"""Run a Lua test inside the installed game's own lua51.dll (LuaJIT 2.1.0-alpha).

Usage: game_lua.py <test.lua> [args...]. The DLL is loaded into this process only;
the game is never started or touched. Without an installed game (or HD2_LUA51_DLL)
the test is skipped. The test's print output is returned through the Lua state.
"""
import ctypes as c
import os
from pathlib import Path
import sys


def game_dll():
    configured = os.environ.get('HD2_LUA51_DLL')
    if configured:
        return Path(configured)
    base = Path(os.environ.get('PROGRAMFILES(X86)', r'C:\Program Files (x86)'))
    return base / 'Steam/steamapps/common/Helldivers 2/bin/lua51.dll'


def lua_string(text):
    return '"' + ''.join('\\%03d' % b for b in text.encode()) + '"'


def main():
    test = Path(sys.argv[1]).resolve()
    path = game_dll()
    if os.name != 'nt' or not path.is_file():
        print('SKIP: game LuaJIT not installed; ' + test.name + ' ran in the workspace LuaJIT only')
        return
    args = [Path(a).resolve().as_posix() if os.path.exists(a) else a for a in sys.argv[2:]]
    chunk = '\n'.join([
        'local out = {}',
        'print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end'
        ' out[#out + 1] = table.concat(t, " ") end',
        'arg = {[0] = %s%s}' % (lua_string(test.as_posix()), ''.join(', ' + lua_string(a) for a in args)),
        'local ok, err = pcall(dofile, arg[0])',
        'if not ok then error(tostring(err), 0) end',
        'return table.concat(out, "\\n")',
    ]).encode()
    dll = c.CDLL(str(path))
    dll.luaL_newstate.restype = c.c_void_p
    dll.luaL_openlibs.argtypes = [c.c_void_p]
    dll.luaL_loadbuffer.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t, c.c_char_p]
    dll.lua_pcall.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int]
    dll.lua_tolstring.argtypes = [c.c_void_p, c.c_int, c.c_void_p]
    dll.lua_tolstring.restype = c.c_char_p
    dll.lua_close.argtypes = [c.c_void_p]
    state = dll.luaL_newstate()
    if not state:
        raise RuntimeError('Could not create a game Lua state')
    try:
        dll.luaL_openlibs(state)
        status = dll.luaL_loadbuffer(state, chunk, len(chunk), b'=game_lua')
        if status == 0:
            status = dll.lua_pcall(state, 0, 1, 0)
        message = dll.lua_tolstring(state, -1, None)
        message = message.decode(errors='replace') if message else '<no result>'
    finally:
        dll.lua_close(state)
    if status:
        raise RuntimeError('Game LuaJIT test failed (' + test.name + '): ' + message)
    print(message.strip() + ' [game lua51.dll]')


if __name__ == '__main__':
    main()
