#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#include <dlfcn.h>
#include "Neko.h"
#include <string.h>
#include <pthread.h>

#define NEKO_MAX_STATES  8
#define NEKO_MAX_HOOKS   64

// ============================================================================
// sentinel — used by isexecutorclosure to ID our own dylib exactly
// ============================================================================
static void neko_sentinel(void) { /* never called; only dladdr'd */ }
static const char* g_selfPath = nullptr;

static void neko_init_sentinel(void) {
    Dl_info info;
    if (dladdr((const void*)&neko_sentinel, &info) && info.dli_fname)
        g_selfPath = strdup(info.dli_fname);
}

static int neko_is_own(const void* p) {
    if (!g_selfPath) return 0;
    Dl_info info;
    if (!dladdr(p, &info) || !info.dli_fname) return 0;
    return strcmp(info.dli_fname, g_selfPath) == 0;
}

// ============================================================================
// per-state tracking
// ============================================================================
typedef struct {
    lua_State* L;
    int        scriptEnvRef;
    int        gameEnvRef;
} neko_state_t;

static neko_state_t    g_states[NEKO_MAX_STATES];
static int             g_stateCount = 0;
static pthread_mutex_t g_stateMu    = PTHREAD_MUTEX_INITIALIZER;
static lua_State*      g_injectedL  = nullptr;
static __thread char   t_namecallMethod[64] = {0};

lua_State* neko_get_state(void)  { return g_injectedL; }
void       neko_set_state(lua_State* L) { g_injectedL = L; }

static neko_state_t* state_slot(lua_State* L) {
    if (!L) return nullptr;
    pthread_mutex_lock(&g_stateMu);
    neko_state_t* out = nullptr;
    for (int i = 0; i < g_stateCount; i++)
        if (g_states[i].L == L) { out = &g_states[i]; break; }
    if (!out && g_stateCount < NEKO_MAX_STATES) {
        out = &g_states[g_stateCount++];
        out->L = L; out->scriptEnvRef = LUA_NOREF; out->gameEnvRef = LUA_NOREF;
    }
    pthread_mutex_unlock(&g_stateMu);
    return out;
}

static int is_tracked_state(lua_State* L) {
    if (!L) return 0;
    int found = 0;
    pthread_mutex_lock(&g_stateMu);
    for (int i = 0; i < g_stateCount; i++)
        if (g_states[i].L == L) { found = 1; break; }
    pthread_mutex_unlock(&g_stateMu);
    return found;
}

void neko_track_state(lua_State* L)   { state_slot(L); }
void neko_untrack_state(lua_State* L) {
    pthread_mutex_lock(&g_stateMu);
    for (int i = 0; i < g_stateCount; i++) {
        if (g_states[i].L == L) {
            g_states[i] = g_states[--g_stateCount];
            memset(&g_states[g_stateCount], 0, sizeof(neko_state_t));
            break;
        }
    }
    pthread_mutex_unlock(&g_stateMu);
}

// ============================================================================
// envs
// ============================================================================
static int l_scriptenv_index(lua_State* L) {
    neko_state_t* s = state_slot(L);
    if (!s || s->gameEnvRef == LUA_NOREF || !lua_isstring(L, 2)) { lua_pushnil(L); return 1; }
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->gameEnvRef);
    lua_pushvalue(L, 2);
    lua_gettable(L, -2);
    lua_remove(L, -2);
    return 1;
}

static void ensure_envs(lua_State* L) {
    neko_state_t* s = state_slot(L);
    if (!s || s->scriptEnvRef != LUA_NOREF) return;
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    s->gameEnvRef = lua_ref(L, LUA_REGISTRYINDEX);
    lua_newtable(L);
    lua_newtable(L);
    lua_pushcfunction(L, l_scriptenv_index, "__index");
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);
    s->scriptEnvRef = lua_ref(L, LUA_REGISTRYINDEX);
}

static void env_set(lua_State* L, const char* name, lua_CFunction fn) {
    neko_state_t* s = state_slot(L);
    if (!s || s->scriptEnvRef == LUA_NOREF) return;
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->scriptEnvRef);
    lua_pushcfunction(L, fn, name);
    lua_setfield(L, -2, name);
    lua_pop(L, 1);
}

static void env_set_table(lua_State* L, const char* name,
                          const char** names, lua_CFunction* fns, int n) {
    neko_state_t* s = state_slot(L);
    if (!s || s->scriptEnvRef == LUA_NOREF) return;
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->scriptEnvRef);
    lua_newtable(L);
    for (int i = 0; i < n; i++) {
        lua_pushcfunction(L, fns[i], names[i]);
        lua_setfield(L, -2, names[i]);
    }
    lua_setfield(L, -2, name);
    lua_pop(L, 1);
}

