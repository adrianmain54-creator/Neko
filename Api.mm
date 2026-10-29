#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#include <dlfcn.h>
#include "Neko.h"
#include <string.h>
#include <pthread.h>

#define NEKO_GENV_KEY    "neko.genv"
#define NEKO_MAX_TRACKED 64

static lua_State* g_injectedL = nullptr;
static lua_State* g_mainL = nullptr;
static lua_CFunction g_origNamecall = nullptr;
static int g_scriptEnvRef = LUA_NOREF;
static int g_gameEnvRef = LUA_NOREF;

static __thread char t_namecallMethod[64] = {0};
char g_namecallMethod[64] = {0};

lua_State* neko_get_state(void) { return g_injectedL; }
void neko_set_state(lua_State* L) { g_injectedL = L; }

static lua_State* g_tracked[NEKO_MAX_TRACKED];
static int g_trackedCount = 0;
static pthread_mutex_t g_trackedMu = PTHREAD_MUTEX_INITIALIZER;

static int is_tracked_state(lua_State* L) {
    if (!L) return 0;
    if (L == g_mainL) return 0;
    int found = 0;
    pthread_mutex_lock(&g_trackedMu);
    for (int i = 0; i < g_trackedCount; i++) if (g_tracked[i] == L) { found = 1; break; }
    pthread_mutex_unlock(&g_trackedMu);
    return found;
}

void neko_track_state(lua_State* L) {
    if (!L || is_tracked_state(L)) return;
    pthread_mutex_lock(&g_trackedMu);
    if (g_trackedCount < NEKO_MAX_TRACKED) g_tracked[g_trackedCount++] = L;
    pthread_mutex_unlock(&g_trackedMu);
}

void neko_untrack_state(lua_State* L) {
    pthread_mutex_lock(&g_trackedMu);
    for (int i = 0; i < g_trackedCount; i++) {
        if (g_tracked[i] == L) {
            g_tracked[i] = g_tracked[--g_trackedCount];
            g_tracked[g_trackedCount] = nullptr;
            break;
        }
    }
    pthread_mutex_unlock(&g_trackedMu);
}

static int l_scriptenv_index(lua_State* L) {
    if (!lua_isstring(L, 2)) { lua_pushnil(L); return 1; }
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_gameEnvRef);
    lua_pushvalue(L, 2);
    lua_gettable(L, -2);
    return 1;
}

static void ensure_envs(lua_State* L) {
    if (g_scriptEnvRef != LUA_NOREF) return;
    
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    g_gameEnvRef = lua_ref(L, LUA_REGISTRYINDEX);

    lua_newtable(L);
    lua_newtable(L);
    lua_pushcfunction(L, l_scriptenv_index, "__index");
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);
    g_scriptEnvRef = lua_ref(L, LUA_REGISTRYINDEX);
}

static void env_set(lua_State* L, const char* name, lua_CFunction fn) {
    lua_pushcfunction(L, fn, name);
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_scriptEnvRef);
    lua_insert(L, -2);
    lua_setfield(L, -2, name);
    lua_pop(L, 1);
}

static int neko_namecall_hook(lua_State* L);

// FIX: Removed lua_callk and namecall_cont. Using standard lua_call.
static int passthrough(lua_State* L) {
    if (!g_origNamecall) { lua_pushnil(L); return 1; }
    int nargs = lua_gettop(L) - 1;
    if (nargs < 0) { lua_pushnil(L); return 1; }
    lua_pushcfunction(L, g_origNamecall, "orig");
    lua_insert(L, 1);
    lua_call(L, nargs, LUA_MULTRET);
    return lua_gettop(L);
}

static int neko_namecall_hook(lua_State* L) {
    if (is_tracked_state(L)) {
        const char* m = lua_namecallatom(L, nullptr);
        if (m) {
            strncpy(t_namecallMethod, m, 63);
            t_namecallMethod[63] = 0;
            memcpy(g_namecallMethod, t_namecallMethod, 64);
        }
    }
    return passthrough(L);
}

void neko_install_hooks(lua_State* L) {
    if (!L) return;
    if (!g_injectedL) g_injectedL = L;
    if (!g_mainL)     g_mainL     = L;
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

static int l_getgenv(lua_State* L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_scriptEnvRef);
    return 1;
}

static int l_getrenv(lua_State* L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_gameEnvRef);
    return 1;
}

static int l_getreg(lua_State* L) { lua_pushvalue(L, LUA_REGISTRYINDEX); return 1; }

static int l_loadstring(lua_State* L) {
    size_t len = 0;
    const char* src = luaL_checklstring(L, 1, &len);
    if (luau_load(L, "=neko", src, len, 0) != 0) { lua_error(L); return 0; }
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_scriptEnvRef);
    lua_setfenv(L, -2);
    return 1;
}

