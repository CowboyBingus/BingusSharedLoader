local base, source = assert(arg[1]):gsub('\\', '/'), assert(arg[2]):gsub('\\', '/')
local ffi, bit = require('ffi'), require('bit')
local resources = dofile(base .. '/resources.lua')
local legacy = 'mods/cowboybingus/vanilla_plus_megapack'
local bounce = 'mods/cowboybingus/better_stratagem_bounce'
local good = 'mods/new_author/group/Example_2'
local owned, pending = 'mods/new_author/owned', 'mods/new_author/in_progress'
local broken, unavailable = 'mods/new_author/broken', 'mods/new_author/unavailable'

for _, mode in ipairs({'normal', 'noffi', 'enumeration_error', 'bad_path', 'stock_error'}) do
    local calls, order, scans = {}, {}, 0
    local native_ffi = setmetatable({}, {__index = ffi})
    native_ffi.load = function(name)
        assert(name == 'kernel32')
        local kernel = ffi.load(name)
        return setmetatable({GetModuleFileNameA = function(module, buffer, capacity)
            assert(module == nil)
            local path = mode == 'bad_path' and 'relative/bin/helldivers2.exe' or base .. '/bin/helldivers2.exe'
            assert(capacity > #path); ffi.copy(buffer, path); return #path
        end, FindFirstFileA = function(pattern, buffer)
            scans = scans + 1
            if mode == 'enumeration_error' then error('enumeration unavailable') end
            return kernel.FindFirstFileA(pattern, buffer)
        end}, {__index = function(_, key) return kernel[key] end})
    end
    local env = setmetatable({print = function() end, os = {getenv = function() end},
        package = {loaded = mode == 'noffi' and {} or {ffi = native_ffi, bit = bit}, preload = {}},
        stock_error = mode == 'stock_error',
        HD2ModLoader = {modules = {[owned] = 'loaded', [pending] = 'loading'}},
        stingray = {Application = {can_get = function(kind, name)
            assert(kind == 'lua'); return resources[name] ~= nil and name ~= unavailable
        end}}}, {__index = _G})
    env._G = env
    env.loadstring = function(bytes, name)
        local chunk, reason = loadstring(bytes, name)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    env.require = function(name)
        assert(resources[name], 'Unknown module or builtin reached engine require: ' .. name)
        assert((env.stock_calls or 0) == 1, 'Addon ran before stock startup')
        assert(env.CowboyBingusModLoader.modules[name] == 'loading', 'Missing reentrant guard')
        calls[name] = (calls[name] or 0) + 1; order[#order + 1] = name
        -- Reentering the coordinator must not initialize this or subsequent mods twice.
        setfenv(assert(loadfile(source .. '/shared_loader.lua')), env)()
        return setfenv(assert(loadfile(resources[name])), env)(name)
    end
    local startup = setfenv(assert(loadfile(base .. '/startup.ljbc')), env)
    if mode == 'stock_error' then
        local ok, reason = pcall(startup, 'argument', nil, 'last')
        assert(not ok and tostring(reason):find('native startup failed', 1, true))
        assert(env.stock_calls == 1 and #order == 0 and scans == 0)
    else
        local function results(...)
            assert(select('#', ...) == 4)
            local a, b, c, d = ...; assert(a == 'first' and b == nil and c == 3 and d == nil)
        end
        results(startup('argument', nil, 'last'))
        assert(env.stock_calls == 1 and env.CowboyBingusModLoader.api == 1)
        assert(order[1] == legacy and order[2] == bounce, 'Legacy order changed')
        assert(calls[legacy] == 1 and calls[bounce] == 1)
        if mode == 'normal' then
            assert(scans == 1 and calls[good] == 1 and calls['mods/patpatpatrick/example_addon'] == 1)
            assert(calls[broken] == 1 and not calls[owned] and not calls[pending] and not calls[unavailable])
            local state = env.CowboyBingusModLoader
            assert(state.modules[broken]:find('intentional addon failure', 1, true))
            assert(state.modules[owned] == 'loaded' and state.modules[pending] == 'loading')
            assert(state.modules[unavailable] == 'not installed' and #order == 5)
            assert(state.discovery:find('7 declared entries', 1, true))
            -- A module initialized by an earlier addon must also be respected.
        else
            assert(#order == 2 and env.CowboyBingusModLoader.discovery:find('failed:', 1, true))
        end
        setfenv(assert(loadfile(source .. '/shared_loader.lua')), env)()
        assert(calls[legacy] == 1 and calls[bounce] == 1)
    end
end
print('PASS: compiled bootstrap, real Windows enumeration, independent addon packages, legacy order, API 1, failure/reentry isolation, dispatcher coexistence and stock arguments/results')