// ============================================================================
// __namecall hook
// ============================================================================
static lua_CFunction g_origNamecall = nullptr;

static int passthrough(lua_State* L) {
    if (!g_origNamecall) { lua_pushnil(L); return 1; }
    int nargs = lua_gettop(L);
    lua_pushcfunction(L, g_origNamecall, "orig");
    lua_insert(L, 1);
    if (lua_pcall(L, nargs, LUA_MULTRET, 0) != 0) return lua_error(L);
    return lua_gettop(L);
}

static int neko_namecall_hook(lua_State* L) {
    if (is_tracked_state(L)) {
        const char* m = lua_namecallatom(L, nullptr);
        if (m) { strncpy(t_namecallMethod, m, 63); t_namecallMethod[63] = 0; }
    }
    return passthrough(L);
}

void neko_install_hooks(lua_State* L) {
    if (!L) return;
    if (!g_injectedL) g_injectedL = L;
    neko_init_sentinel();
    ensure_envs(L);

    lua_getglobal(L, "game");
    if (!lua_getmetatable(L, -1)) { lua_pop(L, 1); return; }
    lua_getfield(L, -1, "__namecall");
    if (lua_iscfunction(L, -1) && !g_origNamecall) g_origNamecall = lua_tocfunction(L, -1);
    lua_pop(L, 1);
    if (!g_origNamecall) { lua_pop(L, 2); return; }
    lua_setreadonly(L, -1, 0);
    lua_pushcclosure(L, neko_namecall_hook, "namecall", 0);
    lua_setfield(L, -2, "__namecall");
    lua_setreadonly(L, -1, 1);
    lua_pop(L, 2);
}

// ============================================================================
// env accessors
// ============================================================================
static int l_getgenv(lua_State* L) {
    neko_state_t* s = state_slot(L);
    if (!s || s->scriptEnvRef == LUA_NOREF) { lua_newtable(L); return 1; }
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->scriptEnvRef);
    return 1;
}
static int l_getrenv(lua_State* L) {
    neko_state_t* s = state_slot(L);
    if (!s || s->gameEnvRef == LUA_NOREF) { lua_pushvalue(L, LUA_GLOBALSINDEX); return 1; }
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->gameEnvRef);
    return 1;
}
static int l_getreg(lua_State* L) { lua_pushvalue(L, LUA_REGISTRYINDEX); return 1; }

static int l_loadstring(lua_State* L) {
    size_t len = 0;
    const char* src = luaL_checklstring(L, 1, &len);
    const char* chunk = luaL_optstring(L, 2, "=neko");
    if (luau_load(L, chunk, src, len, 0) != 0) return lua_error(L);
    neko_state_t* s = state_slot(L);
    if (s && s->scriptEnvRef != LUA_NOREF) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, s->scriptEnvRef);
        lua_setfenv(L, -2);
    }
    return 1;
}

// ============================================================================
// identity / introspection
// ============================================================================
static int l_identify(lua_State* L) { lua_pushliteral(L, "Neko/1.5"); return 1; }
static int l_getnamecallmethod(lua_State* L) {
    if (t_namecallMethod[0]) lua_pushstring(L, t_namecallMethod);
    else lua_pushnil(L);
    return 1;
}
static int l_setnamecallmethod(lua_State* L) {
    const char* m = luaL_checkstring(L, 1);
    strncpy(t_namecallMethod, m, 63); t_namecallMethod[63] = 0;
    return 0;
}
static int l_checkcaller(lua_State* L) { lua_pushboolean(L, is_tracked_state(L)); return 1; }

static int l_getrawmetatable(lua_State* L) {
    luaL_checkany(L, 1);
    if (lua_getmetatable(L, 1)) return 1;
    lua_pushnil(L); return 1;
}
static int l_setrawmetatable(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!lua_isnil(L, 2)) luaL_checktype(L, 2, LUA_TTABLE);
    lua_setmetatable(L, 1);
    lua_pushboolean(L, 1);
    return 1;
}
static int l_islclosed(lua_State* L) {
    luaL_checkany(L, 1);
    int has = lua_getmetatable(L, 1);
    if (has) lua_pop(L, 1);
    lua_pushboolean(L, !has);
    return 1;
}
static int l_setreadonly(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_setreadonly(L, 1, lua_toboolean(L, 2));
    return 0;
}
static int l_isreadonly(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushboolean(L, lua_getreadonly(L, 1));
    return 1;
}