static int l_identify(lua_State* L)          { lua_pushliteral(L, "Neko/1.2"); return 1; }
static int l_getnamecallmethod(lua_State* L) {
    if (t_namecallMethod[0]) lua_pushstring(L, t_namecallMethod);
    else                     lua_pushnil(L);
    return 1;
}
static int l_checkcaller(lua_State* L)       { lua_pushboolean(L, is_tracked_state(L)); return 1; }

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

static int l_setreadonly(lua_State* L) { luaL_checktype(L, 1, LUA_TTABLE); lua_setreadonly(L, 1, lua_toboolean(L, 2)); return 0; }
static int l_isreadonly(lua_State* L)  { luaL_checktype(L, 1, LUA_TTABLE); lua_pushboolean(L, lua_getreadonly(L, 1)); return 1; }

static int l_setclipboard(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);
    [UIPasteboard generalPasteboard].string =
        [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
    return 0;
}

static int l_getclipboard(lua_State* L) {
    NSString* s = [UIPasteboard generalPasteboard].string;
    if (s) lua_pushlstring(L, [s UTF8String], [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    else   lua_pushnil(L);
    return 1;
}

static int l_newcclosure(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    return 1;
}

static int l_iscclosure(lua_State* L) {
    luaL_checkany(L, 1);
    lua_pushboolean(L, lua_iscfunction(L, 1));
    return 1;
}

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
    Dl_info info;
    if (dladdr((const void*)f, &info) && info.dli_fname) {
        const char* p = info.dli_fname;
        const char* base = strrchr(p, '/');
        base = base ? base + 1 : p;
        if (strstr(base, "Neko") || strstr(base, "neko") || strstr(base, "swift")) {
            lua_pushboolean(L, 1);
            return 1;
        }
    }
    lua_pushboolean(L, 0);
    return 1;
}

static int l_getfenv_real(lua_State* L) {
    luaL_checkany(L, 1);
    if (lua_isfunction(L, 1) || lua_isnumber(L, 1)) lua_getfenv(L, 1);
    else lua_pushnil(L);
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
    if (lua_isfunction(L, 1)) {
        lua_getfenv(L, 1);
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

static int l_debug_info(lua_State* L) {
    lua_Debug ar;
    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
        if (!lua_getinfo(L, 0, "Slnf", &ar)) { lua_pushnil(L); return 1; }
    } else {
        int level = (int)luaL_checkinteger(L, 1);
        if (!lua_getinfo(L, level, "nSluf", &ar)) { lua_pushnil(L); return 1; }
    }
    lua_newtable(L);
    lua_pushstring(L, ar.source ? ar.source : "");      lua_setfield(L, -2, "source");
    lua_pushstring(L, ar.short_src ? ar.short_src : "");lua_setfield(L, -2, "short_src");
    lua_pushinteger(L, ar.linedefined);                 lua_setfield(L, -2, "linedefined");
    lua_pushinteger(L, ar.currentline);                 lua_setfield(L, -2, "currentline");
    lua_pushstring(L, ar.what ? ar.what : "");          lua_setfield(L, -2, "what");
    lua_pushstring(L, ar.name ? ar.name : "");          lua_setfield(L, -2, "name");
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

static int l_getthreadidentity(lua_State* L) { lua_pushinteger(L, 8); return 1; }
static int l_setthreadidentity(lua_State* L) { luaL_checkinteger(L, 1); return 0; }

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
    NSString *b64String = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
    if (!b64String) { lua_pushnil(L); return 1; }
    NSData* d = [[NSData alloc] initWithBase64EncodedString:b64String options:0];
    if (!d) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char*)d.bytes, d.length);
    return 1;
}

static int l_crypt_hash(lua_State* L) {
    size_t len = 0;
    const char* s = luaL_checklstring(L, 1, &len);
    NSString* algo = [NSString stringWithUTF8String:luaL_optstring(L, 2, "sha256")];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    size_t dlen = CC_SHA256_DIGEST_LENGTH;
    if ([algo caseInsensitiveCompare:@"md5"] == NSOrderedSame) {
        CC_MD5(s, (CC_LONG)len, digest); dlen = CC_MD5_DIGEST_LENGTH;
    } else if ([algo caseInsensitiveCompare:@"sha1"] == NSOrderedSame) {
        CC_SHA1(s, (CC_LONG)len, digest); dlen = CC_SHA1_DIGEST_LENGTH;
    } else {
        CC_SHA256(s, (CC_LONG)len, digest);
    }
    NSMutableString* hex = [NSMutableString stringWithCapacity:dlen * 2];
    for (size_t i = 0; i < dlen; i++) [hex appendFormat:@"%02x", digest[i]];
    lua_pushstring(L, [hex UTF8String]);
    return 1;
}

