#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "luacode.h"

#ifdef __cplusplus
}
#endif

void neko_register_api(lua_State* L);
void neko_install_hooks(lua_State* L);