// ============================================================================
// clipboard
// ============================================================================
static int l_setclipboard(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);
    NSString* str = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
    if (!str) { lua_pushboolean(L, 0); return 1; }
    dispatch_async(dispatch_get_main_queue(), ^{ [UIPasteboard generalPasteboard].string = str; });
    lua_pushboolean(L, 1);
    return 1;
}
static int l_getclipboard(lua_State* L) {
    __block NSString* s = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        s = [UIPasteboard generalPasteboard].string;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    if (s) lua_pushlstring(L, [s UTF8String], [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    else   lua_pushnil(L);
    return 1;
}

// ============================================================================
// newcclosure — yieldable, single lightuserdata upvalue
// ============================================================================
static int g_cclosureMapRef = LUA_NOREF;

static int cclosure_cont(lua_State* L, int status, lua_KContext ctx) {
    (void)ctx;
    if (status != LUA_OK) return lua_error(L);
    return lua_gettop(L) - 1;
}
static int cclosure_dispatch(lua_State* L) {
    void* key = lua_touserdata(L, lua_upvalueindex(1));
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_cclosureMapRef);
    lua_pushlightuserdata(L, key);
    lua_gettable(L, -2);
    lua_remove(L, -2);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 1); lua_pushnil(L); return 1; }
    lua_insert(L, 1);
    int nargs = lua_gettop(L) - 1;
    lua_callk(L, nargs, LUA_MULTRET, 0, cclosure_cont);
    return lua_gettop(L);
}
static int l_newcclosure(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    if (lua_iscfunction(L, 1)) { lua_pushvalue(L, 1); return 1; }
    if (g_cclosureMapRef == LUA_NOREF) {
        lua_newtable(L);
        g_cclosureMapRef = lua_ref(L, LUA_REGISTRYINDEX);
    }
    void* key = (void*)lua_topointer(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_cclosureMapRef);
    lua_pushlightuserdata(L, key);
    lua_pushvalue(L, 1);
    lua_settable(L, -3);
    lua_pop(L, 1);
    lua_pushlightuserdata(L, key);
    lua_pushcclosure(L, cclosure_dispatch, "wrapped", 1);
    return 1;
}

// ============================================================================
// closure predicates
// ============================================================================
static int l_iscclosure(lua_State* L) { luaL_checkany(L, 1); lua_pushboolean(L, lua_iscfunction(L, 1)); return 1; }
static int l_islclosure(lua_State* L) {
    luaL_checkany(L, 1);
    lua_pushboolean(L, !lua_iscfunction(L, 1) && lua_isfunction(L, 1));
    return 1;
}
static int l_isexecutorclosure(lua_State* L) {
    luaL_checkany(L, 1);
    if (!lua_isfunction(L, 1)) { lua_pushboolean(L, 0); return 1; }
    lua_CFunction f = lua_tocfunction(L, 1);
    if (!f) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, neko_is_own((const void*)f));
    return 1;
}

// ============================================================================
// fenv — sanitized for game threads
// ============================================================================
static int l_getfenv_safe(lua_State* L) {
    luaL_checkany(L, 1);
    int isExec = is_tracked_state(L);
    if (lua_isfunction(L, 1)) {
        lua_settop(L, 1);
        lua_getfenv(L, 1);
    } else if (lua_isnumber(L, 1)) {
        int level = (int)lua_tointeger(L, 1);
        lua_Debug ar;
        if (!lua_getstack(L, level, &ar)) { lua_pushnil(L); return 1; }
        lua_getinfo(L, "f", &ar);
        if (!lua_isfunction(L, -1)) { lua_pop(L, 1); lua_pushnil(L); return 1; }
        lua_getfenv(L, -1);
        lua_remove(L, -2);
    } else {
        lua_pushnil(L); return 1;
    }
    if (!isExec) { lua_pop(L, 1); lua_pushvalue(L, LUA_GLOBALSINDEX); }
    return 1;
}
static int l_setfenv_real(lua_State* L) {
    luaL_checkany(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_setfenv(L, 1);
    return 0;
}
static int l_getsenv(lua_State* L) {
    luaL_checkany(L, 1);
    if (lua_isfunction(L, 1)) { lua_settop(L, 1); lua_getfenv(L, 1); return 1; }
    lua_pushnil(L); return 1;
}

// ============================================================================
// debug
// ============================================================================
static int l_debug_info(lua_State* L) {
    lua_Debug ar; memset(&ar, 0, sizeof(ar));
    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
        if (!lua_getinfo(L, 0, "Slnuf", &ar)) { lua_pushnil(L); return 1; }
    } else {
        int level = (int)luaL_checkinteger(L, 1);
        if (!lua_getinfo(L, level, "Slnuf", &ar)) { lua_pushnil(L); return 1; }
    }
    lua_newtable(L);
    lua_pushstring(L, ar.source ? ar.source : "");       lua_setfield(L, -2, "source");
    lua_pushstring(L, ar.short_src ? ar.short_src : ""); lua_setfield(L, -2, "short_src");
    lua_pushinteger(L, ar.linedefined);                  lua_setfield(L, -2, "linedefined");
    lua_pushinteger(L, ar.lastlinedefined);              lua_setfield(L, -2, "lastlinedefined");
    lua_pushinteger(L, ar.currentline);                  lua_setfield(L, -2, "currentline");
    lua_pushstring(L, ar.what ? ar.what : "");           lua_setfield(L, -2, "what");
    lua_pushstring(L, ar.name ? ar.name : "");           lua_setfield(L, -2, "name");
    lua_pushstring(L, ar.namewhat ? ar.namewhat : "");   lua_setfield(L, -2, "namewhat");
    return 1;
}
static int l_debug_traceback(lua_State* L) {
    const char* msg = luaL_optstring(L, 1, "");
    luaL_traceback(L, L, msg, 1);
    return 1;
}
static int l_debug_profilebegin(lua_State* L)        { (void)L; return 0; }
static int l_debug_profileend(lua_State* L)          { (void)L; return 0; }
static int l_debug_setmemorycategory(lua_State* L)   { (void)L; return 0; }
static int l_debug_resetmemorycategory(lua_State* L) { (void)L; return 0; }

