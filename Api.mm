#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "Neko.h"
#include <dlfcn.h>
#include <string.h>
#include <pthread.h>

static lua_State* g_mainL = nullptr;
static pthread_key_t g_threadKey;
static pthread_once_t g_keyOnce = PTHREAD_ONCE_INIT;

char g_namecallMethod[64] = {0};

static lua_CFunction g_origNamecall = nullptr;

// upvalue indices for the wrapper closure
#define UPV_ORIG   1
#define UPV_WRAPPER 2

static void make_key() { pthread_key_create(&g_threadKey, nullptr); }
static inline int on_executor_thread() { return pthread_getspecific(g_threadKey) != nullptr; }
static inline void mark_executor_thread(int v) { pthread_setspecific(g_threadKey, v ? (void*)1 : nullptr); }

// FILL: hook your real state accessor here
static lua_State* get_roblox_state() {
    if (!g_mainL) {
        void* addr = dlsym(RTLD_DEFAULT, "lua_newstate");
        if (addr) g_mainL = ((lua_State*(*)(void*, void*))addr)(nullptr, nullptr);
    }
    return g_mainL;
}

static int neko_namecall_hook(lua_State* L);

// --- wrapper: takes the original __namecall and returns a Luau-visible function
// that, when invoked, runs our hook and then calls the original ---
// this is the iOS/C++ equivalent of newcclosure: the thing the game sees is a
// regular Lua closure, not a raw C function.
static int neko_wrapper(lua_State* L) {
    // upvalue 1 = original C function
    int nargs = lua_gettop(L);
    lua_pushvalue(L, lua_upvalueindex(UPV_ORIG));   // push original
    lua_insert(L, 1);                               // move to bottom
    lua_call(L, nargs, LUA_MULTRET);                // call with same args
    return lua_gettop(L);
}

// build a Luau closure around neko_namecall_hook so the game sees a Lua fn
static void push_wrapped_hook(lua_State* L) {
    // wrapper closure with original as upvalue
    lua_pushcclosure(L, g_origNamecall, 1);
    // now the raw C hook as upvalue 2 of another closure
    lua_pushcclosure(L, neko_namecall_hook, 1);
}

static int neko_namecall_hook(lua_State* L) {
    // upvalue 1 is the original
    if (on_executor_thread() || L == g_mainL) {
        int nargs = lua_gettop(L);
        lua_pushvalue(L, lua_upvalueindex(1));
        lua_insert(L, 1);
        lua_call(L, nargs, LUA_MULTRET);
        return lua_gettop(L);
    }

    // capture the atom under pcall so we don't leak a C error string
    int base = lua_gettop(L);
    lua_pushcfunction(L, [](lua_State* S) -> int {
        const char* a = lua_namecallatom(S, nullptr);
        if (a) lua_pushstring(S, a); else lua_pushnil(S);
        return 1;
    });
    if (lua_pcall(L, 0, 1, 0) == 0 && lua_isstring(L, -1)) {
        const char* s = lua_tostring(L, -1);
        if (s) { strncpy(g_namecallMethod, s, 63); g_namecallMethod[63] = 0; }
    }
    lua_settop(L, base);

    // passthrough
    int nargs = lua_gettop(L);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_insert(L, 1);
    lua_call(L, nargs, LUA_MULTRET);
    return lua_gettop(L);
}

void neko_install_hooks(lua_State* L) {
    if (!L || L != g_mainL) return;

    lua_getglobal(L, "game");
    if (!lua_getmetatable(L, -1)) { lua_pop(L, 1); return; }

    lua_getfield(L, -1, "__namecall");
    if (!lua_iscfunction(L, -1)) { lua_pop(L, 2); return; }
    if (!g_origNamecall) g_origNamecall = lua_tocfunction(L, -1);
    lua_pop(L, 1);

    // single field write, no long readonly window
    lua_setreadonly(L, -1, 0);
    push_wrapped_hook(L);
    lua_setfield(L, -2, "__namecall");
    lua_setreadonly(L, -1, 1);

    lua_pop(L, 2);
}

// --- stdlib ---

static int l_HttpGet(lua_State* L) {
    const char* url = luaL_checkstring(L, 1);
    NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
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
    if (data) {
        NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (str) { lua_pushstring(L, [str UTF8String]); return 1; }
    }
    lua_pushnil(L); return 1;
}

static int l_getgenv(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, "neko.genv");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_newtable(L); lua_pushvalue(L, -1); lua_setfield(L, LUA_REGISTRYINDEX, "neko.genv"); }
    return 1;
}

static int l_loadstring(lua_State* L) {
    size_t len = 0; const char* src = luaL_checklstring(L, 1, &len);
    if (luau_load(L, "=neko", src, len, 0) != 0) { lua_error(L); return 0; }
    return 1;
}

static int l_identify(lua_State* L) { lua_pushstring(L, "Neko"); return 1; }
static int l_getnamecallmethod(lua_State* L) { if (g_namecallMethod[0]) lua_pushstring(L, g_namecallMethod); else lua_pushnil(L); return 1; }

static int l_checkcaller(lua_State* L) {
    lua_pushboolean(L, on_executor_thread() || L == g_mainL);
    return 1;
}

static int l_getrawmetatable(lua_State* L) {
    luaL_checkany(L, 1);
    if (lua_getmetatable(L, 1)) return 1;
    lua_pushnil(L); return 1;
}

static int l_setreadonly(lua_State* L) { luaL_checktype(L, 1, LUA_TTABLE); lua_setreadonly(L, 1, lua_toboolean(L, 2)); return 0; }
static int l_isreadonly(lua_State* L) { luaL_checktype(L, 1, LUA_TTABLE); lua_pushboolean(L, lua_getreadonly(L, 1)); return 1; }
static int l_stub(lua_State* L) { lua_newtable(L); return 1; }

void neko_register_api(lua_State* L) {
    pthread_once(&g_keyOnce, make_key);

    lua_pushcfunction(L, l_getgenv, "getgenv"); lua_setglobal(L, "getgenv");
    lua_pushcfunction(L, l_loadstring, "loadstring"); lua_setglobal(L, "loadstring");
    lua_pushcfunction(L, l_identify, "identifyexecutor"); lua_setglobal(L, "identifyexecutor");
    lua_pushcfunction(L, l_getnamecallmethod, "getnamecallmethod"); lua_setglobal(L, "getnamecallmethod");
    lua_pushcfunction(L, l_getrawmetatable, "getrawmetatable"); lua_setglobal(L, "getrawmetatable");
    lua_pushcfunction(L, l_setreadonly, "setreadonly"); lua_setglobal(L, "setreadonly");
    lua_pushcfunction(L, l_isreadonly, "isreadonly"); lua_setglobal(L, "isreadonly");
    lua_pushcfunction(L, l_checkcaller, "checkcaller"); lua_setglobal(L, "checkcaller");
    lua_pushcfunction(L, l_stub, "getgc"); lua_setglobal(L, "getgc");
    lua_pushcfunction(L, l_stub, "getconnections"); lua_setglobal(L, "getconnections");
    lua_pushcfunction(L, l_stub, "Drawing"); lua_setglobal(L, "Drawing");

    lua_getglobal(L, "game");
    if (lua_getmetatable(L, -1)) {
        lua_pushcfunction(L, l_HttpGet, "HttpGet"); lua_setfield(L, -2, "HttpGet");
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

void neko_begin_executor_tick(void) { mark_executor_thread(1); }
void neko_end_executor_tick(void)   { mark_executor_thread(0); }
