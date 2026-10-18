-- Test fixture for the loader's build gate (src/build_gate.lua): which game build
-- the gate sees in a test process, which has no game.dll and whose executable is
-- LuaJIT or Python. Load with dofile(<tests>/build_fixture.lua).
--
-- fixture.library(ffi_like, options): an ffi stand-in for env.package.loaded.ffi.
--   load('kernel32') wraps the real library: the runtime's GetModuleHandleA answers
--   a handle for game.dll (none with options.no_game) and its GetModuleFileNameW
--   answers options.exe_path and options.game_path for the two modules (the
--   default fixture paths otherwise; 0 with options.no_name). Every other name, and
--   every other library, is the real one. ffi_like defaults to the real ffi.
-- fixture.known(env [, ffi_like]): a supported build. env.package gets the stand-in
--   and env.BingusRuntime holds the pinned hashes of both fixture paths, so the gate
--   reads no file; returns the stand-in.
-- fixture.supported_gate(): a gate for direct-source runs (the global build_gate),
--   which always reports the supported build.
-- fixture.EXE_SHA256, fixture.GAME_SHA256: the release pins, from scripts/archive.py.
local ffi = require('ffi')
local fixture = {}

local here = debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or './'
do
    local file = assert(io.open(here .. '../scripts/archive.py', 'rb'))
    local text = file:read('*a'); file:close()
    fixture.EXE_SHA256 = assert(text:match("\nEXE_SHA = '(%x+)'"), 'no EXE_SHA in archive.py')
    fixture.GAME_SHA256 = assert(text:match("\nGAME_DLL_SHA = '(%x+)'"), 'no GAME_DLL_SHA in archive.py')
end
fixture.EXE_PATH, fixture.GAME_PATH = 'C:/BuildFixture/bin/helldivers2.exe', 'C:/BuildFixture/data/game/game.dll'

-- Never dereferenced: only compared and passed back to the fixture.
local GAME_HANDLE = ffi.cast('void *', 0x7FFE0000)

local function utf16(text) return (text:gsub('.', '%0\0')) end
function fixture.key(path) return 'sha256:' .. utf16(path) end

local function address(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end

-- The runtime declares its names before it binds them, so the real functions are
-- looked up only when called.
local function kernel_stand_in(kernel, options)
    local exe_path, game_path = options.exe_path or fixture.EXE_PATH, options.game_path or fixture.GAME_PATH
    local own = {}
    function own.bingus_memory1_GetModuleHandleA(name)
        if name ~= nil and (type(name) == 'string' and name or ffi.string(name)) == 'game.dll' then
            return not options.no_game and GAME_HANDLE or nil
        end
        return kernel.bingus_memory1_GetModuleHandleA(name)
    end
    function own.bingus_memory1_GetModuleFileNameW(module, buffer, capacity)
        if options.no_name then return 0 end
        local which, exe = address(module), address(kernel.bingus_memory1_GetModuleHandleA(nil))
        local path = (which == 0 or which == exe) and exe_path or which == address(GAME_HANDLE) and game_path
        if not path then return kernel.bingus_memory1_GetModuleFileNameW(module, buffer, capacity) end
        local wide = utf16(path) .. '\0\0'
        assert(#wide / 2 <= capacity)
        ffi.copy(buffer, wide, #wide)
        return #path
    end
    return setmetatable(own, {__index = function(_, name) return kernel[name] end})
end

function fixture.library(ffi_like, options)
    ffi_like, options = ffi_like or ffi, options or {}
    local loads = {}
    local stand_in = setmetatable({loads = loads, load = function(name)
        loads[#loads + 1] = name
        local library = ffi_like.load(name)
        if name == 'kernel32' then return kernel_stand_in(library, options) end
        return library
    end}, {__index = ffi_like})
    return stand_in
end

local function package_with(library, base)
    base = base or package
    local loaded = setmetatable({ffi = library}, {__index = base.loaded})
    return setmetatable({loaded = loaded}, {__index = base})
end
fixture.package_with = package_with

function fixture.known(env, ffi_like)
    local library = fixture.library(ffi_like)
    local base = rawget(env, 'package') or package
    rawset(env, 'package', package_with(library, base))
    rawset(env, 'BingusRuntime', {hashes = {[fixture.key(fixture.EXE_PATH)] = fixture.EXE_SHA256,
                                            [fixture.key(fixture.GAME_PATH)] = fixture.GAME_SHA256}})
    return library
end

function fixture.supported_gate()
    return {check = function()
        return {supported = true, exe_sha256 = fixture.EXE_SHA256, game_sha256 = fixture.GAME_SHA256}
    end}
end

return fixture