// ============================================================================
// thread identity
// ============================================================================
static int l_getthreadidentity(lua_State* L) { lua_pushinteger(L, 8); return 1; }
static int l_setthreadidentity(lua_State* L) { luaL_checkinteger(L, 1); return 0; }
static int l_getidentity(lua_State* L)       { lua_pushinteger(L, 8); return 1; }
static int l_setidentity(lua_State* L)       { luaL_checkinteger(L, 1); return 0; }

// ============================================================================
// crypt / base64
// ============================================================================
static int l_crypt_base64encode(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);
    NSData* d = [NSData dataWithBytes:s length:len];
    NSString* b64 = [d base64EncodedStringWithOptions:0];
    if (!b64) { lua_pushnil(L); return 1; }
    lua_pushstring(L, [b64 UTF8String]);
    return 1;
}
static int l_crypt_base64decode(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);
    NSString* b64String = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
    if (!b64String) { lua_pushnil(L); return 1; }
    NSData* d = [[NSData alloc] initWithBase64EncodedString:b64String options:0];
    if (!d) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char*)d.bytes, d.length);
    return 1;
}
static int l_crypt_hash(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);
    const char* algoC = luaL_optstring(L, 2, "sha256");
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    size_t dlen = CC_SHA256_DIGEST_LENGTH;
    if      (strcasecmp(algoC, "md5")    == 0) { CC_MD5(s, (CC_LONG)len, digest);    dlen = CC_MD5_DIGEST_LENGTH; }
    else if (strcasecmp(algoC, "sha1")   == 0) { CC_SHA1(s, (CC_LONG)len, digest);   dlen = CC_SHA1_DIGEST_LENGTH; }
    else if (strcasecmp(algoC, "sha512") == 0) { CC_SHA512(s, (CC_LONG)len, digest); dlen = CC_SHA512_DIGEST_LENGTH; }
    else                                       { CC_SHA256(s, (CC_LONG)len, digest); }
    NSMutableString* hex = [NSMutableString stringWithCapacity:dlen * 2];
    for (size_t i = 0; i < dlen; i++) [hex appendFormat:@"%02x", digest[i]];
    lua_pushstring(L, [hex UTF8String]);
    return 1;
}
static int l_crypt_generatekey(lua_State* L) {
    int bits = (int)luaL_optinteger(L, 1, 32);
    if (bits <= 0 || bits > 256) { lua_pushnil(L); return 1; }
    unsigned char buf[256]; arc4random_buf(buf, (size_t)bits);
    NSData* d = [NSData dataWithBytes:buf length:(NSUInteger)bits];
    lua_pushstring(L, [[d base64EncodedStringWithOptions:0] UTF8String]);
    return 1;
}
static int l_crypt_generatebytes(lua_State* L) {
    int n = (int)luaL_checkinteger(L, 1);
    if (n <= 0 || n > 65536) { lua_pushnil(L); return 1; }
    unsigned char* buf = (unsigned char*)malloc((size_t)n);
    if (!buf) { lua_pushnil(L); return 1; }
    arc4random_buf(buf, (size_t)n);
    lua_pushlstring(L, (const char*)buf, (size_t)n);
    free(buf);
    return 1;
}
static int l_crypt_encrypt(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_crypt_decrypt(lua_State* L) { (void)L; lua_pushnil(L); return 1; }

// ============================================================================
// http
// ============================================================================
static int l_HttpGet(lua_State* L) {
    size_t ulen = 0;
    const char* url = luaL_checklstring(L, 1, &ulen);
    NSString* urlStr = [[NSString alloc] initWithBytes:url length:ulen encoding:NSUTF8StringEncoding];
    NSURL* u = urlStr ? [NSURL URLWithString:urlStr] : nil;
    if (!u) { lua_pushnil(L); return 1; }
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:u];
    [req setValue:@"RobloxApp/0.592.0 (iOS)" forHTTPHeaderField:@"User-Agent"];
    __block NSData* data = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData* d, NSURLResponse* r, NSError* e) {
        if (d) data = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        lua_pushnil(L); return 1;
    }
    if (data) { lua_pushlstring(L, (const char*)data.bytes, data.length); return 1; }
    lua_pushnil(L); return 1;
}
static int l_request(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "Url");
    if (!lua_isstring(L, -1)) { lua_pop(L, 1); lua_pushnil(L); return 1; }
    lua_replace(L, 1);
    return l_HttpGet(L);
}

