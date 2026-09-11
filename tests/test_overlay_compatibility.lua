local build, fixture, hud = assert(arg[1]), assert(arg[2]), assert(arg[3])
local overlay = 'mods/codex/gun_calibration'
local wwise = 'core/wwise/lua/wwise_flow_callbacks'
local names = {overlay, 'mods/cowboybingus/better_stratagem_bounce',
    'mods/cowboybingus/hellpod_steering_unlocked', 'mods/cowboybingus/reinforcement_beacon_fix_data'}
local paths = {
    [overlay] = fixture .. '/overlay.lua.main',
    [names[2]] = fixture .. '/bounce.lua.main',
    [names[3]] = fixture .. '/steering.lua.main',
    [names[4]] = fixture .. '/reinforcement.lua.main',
    ['boot'] = hud .. '/f476df93691895fa.lua.main',
    ['mods/hd2_hud/frag_gauge'] = hud .. '/8695397a5ee5b670.lua.main',
    ['mods/hd2_hud/frag_numbers'] = hud .. '/d8c251eabb67f38b.lua.main',
    ['mods/hd2_hud/frag_icon'] = hud .. '/b02f08943274cb87.lua.main',
    ['mods/hd2_hud/frag_idle'] = hud .. '/c622e294f0394777.lua.main',
}
local function read(path, resource)
    local file = assert(io.open(path, 'rb'))
    local bytes = file:read('*a'); file:close()
    return resource and bytes:sub(9) or bytes
end
local sources = {}
for name, path in pairs(paths) do sources[name] = read(path, true) end
local candidate = read(build .. '/callbacks.ljbc')
local vanilla = read(build .. '/vanilla-callbacks.ljbc')
local boot = read(build .. '/vanilla-boot.ljbc')

