#pragma once
#include <stdint.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "luacode.h"

#ifdef __cplusplus
extern "C" {
#endif

void neko_register_api(lua_State* L);
void neko_install_hooks(lua_State* L);

// implemented in Neko.mm — returns the live injected lua_State
lua_State* neko_get_state(void);
void neko_set_state(lua_State* L);

// implemented in Api.mm — script-thread tracking for checkcaller
void neko_track_state(lua_State* L);
void neko_untrack_state(lua_State* L);

extern char g_namecallMethod[64];

#ifdef __cplusplus
}
#endif
