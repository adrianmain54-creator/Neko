#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "Neko.h"
#include <string.h>
#include <pthread.h>

#define NEKO_GENV_KEY    "neko.genv"
#define NEKO_MAX_TRACKED 64

// ─── state ────────────────────────────────────────────────────────────────
static lua_State* g_injectedL = nullptr;
static lua_State* g_mainL = nullptr;
static lua_CFunction g_origNamecall = nullptr;
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

// ─── hook ─────────────────────────────────────────────────────────────────
static int neko_namecall_hook(lua_State* L);

static int namecall_cont(lua_State* L, int status, lua_KContext ctx) {
    if (status != LUA_OK && status != LUA_YIELD) return lua_error(L);
    return lua_gettop(L);
}

static int passthrough(lua_State* L) {
    if (!g_origNamecall) { lua_pushnil(L); return 1; }
    int nargs = lua_gettop(L) - 1;
    if (nargs < 0) { lua_pushnil(L); return 1; }
    lua_pushcfunction(L, g_origNamecall);
    lua_insert(L, 1);
    lua_callk(L, nargs, LUA_MULTRET, 0, namecall_cont);
    return lua_gettop(L);
}

static int neko_namecall_hook(lua_State* L) {
    if (is_tracked_state(L)) return passthrough(L);
    const char* m = lua_namecallatom(L, nullptr);
    if (m) { strncpy(g_namecallMethod, m, 63); g_namecallMethod[63] = 0; }
    return passthrough(L);
}

void neko_install_hooks(lua_State* L) {
    if (!L) return;
    if (!g_injectedL) g_injectedL = L;
    if (!g_mainL)     g_mainL     = L;

    lua_getglobal(L, "game");
    if (!lua_getmetatable(L, -1)) { lua_pop(L, 1); return; }

    lua_getfield(L, -1, "__namecall");
    if (lua_iscfunction(L, -1) && !g_origNamecall) g_origNamecall = lua_tocfunction(L, -1);
    lua_pop(L, 1);
    if (!g_origNamecall) { lua_pop(L, 2); return; }

    lua_setreadonly(L, -1, 0);
    lua_pushcclosure(L, neko_namecall_hook, 0);
    lua_setfield(L, -2, "__namecall");
    lua_setreadonly(L, -1, 1);
    lua_pop(L, 2);
}

// ─── stdlib ───────────────────────────────────────────────────────────────
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
        data = [d retain];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (data) { lua_pushlstring(L, (const char*)data.bytes, data.length); [data release]; return 1; }
    lua_pushnil(L); return 1;
}

static int l_getgenv(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, NEKO_GENV_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, NEKO_GENV_KEY);
    }
    return 1;
}

static int l_getreg(lua_State* L) { lua_pushvalue(L, LUA_REGISTRYINDEX); return 1; }

static int l_loadstring(lua_State* L) {
    size_t len = 0;
    const char* src = luaL_checklstring(L, 1, &len);
    if (luau_load(L, "=neko", src, len, 0) != 0) return lua_error(L);
    lua_getfield(L, LUA_REGISTRYINDEX, NEKO_GENV_KEY);
    if (!lua_isnil(L, -1)) lua_setfenv(L, -2);
    else lua_pop(L, 1);
    return 1;
}

static int l_identify(lua_State* L)          { lua_pushliteral(L, "Neko/1.1"); return 1; }
static int l_getnamecallmethod(lua_State* L) { if (g_namecallMethod[0]) lua_pushstring(L, g_namecallMethod); else lua_pushnil(L); return 1; }
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

void neko_register_api(lua_State* L) {
    lua_pushcfunction(L, l_getgenv,           "getgenv");           lua_setglobal(L, "getgenv");
    lua_pushcfunction(L, l_getreg,            "getreg");            lua_setglobal(L, "getreg");
    lua_pushcfunction(L, l_loadstring,        "loadstring");        lua_setglobal(L, "loadstring");
    lua_pushcfunction(L, l_identify,          "identifyexecutor");  lua_setglobal(L, "identifyexecutor");
    lua_pushcfunction(L, l_getnamecallmethod, "getnamecallmethod"); lua_setglobal(L, "getnamecallmethod");
    lua_pushcfunction(L, l_getrawmetatable,   "getrawmetatable");   lua_setglobal(L, "getrawmetatable");
    lua_pushcfunction(L, l_setrawmetatable,   "setrawmetatable");   lua_setglobal(L, "setrawmetatable");
    lua_pushcfunction(L, l_islclosed,         "islclosed");         lua_setglobal(L, "islclosed");
    lua_pushcfunction(L, l_setreadonly,       "setreadonly");       lua_setglobal(L, "setreadonly");
    lua_pushcfunction(L, l_isreadonly,        "isreadonly");        lua_setglobal(L, "isreadonly");
    lua_pushcfunction(L, l_checkcaller,       "checkcaller");       lua_setglobal(L, "checkcaller");
    lua_pushcfunction(L, l_setclipboard,      "setclipboard");      lua_setglobal(L, "setclipboard");
    lua_pushcfunction(L, l_setclipboard,      "toclipboard");       lua_setglobal(L, "toclipboard");
    lua_pushcfunction(L, l_getclipboard,      "getclipboard");      lua_setglobal(L, "getclipboard");

    lua_getglobal(L, "game");
    if (lua_getmetatable(L, -1)) {
        lua_pushcfunction(L, l_HttpGet, "HttpGet");  lua_setfield(L, -2, "HttpGet");
        lua_pushcfunction(L, l_HttpGet, "request");  lua_setfield(L, -2, "request");
        lua_pushcfunction(L, l_getgenv, "getgenv");  lua_setfield(L, -2, "getgenv");
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}
