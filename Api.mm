#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "Neko.h"
#include <dlfcn.h>
#include <substrate.h>
#include <string.h>

static lua_State* g_L = nullptr;
static const char* GENV_REG = "neko.genv";
char g_namecallMethod[64] = {0};

struct Closure {
    uint8_t tt; uint8_t marked; uint8_t isC; uint8_t nupvalues; void* gclist;
    union { struct { void* p; void* execdata; } l; struct { lua_CFunction f; void* cont; } c; };
};

static lua_CFunction orig_namecall = nullptr;

static int namecall_hook(lua_State* L) {
    const char* m = lua_namecallatom(L, nullptr);
    if (m) { strncpy(g_namecallMethod, m, 63); g_namecallMethod[63] = 0; }
    return orig_namecall(L);
}

void neko_install_hooks(lua_State* L) {
    lua_getglobal(L, "game");
    if (lua_getmetatable(L, -1)) {
        lua_getfield(L, -1, "__namecall");
        if (lua_iscfunction(L, -1)) {
            void* target = (void*)lua_tocfunction(L, -1);
            MSHookFunction(target, (void*)namecall_hook, (void**)&orig_namecall);
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 2);
}

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
    lua_getfield(L, LUA_REGISTRYINDEX, GENV_REG);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_newtable(L); lua_pushvalue(L, -1); lua_setfield(L, LUA_REGISTRYINDEX, GENV_REG); }
    return 1;
}

static int l_loadstring(lua_State* L) {
    size_t len = 0; const char* src = luaL_checklstring(L, 1, &len);
    if (luau_load(L, "=neko", src, len, 0) != 0) { lua_error(L); return 0; }
    return 1;
}

static int l_identify(lua_State* L) { lua_pushstring(L, "Neko"); return 1; }
static int l_getnamecallmethod(lua_State* L) { if (g_namecallMethod[0]) lua_pushstring(L, g_namecallMethod); else lua_pushnil(L); return 1; }
static int l_checkcaller(lua_State* L) { lua_pushboolean(L, true); return 1; }

static int l_getrawmetatable(lua_State* L) {
    luaL_checkany(L, 1);
    if (lua_getmetatable(L, 1)) return 1;
    lua_pushnil(L); return 1;
}

static int l_setreadonly(lua_State* L) { luaL_checktype(L, 1, LUA_TTABLE); lua_setreadonly(L, 1, lua_toboolean(L, 2)); return 0; }
static int l_isreadonly(lua_State* L) { luaL_checktype(L, 1, LUA_TTABLE); lua_pushboolean(L, lua_getreadonly(L, 1)); return 1; }

static int l_hookfunction(lua_State* L) {
    Closure* target = (Closure*)lua_topointer(L, 1);
    Closure* hook = (Closure*)lua_topointer(L, 2);
    if (!target || !hook || !target->isC || !hook->isC) return 0;
    lua_CFunction original = target->c.f;
    target->c.f = hook->c.f;
    target->c.cont = hook->c.cont;
    lua_pushcfunction(L, original, "original");
    return 1;
}

static int l_setclipboard(lua_State* L) { const char* str = luaL_checkstring(L, 1); [UIPasteboard generalPasteboard].string = [NSString stringWithUTF8String:str]; return 0; }
static int l_stub(lua_State* L) { lua_newtable(L); return 1; }

void neko_register_api(lua_State* L) {
    lua_pushcfunction(L, l_getgenv, "getgenv"); lua_setglobal(L, "getgenv");
    lua_pushcfunction(L, l_loadstring, "loadstring"); lua_setglobal(L, "loadstring");
    lua_pushcfunction(L, l_loadstring, "require"); lua_setglobal(L, "require");
    lua_pushcfunction(L, l_identify, "identifyexecutor"); lua_setglobal(L, "identifyexecutor");
    lua_pushcfunction(L, l_getnamecallmethod, "getnamecallmethod"); lua_setglobal(L, "getnamecallmethod");
    lua_pushcfunction(L, l_hookfunction, "hookfunction"); lua_setglobal(L, "hookfunction");
    lua_pushcfunction(L, l_getrawmetatable, "getrawmetatable"); lua_setglobal(L, "getrawmetatable");
    lua_pushcfunction(L, l_setreadonly, "setreadonly"); lua_setglobal(L, "setreadonly");
    lua_pushcfunction(L, l_isreadonly, "isreadonly"); lua_setglobal(L, "isreadonly");
    lua_pushcfunction(L, l_checkcaller, "checkcaller"); lua_setglobal(L, "checkcaller");
    lua_pushcfunction(L, l_setclipboard, "setclipboard"); lua_setglobal(L, "setclipboard");
    
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
