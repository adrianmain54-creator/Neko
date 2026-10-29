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

// state handle — defined in Api.mm, called from your dylib entry
lua_State* neko_get_state(void);
void neko_set_state(lua_State* L);

// script-thread tracking (defined in Api.mm)
void neko_track_state(lua_State* L);
void neko_untrack_state(lua_State* L);

extern char g_namecallMethod[64];

#ifdef __cplusplus
}
#endif