// ============================================================================
// filesystem — sandboxed to app Documents/neko/
// ============================================================================
static NSString* neko_ws(void) {
    static NSString* g = nil;
    if (!g) {
        NSArray* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* base = docs.firstObject ?: NSTemporaryDirectory();
        g = [base stringByAppendingPathComponent:@"neko"];
        [[NSFileManager defaultManager] createDirectoryAtPath:g
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return g;
}
static NSString* neko_path(const char* p) {
    NSString* rel = [NSString stringWithUTF8String:p];
    if (!rel) return nil;
    return [neko_ws() stringByAppendingPathComponent:rel];
}

static int l_readfile(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    NSString* path = neko_path(p);
    NSData* d = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!d) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char*)d.bytes, d.length);
    return 1;
}
static int l_writefile(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    size_t len = 0;
    const char* s = luaL_checklstring(L, 2, &len);
    NSString* path = neko_path(p);
    if (!path) { lua_pushboolean(L, 0); return 1; }
    NSData* d = [NSData dataWithBytes:s length:len];
    lua_pushboolean(L, [d writeToFile:path atomically:YES]);
    return 1;
}
static int l_appendfile(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    size_t len = 0;
    const char* s = luaL_checklstring(L, 2, &len);
    NSString* path = neko_path(p);
    if (!path) { lua_pushboolean(L, 0); return 1; }
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSData dataWithBytes:s length:len] writeToFile:path atomically:YES];
        lua_pushboolean(L, 1); return 1;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[NSData dataWithBytes:s length:len]]; [fh closeFile]; }
    @catch (NSException* e) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, 1);
    return 1;
}
static int l_isfile(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    NSString* path = neko_path(p);
    if (!path) { lua_pushboolean(L, 0); return 1; }
    BOOL isDir = NO;
    BOOL ex = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    lua_pushboolean(L, ex && !isDir);
    return 1;
}
static int l_isfolder(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    NSString* path = neko_path(p);
    if (!path) { lua_pushboolean(L, 0); return 1; }
    BOOL isDir = NO;
    BOOL ex = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    lua_pushboolean(L, ex && isDir);
    return 1;
}
static int l_makefolder(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    NSString* path = neko_path(p);
    if (!path) { lua_pushboolean(L, 0); return 1; }
    NSError* e = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:path
                                        withIntermediateDirectories:YES attributes:nil error:&e];
    lua_pushboolean(L, ok || e == nil);
    return 1;
}
static int l_delfile(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    NSString* path = neko_path(p);
    if (!path) { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, [[NSFileManager defaultManager] removeItemAtPath:path error:nil]);
    return 1;
}
static int l_delfolder(lua_State* L) { return l_delfile(L); }
static int l_listfiles(lua_State* L) {
    const char* p = luaL_checkstring(L, 1);
    NSString* path = neko_path(p);
    if (!path) { lua_newtable(L); return 1; }
    NSArray* items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    lua_newtable(L);
    int i = 1;
    for (NSString* it in items) {
        lua_pushstring(L, [it UTF8String]);
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

// ============================================================================
// hooking — Lua-level; C targets via g_hooks side table
// ============================================================================
typedef struct { void* key; int hookRef; lua_State* L; } hook_entry_t;
static hook_entry_t    g_hooks[NEKO_MAX_HOOKS];
static int             g_hookCount = 0;
static pthread_mutex_t g_hookMu   = PTHREAD_MUTEX_INITIALIZER;

static int cclosure_hook_trampoline(lua_State* L) {
    lua_pushvalue(L, lua_upvalueindex(1));      // hook
    lua_pushvalue(L, lua_upvalueindex(2));      // orig
    int n = lua_gettop(L) - 2;
    lua_insert(L, 1);                           // hook -> slot 1
    lua_insert(L, 2);                           // orig -> slot 2
    lua_call(L, n + 1, LUA_MULTRET);
    return lua_gettop(L);
}

static int l_hookfunction(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    if (lua_iscfunction(L, 1)) {
        void* key = (void*)lua_tocfunction(L, 1);
        pthread_mutex_lock(&g_hookMu);
        for (int i = 0; i < g_hookCount; i++) {
            if (g_hooks[i].key == key) {
                lua_rawgeti(L, LUA_REGISTRYINDEX, g_hooks[i].hookRef);
                pthread_mutex_unlock(&g_hookMu);
                lua_pushvalue(L, 1);
                return 2;
            }
        }
        if (g_hookCount < NEKO_MAX_HOOKS) {
            g_hooks[g_hookCount].key = key;
            g_hooks[g_hookCount].L = L;
            lua_pushvalue(L, 2);
            g_hooks[g_hookCount].hookRef = lua_ref(L, LUA_REGISTRYINDEX);
            g_hookCount++;
        }
        pthread_mutex_unlock(&g_hookMu);
        lua_pushvalue(L, 1);
        return 1;
    }
    lua_pushvalue(L, 2);
    lua_pushvalue(L, 1);
    lua_pushcclosure(L, cclosure_hook_trampoline, "hooked", 2);
    lua_pushvalue(L, 1);
    return 2;
}

static int l_restorefunction(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    if (!lua_iscfunction(L, 1)) { lua_pushvalue(L, 1); return 1; }
    void* key = (void*)lua_tocfunction(L, 1);
    pthread_mutex_lock(&g_hookMu);
    for (int i = 0; i < g_hookCount; i++) {
        if (g_hooks[i].key == key) {
            luaL_unref(L, LUA_REGISTRYINDEX, g_hooks[i].hookRef);
            g_hooks[i] = g_hooks[--g_hookCount];
            memset(&g_hooks[g_hookCount], 0, sizeof(hook_entry_t));
            break;
        }
    }
    pthread_mutex_unlock(&g_hookMu);
    lua_pushvalue(L, 1);
    return 1;
}

static int l_hookmetamethod(lua_State* L) {
    luaL_checkany(L, 1);
    const char* name = luaL_checkstring(L, 2);
    luaL_checktype(L, 3, LUA_TFUNCTION);
    if (!lua_getmetatable(L, 1)) { lua_pushnil(L); return 1; }
    lua_getfield(L, -1, name);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); lua_pushnil(L); return 1; }
    int origRef = lua_ref(L, LUA_REGISTRYINDEX);
    lua_pushvalue(L, 3);
    lua_setfield(L, -2, name);
    lua_pop(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, origRef);
    luaL_unref(L, LUA_REGISTRYINDEX, origRef);
    return 1;
}

