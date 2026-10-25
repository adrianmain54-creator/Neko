#pragma once
#include <stdint.h>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "luacode.h"
}

void neko_register_api(lua_State* L);
void neko_install_hooks(lua_State* L);