static int l_crypt_generatekey(lua_State* L) {
    int bits = (int)luaL_optinteger(L, 1, 32);
    if (bits <= 0 || bits > 256) { lua_pushnil(L); return 1; }
    unsigned char buf[256];
    arc4random_buf(buf, (size_t)bits);
    NSData* d = [NSData dataWithBytes:buf length:(NSUInteger)bits];
    lua_pushstring(L, [[d base64EncodedStringWithOptions:0] UTF8String]);
    return 1;
}

static int l_crypt_encrypt(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_crypt_decrypt(lua_State* L) { (void)L; lua_pushnil(L); return 1; }

static int l_HttpGet(lua_State* L) {
    size_t ulen = 0;
    const char* url = luaL_checklstring(L, 1, &ulen);
    NSURL* u = [NSURL URLWithString:[[NSString alloc] initWithBytes:url length:ulen encoding:NSUTF8StringEncoding]];
    if (!u) { lua_pushnil(L); return 1; }
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:u];
    [req setValue:@"RobloxApp/0.592.0 (iOS)" forHTTPHeaderField:@"User-Agent"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData* data = nil;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData* d, NSURLResponse* r, NSError* e) {
        if (d) data = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
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

static int l_getcallingscript(lua_State* L)  { (void)L; lua_pushnil(L); return 1; }
static int l_getscriptclosure(lua_State* L)  { (void)L; lua_pushnil(L); return 1; }
static int l_fireclickdetector(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_firetouchinterest(lua_State* L) { (void)L; lua_pushnil(L); return 1; }
static int l_queue_on_teleport(lua_State* L) { (void)L; lua_pushnil(L); return 1; }

void neko_register_api(lua_State* L) {
    ensure_envs(L);

    env_set(L, "getgenv",           l_getgenv);
    env_set(L, "getrenv",           l_getrenv);
    env_set(L, "getreg",            l_getreg);
    env_set(L, "loadstring",        l_loadstring);
    env_set(L, "identifyexecutor",  l_identify);
    env_set(L, "getnamecallmethod", l_getnamecallmethod);
    env_set(L, "getrawmetatable",   l_getrawmetatable);
    env_set(L, "setrawmetatable",   l_setrawmetatable);
    env_set(L, "islclosed",         l_islclosed);
    env_set(L, "setreadonly",       l_setreadonly);
    env_set(L, "isreadonly",        l_isreadonly);
    env_set(L, "checkcaller",       l_checkcaller);
    env_set(L, "setclipboard",      l_setclipboard);
    env_set(L, "toclipboard",       l_setclipboard);
    env_set(L, "getclipboard",      l_getclipboard);

    env_set(L, "newcclosure",       l_newcclosure);
    env_set(L, "iscclosure",        l_iscclosure);
    env_set(L, "islclosure",        l_islclosure);
    env_set(L, "isexecutorclosure", l_isexecutorclosure);
    env_set(L, "getfenv",           l_getfenv_real);
    env_set(L, "setfenv",           l_setfenv_real);
    env_set(L, "getsenv",           l_getsenv);
    env_set(L, "getthreadidentity", l_getthreadidentity);
    env_set(L, "setthreadidentity", l_setthreadidentity);
    env_set(L, "getcallingscript",  l_getcallingscript);
    env_set(L, "getscriptclosure",  l_getscriptclosure);
    env_set(L, "fireclickdetector", l_fireclickdetector);
    env_set(L, "firetouchinterest", l_firetouchinterest);
    env_set(L, "queue_on_teleport", l_queue_on_teleport);
    env_set(L, "queueonteleport",   l_queue_on_teleport);
    env_set(L, "HttpGet",           l_HttpGet);
    env_set(L, "http_request",      l_HttpGet);
    env_set(L, "request",           l_request);

    lua_rawgeti(L, LUA_REGISTRYINDEX, g_scriptEnvRef);
    lua_newtable(L);
    lua_pushcfunction(L, l_crypt_base64encode, "base64encode"); lua_setfield(L, -2, "base64encode");
    lua_pushcfunction(L, l_crypt_base64decode, "base64decode"); lua_setfield(L, -2, "base64decode");
    lua_pushcfunction(L, l_crypt_hash,         "hash");         lua_setfield(L, -2, "hash");
    lua_pushcfunction(L, l_crypt_generatekey,  "generatekey");  lua_setfield(L, -2, "generatekey");
    lua_pushcfunction(L, l_crypt_encrypt,      "encrypt");      lua_setfield(L, -2, "encrypt");
    lua_pushcfunction(L, l_crypt_decrypt,      "decrypt");      lua_setfield(L, -2, "decrypt");
    lua_setfield(L, -2, "crypt");
    lua_newtable(L);
    lua_pushcfunction(L, l_crypt_base64encode, "encode"); lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, l_crypt_base64decode, "decode"); lua_setfield(L, -2, "decode");
    lua_setfield(L, -2, "base64");
    lua_pop(L, 1);

    lua_rawgeti(L, LUA_REGISTRYINDEX, g_scriptEnvRef);
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