// ============================================================================
// cloneref / clonefunction / protectfunction
// ============================================================================
static int l_cloneref(lua_State* L) {
    luaL_checkany(L, 1);
    if (!lua_isuserdata(L, 1)) { lua_pushvalue(L, 1); return 1; }
    void* p = lua_touserdata(L, 1);
    lua_pushlightuserdata(L, p);
    return 1;
}
static int l_clonefunction(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    return 1;
}
static int g_protectedRef = LUA_NOREF;
static int l_protectfunction(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    if (g_protectedRef == LUA_NOREF) { lua_newtable(L); g_protectedRef = lua_ref(L, LUA_REGISTRYINDEX); }
    void* key = (void*)lua_topointer(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_protectedRef);
    lua_pushlightuserdata(L, key);
    lua_pushboolean(L, 1);
    lua_settable(L, -3);
    lua_pop(L, 1);
    lua_pushvalue(L, 1);
    return 1;
}

// ============================================================================
// type predicates
// ============================================================================
static int l_isfunction(lua_State* L) { luaL_checkany(L, 1); lua_pushboolean(L, lua_isfunction(L, 1)); return 1; }
static int l_istable(lua_State* L)    { luaL_checkany(L, 1); lua_pushboolean(L, lua_istable(L, 1)); return 1; }
static int l_isuserdata(lua_State* L) { luaL_checkany(L, 1); lua_pushboolean(L, lua_isuserdata(L, 1)); return 1; }

