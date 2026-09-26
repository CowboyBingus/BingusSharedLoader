"""Run test_jit_budget_game.lua in the installed game's own lua51.dll (LuaJIT 2.1.0-alpha).

The DLL is loaded into this test process only; the game is never started or touched.
Without an installed game (or HD2_LUA51_DLL) the check is skipped.
"""
import ctypes as c
import os
from pathlib import Path
import sys

TEST = Path(__file__).with_name('test_jit_budget_game.lua')


def game_dll():
    configured = os.environ.get('HD2_LUA51_DLL')
    if configured:
        return Path(configured)
    base = Path(os.environ.get('PROGRAMFILES(X86)', r'C:\Program Files (x86)'))
    return base / 'Steam/steamapps/common/Helldivers 2/bin/lua51.dll'


def main():
    source = Path(sys.argv[1]).resolve()
    path = game_dll()
    if os.name != 'nt' or not path.is_file():
        print('SKIP: game LuaJIT not installed; JIT cache budget checked against a stand-in only')
        return
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
        chunk = ("arg = {[0] = %r, %r}\n" % (TEST.as_posix(), source.as_posix())).encode()
        chunk += TEST.read_bytes()
        status = dll.luaL_loadbuffer(state, chunk, len(chunk), b'@test_jit_budget_game.lua')
        if status == 0:
            status = dll.lua_pcall(state, 0, 1, 0)
        message = dll.lua_tolstring(state, -1, None)
        message = message.decode(errors='replace') if message else '<no result>'
        if status:
            raise RuntimeError('Game LuaJIT check failed: ' + message)
    finally:
        dll.lua_close(state)
    print('PASS: game LuaJIT cache budget (' + message + ')')


if __name__ == '__main__':
    main()
