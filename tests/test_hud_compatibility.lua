local loader, bounce, hellpod, fixture, reinforcement = arg[1], arg[2], arg[3], arg[4], arg[5]
local resource_files = {
    ['boot'] = fixture .. '/f476df93691895fa.lua.main',
    ['mods/hd2_hud/frag_gauge'] = fixture .. '/8695397a5ee5b670.lua.main',
    ['mods/hd2_hud/frag_numbers'] = fixture .. '/d8c251eabb67f38b.lua.main',
    ['mods/hd2_hud/frag_icon'] = fixture .. '/b02f08943274cb87.lua.main',
    ['mods/hd2_hud/frag_idle'] = fixture .. '/c622e294f0394777.lua.main',
    ['core/wwise/lua/wwise_flow_callbacks'] = loader .. '/callbacks.lua.main',
    ['mods/cowboybingus/better_stratagem_bounce'] = bounce .. '/mod.lua.main',
    ['mods/cowboybingus/hellpod_steering_unlocked'] = hellpod .. '/mod.lua.main',
}
if reinforcement then
    resource_files['mods/cowboybingus/reinforcement_beacon_fix_data'] = reinforcement .. '/mod.lua.main'
end
local loader_bit = reinforcement and 8 or 4
for mask = 0, loader_bit * 2 - 1 do
    local loader_installed = mask >= loader_bit
    resource_files['core/wwise/lua/wwise_flow_callbacks'] = loader ..
        (loader_installed and '/callbacks.lua.main' or '/vanilla-callbacks.lua.main')
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env._G = env
    env.print = function() end
    env.os = {getenv = function() end, clock = os.clock}
    env.io = {open = function() return nil end}
    env.stingray = {Application = {build = function() return 'release' end}}
    local installed = {
        ['mods/cowboybingus/better_stratagem_bounce'] = mask % 2 == 1,
        ['mods/cowboybingus/hellpod_steering_unlocked'] = mask % 4 >= 2,
        ['mods/cowboybingus/wide_angle_stratagems'] = false,
        ['mods/cowboybingus/reinforcement_beacon_fix_data'] = reinforcement ~= nil and mask % 8 >= 4,
    }
    env.stingray.Application.can_get = function(kind, name)
        assert(kind == 'lua' and installed[name] ~= nil)
        return installed[name]
    end
    env.loadstring = function(bytes, name)
        local chunk, reason = loadstring(bytes, name)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    local required, loaded = {}, {}
    env.require = function(name)
        if loaded[name] then return loaded[name] end
        if name == 'ffi' or name == 'bit' then return require(name) end
        if name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference' then return {} end
        local file = assert(io.open(assert(resource_files[name], name), 'rb'))
        local bytes = file:read('*a'); file:close()
        required[name] = (required[name] or 0) + 1
        loaded[name] = assert(env.loadstring(bytes:sub(9), '@' .. name))() or true
        return loaded[name]
    end
    local result = env.require('boot')
    assert(result.installed == true, 'HUD+ failed to install its actual update callback')
    local hud = env.update
    local calls = 0
    env.update = function(...)
        calls = calls + 1
        return hud(...)
    end
    local shutdown = env.shutdown
    env.init()
    for _ = 1, 3 do env.update(0.1) end
    assert(calls == 3 and env.shutdown == shutdown)
    for name, present in pairs(installed) do
        assert((required[name] or 0) == (loader_installed and present and 1 or 0))
    end
    assert((rawget(env, 'BetterStratagemBounce') ~= nil) == (loader_installed and installed['mods/cowboybingus/better_stratagem_bounce']))
    assert((rawget(env, 'HellpodSteeringUnlocked') ~= nil) == (loader_installed and installed['mods/cowboybingus/hellpod_steering_unlocked']))
    assert((rawget(env, 'ReinforcementBeaconFixData') ~= nil) == (loader_installed and installed['mods/cowboybingus/reinforcement_beacon_fix_data']))
    assert((rawget(env, 'CowboyBingusModLoader') ~= nil) == loader_installed)

end
print('PASS: unmodified HUD+ boot and fragments retain their update chain; module-only packages stay inactive without the loader; every installed combination starts once')