// ============================================================================
// stubs — need offsets / Luau internal headers
// ============================================================================
static int l_getcallingscript(lua_State* L)  { (void)L; lua_pushnil(L); return 1; }
static int l_getscriptclosure(lua_State* L)  { (void)L; lua_pushnil(L); return 1; }
static int l_getscriptbytecode(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_getscripthash(lua_State* L)     { (void)L; lua_pushnil(L); return 1; }
static int l_fireclickdetector(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_firetouchinterest(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_queue_on_teleport(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_getupvalues(lua_State* L)       { (void)L; lua_newtable(L); return 1; }
static int l_setupvalue(lua_State* L)        { (void)L; lua_pushnil(L); return 1; }
static int l_getconstants(lua_State* L)      { (void)L; lua_newtable(L); return 1; }
static int l_getgc(lua_State* L)             { lua_newtable(L); return 1; }
static int l_getinstances(lua_State* L)      { lua_newtable(L); return 1; }
static int l_getnilinstances(lua_State* L)   { lua_newtable(L); return 1; }
static int l_getconnections(lua_State* L)    { lua_newtable(L); return 1; }
static int l_getloadedmodules(lua_State* L)  { lua_newtable(L); return 1; }
static int l_getrunningscripts(lua_State* L) { lua_newtable(L); return 1; }
static int l_getcallbackvalue(lua_State* L)  { (void)L; lua_pushnil(L); return 1; }
static int l_setcallbackvalue(lua_State* L)  { (void)L; lua_pushnil(L); return 1; }
static int l_gethiddenproperty(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_sethiddenproperty(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_sethiddenproperties(lua_State* L){ (void)L; lua_pushnil(L); return 1; }
static int l_isrenderobj(lua_State* L)       { luaL_checkany(L, 1); lua_pushboolean(L, 0); return 1; }
static int l_getrenderproperty(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_setrenderproperty(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_isfile_compat(lua_State* L)     { return l_isfile(L); }
static int l_isfolder_compat(lua_State* L)   { return l_isfolder(L); }
static int l_getfunctionhash(lua_State* L)   { (void)L; lua_pushnil(L); return 1; }
static int l_isscriptable(lua_State* L)      { luaL_checkany(L, 1); lua_pushboolean(L, 1); return 1; }
static int l_setscriptable(lua_State* L)     { (void)L; lua_pushboolean(L, 0); return 1; }
static int l_isrenderobj_2(lua_State* L)     { return l_isrenderobj(L); }
static int l_getrenderproperty_2(lua_State* L){ return l_getrenderproperty(L); }
static int l_setrenderproperty_2(lua_State* L){ return l_setrenderproperty(L); }
static int l_iscclosure_2(lua_State* L)      { return l_iscclosure(L); }
static int l_islclosure_2(lua_State* L)      { return l_islclosure(L); }

// ============================================================================
// registration
// ============================================================================
void neko_register_api(lua_State* L) {
    ensure_envs(L);
    neko_state_t* s = state_slot(L);
    if (!s || s->scriptEnvRef == LUA_NOREF) return;

    // env
    env_set(L, "getgenv",           l_getgenv);
    env_set(L, "getrenv",           l_getrenv);
    env_set(L, "getreg",            l_getreg);
    env_set(L, "getregistry",       l_getreg);

    // exec / identity
    env_set(L, "loadstring",        l_loadstring);
    env_set(L, "identifyexecutor",  l_identify);
    env_set(L, "getnamecallmethod", l_getnamecallmethod);
    env_set(L, "setnamecallmethod", l_setnamecallmethod);
    env_set(L, "checkcaller",       l_checkcaller);

    // metatable
    env_set(L, "getrawmetatable",   l_getrawmetatable);
    env_set(L, "setrawmetatable",   l_setrawmetatable);
    env_set(L, "islclosed",         l_islclosed);
    env_set(L, "setreadonly",       l_setreadonly);
    env_set(L, "isreadonly",        l_isreadonly);

    // clipboard
    env_set(L, "setclipboard",      l_setclipboard);
    env_set(L, "toclipboard",       l_setclipboard);
    env_set(L, "getclipboard",      l_getclipboard);

    // closures
    env_set(L, "newcclosure",       l_newcclosure);
    env_set(L, "iscclosure",        l_iscclosure);
    env_set(L, "islclosure",        l_islclosure);
    env_set(L, "isexecutorclosure", l_isexecutorclosure);
    env_set(L, "clonefunction",     l_clonefunction);
    env_set(L, "cloneref",          l_cloneref);
    env_set(L, "protectfunction",   l_protectfunction);

    // hooking
    env_set(L, "hookfunction",      l_hookfunction);
    env_set(L, "hookfunc",          l_hookfunction);
    env_set(L, "replaceclosure",    l_hookfunction);
    env_set(L, "restorefunction",   l_restorefunction);
    env_set(L, "hookmetamethod",    l_hookmetamethod);

    // fenv
    env_set(L, "getfenv",           l_getfenv_safe);
    env_set(L, "setfenv",           l_setfenv_real);
    env_set(L, "getsenv",           l_getsenv);

    // type predicates
    env_set(L, "isfunction",        l_isfunction);
    env_set(L, "istable",           l_istable);
    env_set(L, "isuserdata",        l_isuserdata);

    // thread identity
    env_set(L, "getthreadidentity", l_getthreadidentity);
    env_set(L, "setthreadidentity", l_setthreadidentity);
    env_set(L, "getidentity",       l_getidentity);
    env_set(L, "setidentity",       l_setidentity);

    // filesystem
    env_set(L, "readfile",          l_readfile);
    env_set(L, "writefile",         l_writefile);
    env_set(L, "appendfile",        l_appendfile);
    env_set(L, "isfile",            l_isfile);
    env_set(L, "isfolder",          l_isfolder);
    env_set(L, "makefolder",        l_makefolder);
    env_set(L, "delfile",           l_delfile);
    env_set(L, "delfolder",         l_delfolder);
    env_set(L, "listfiles",         l_listfiles);

    // game ops (stubs until offsets)
    env_set(L, "getcallingscript",  l_getcallingscript);
    env_set(L, "getscriptclosure",  l_getscriptclosure);
    env_set(L, "getscriptbytecode", l_getscriptbytecode);
    env_set(L, "getscripthash",     l_getscripthash);
    env_set(L, "fireclickdetector", l_fireclickdetector);
    env_set(L, "firetouchinterest", l_firetouchinterest);
    env_set(L, "queue_on_teleport", l_queue_on_teleport);
    env_set(L, "queueonteleport",   l_queue_on_teleport);

    // introspection (stubs until Luau headers)
    env_set(L, "getupvalues",       l_getupvalues);
    env_set(L, "setupvalue",        l_setupvalue);
    env_set(L, "getconstants",      l_getconstants);
    env_set(L, "getgc",             l_getgc);
    env_set(L, "getinstances",      l_getinstances);
    env_set(L, "getnilinstances",   l_getnilinstances);
    env_set(L, "getconnections",    l_getconnections);
    env_set(L, "getloadedmodules",  l_getloadedmodules);
    env_set(L, "getrunningscripts", l_getrunningscripts);
    env_set(L, "getcallbackvalue",  l_getcallbackvalue);
    env_set(L, "setcallbackvalue",  l_setcallbackvalue);
    env_set(L, "gethiddenproperty", l_gethiddenproperty);
    env_set(L, "sethiddenproperty", l_sethiddenproperty);
    env_set(L, "sethiddenproperties", l_sethiddenproperties);
    env_set(L, "isrenderobj",       l_isrenderobj);
    env_set(L, "getrenderproperty", l_getrenderproperty);
    env_set(L, "setrenderproperty", l_setrenderproperty);
    env_set(L, "getfunctionhash",   l_getfunctionhash);
    env_set(L, "isscriptable",      l_isscriptable);
    env_set(L, "setscriptable",     l_setscriptable);

    // http
    env_set(L, "HttpGet",           l_HttpGet);
    env_set(L, "http_request",      l_HttpGet);
    env_set(L, "request",           l_request);
    env_set(L, "http_request_async", l_HttpGet);
    env_set(L, "syn_request",       l_HttpGet);
    env_set(L, "syn.request",       l_HttpGet);

    // crypt / base64 tables
    {
        const char* names[] = {
            "base64encode", "base64decode", "hash", "generatekey",
            "generatebytes", "encrypt", "decrypt"
        };
        lua_CFunction fns[] = {
            l_crypt_base64encode, l_crypt_base64decode, l_crypt_hash,
            l_crypt_generatekey, l_crypt_generatebytes,
            l_crypt_encrypt, l_crypt_decrypt
        };
        env_set_table(L, "crypt", names, fns, 7);

        const char* bnames[] = { "encode", "decode" };
        lua_CFunction bfns[] = { l_crypt_base64encode, l_crypt_base64decode };
        env_set_table(L, "base64", bnames, bfns, 2);
    }

    // debug overrides
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->scriptEnvRef);
    lua_getfield(L, -1, "debug");
    if (lua_istable(L, -1)) {
        lua_pushcfunction(L, l_debug_info,               "info");               lua_setfield(L, -2, "info");
        lua_pushcfunction(L, l_debug_traceback,          "traceback");          lua_setfield(L, -2, "traceback");
        lua_pushcfunction(L, l_debug_profilebegin,       "profilebegin");       lua_setfield(L, -2, "profilebegin");
        lua_pushcfunction(L, l_debug_profileend,         "profileend");         lua_setfield(L, -2, "profileend");
        lua_pushcfunction(L, l_debug_setmemorycategory,  "setmemorycategory");  lua_setfield(L, -2, "setmemorycategory");
        lua_pushcfunction(L, l_debug_resetmemorycategory,"resetmemorycategory");lua_setfield(L, -2, "resetmemorycategory");
    }
    lua_pop(L, 2);
}