local function context(mask, audio, have_ffi)
    local env = {}
    for _, key in ipairs({'assert', 'error', 'getmetatable', 'ipairs', 'next', 'pairs', 'pcall',
        'rawget', 'rawset', 'select', 'setmetatable', 'setfenv', 'tonumber', 'tostring', 'type', 'unpack'}) do
        env[key] = _G[key]
    end
    for _, lib in ipairs({'math', 'string', 'table'}) do
        env[lib] = {}; for key, value in pairs(_G[lib]) do env[lib][key] = value end
    end
    env._G, env.print = env, function() end
    env.os = {getenv = function() end, clock = os.clock}
    local count, available = {}, {['mods/cowboybingus/wide_angle_stratagems'] = false}
    for i, name in ipairs(names) do available[name] = math.floor(mask / 2^(i-1)) % 2 == 1 end
    local observed = {reads = 0, restored = 0, paths = 0, config = '[overlay]\nenabled=false\n'}
    env.io = {open = function(path, mode)
        assert(mode == 'rb' and (path == nil or path == 'C:/Games/Helldivers 2/HUDBTO.ini'))
        if path == nil then return nil end
        observed.reads = observed.reads + 1
        return {read = function(_, limit) assert(limit == 65537); return observed.config end,
            close = function() return true end}
    end}
    env.package = {loaded = {}}
    if have_ffi then
        env.package.loaded.ffi = {
            os = 'Windows', abi = function(value) assert(value == '64bit'); return true end,
            cdef = function(value) assert(value:find('GetModuleFileNameA', 1, true)) end,
            new = function(kind, size) assert(kind == 'char[?]' and size == 32768); return {} end,
            string = function(buffer, size) assert(size == #buffer.path); return buffer.path end,
            C = {GetModuleFileNameA = function(module, buffer, size)
                assert(module == nil and size == 32768)
                observed.paths = observed.paths + 1
                buffer.path = 'C:\\Games\\Helldivers 2\\bin\\helldivers2.exe'
                return #buffer.path
            end},
        }
    end
    env.stingray = {
        Application = {build = function() return 'release' end, main_world = function() return nil end,
            worlds = function() return {} end,
            can_get = function(kind, name)
                assert(kind == 'lua' and available[name] ~= nil, name)
                return available[name]
            end},
        Network = {game_session = function() return nil end},
        Script = {temp_byte_count = function() return 123 end,
            set_temp_byte_count = function(value) assert(value == 123); observed.restored = observed.restored + 1 end},
    }
    if audio then env.stingray.Wwise = {} end
    env.loadstring = function(bytes, name)
        local chunk, reason = loadstring(bytes, name)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    local function execute(bytes, name) return assert(env.loadstring(bytes, name))() end
    env.require = function(name)
        -- Gameplay modules may import FFI, but only the overlay's fake path resolver can run.
        if name == 'ffi' then return env.package.loaded.ffi or {} end
        if name == 'bit' then return require('bit') end
        local cached = env.package.loaded[name]
        if cached ~= nil then return cached end
        if name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference' then return {} end
        if available[name] ~= nil then assert(available[name], 'Missing resource reached require') end
        count[name] = (count[name] or 0) + 1
        local result = execute(name == wwise and candidate or assert(sources[name], name), '@' .. name) or true
        env.package.loaded[name] = result
        return result
    end
    return env, count, execute, available, observed
end

local total = 0
for _, use_hud in ipairs({false, true}) do
  for _, audio in ipairs({false, true}) do
    for mask = 0, 15 do
        local env, count, execute, available, observed = context(mask, audio, true)
        if use_hud then assert(env.require('boot').installed == true)
        else execute(boot, '@vanilla_boot') end
        local prior_update, prior_shutdown = env.update, env.shutdown
        local updates, shutdowns = 0, 0
        env.update = function(dt, marker)
            assert(dt == 0.1 and marker == 'marker'); updates = updates + 1
            prior_update(dt)
            return 1, nil, 3
        end
        env.shutdown = function(marker)
            assert(marker == 'marker'); shutdowns = shutdowns + 1
            prior_shutdown()
            return 'closed', nil, 7
        end
        env.init()
        assert(env.CowboyBingusModLoader.api == 1)
        for name, present in pairs(available) do
            assert((count[name] or 0) == (present and 1 or 0), name)
            assert(env.CowboyBingusModLoader.modules[name] == (present and 'loaded' or 'not installed'),
                name .. ': ' .. tostring(env.CowboyBingusModLoader.modules[name]))
        end
        local control, _, run_control = context(0, audio, false)
        run_control(vanilla, '@vanilla_wwise_callbacks')
        local callbacks = 0
        for name, callback in pairs(control.WwiseFlowCallbacks) do
            assert(string.dump(callback, true) == string.dump(env.WwiseFlowCallbacks[name], true), name)
            callbacks = callbacks + 1
        end
        assert(callbacks > 25)
        local first_update, first_shutdown = env.update, env.shutdown
        execute(candidate, '@duplicate_loader')
        if available[overlay] then env.require(overlay) end
        assert(env.update == first_update and env.shutdown == first_shutdown)
        for _ = 1, 3 do
            local a, b, c = env.update(0.1, 'marker')
            assert(a == 1 and b == nil and c == 3)
        end
        assert(updates == 3)
        assert(observed.paths == (available[overlay] and 1 or 0))
        assert(observed.reads == (available[overlay] and 1 or 0))
        assert(observed.restored == (available[overlay] and 3 or 0))
        observed.config = '[overlay]\nenabled=true\nsquad=true\ndrop_line=false\n'
        for _ = 1, 11 do env.update(0.1, 'marker') end
        assert(observed.reads == (available[overlay] and 2 or 0))
        local a, b, c = env.shutdown('marker')
        assert(a == 'closed' and b == nil and c == 7 and shutdowns == 1)
        assert(observed.restored == (available[overlay] and 14 or 0))
        for name, present in pairs(available) do assert((count[name] or 0) == (present and 1 or 0)) end
        for _, key in ipairs({'BetterStratagemBounce', 'HellpodSteeringUnlocked', 'ReinforcementBeaconFixData'}) do
            assert(not env[key] or not env[key].active, 'Native behavior escaped the test fixture')
        end
        total = total + 1
    end
  end
end

for _, preloaded in ipairs({false, true}) do
    local env, count, execute, _, observed = context(1, true, false)
    execute(boot, '@vanilla_boot')
    if preloaded then env.require(overlay) end
    env.init()
    env.update(0.1)
    assert(count[overlay] == 1 and observed.paths == 0 and observed.reads == 0)
    assert(observed.restored == 1)
    env.shutdown()
end
print('PASS: ' .. total .. ' actual-module startup combinations with Overlay v2, HUD+ and current gameplay packages')
print('PASS: configuration path/read/reload, update/shutdown forwarding, temporary-memory restoration, duplicate startup and missing FFI')
print('PASS: original Wwise callbacks preserved; native gameplay and in-game rendering not exercised')
