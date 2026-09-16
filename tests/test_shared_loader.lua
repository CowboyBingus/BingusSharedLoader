local source, build = assert(arg[1]), assert(arg[2])
local names = {'mods/cowboybingus/better_stratagem_bounce', 'mods/cowboybingus/hellpod_steering_unlocked',
               'mods/cowboybingus/wide_angle_stratagems', 'mods/cowboybingus/reinforcement_beacon_fix_data',
               'mods/cowboybingus/consistent_vaulting', 'mods/cowboybingus/shallow_water_dive',
               'mods/cowboybingus/sentry_aim_retention', 'mods/codex/gun_calibration',
               'mods/cowboybingus/vanilla_plus_megapack', 'mods/cowboybingus/corpse_collision_repair', 'mods/cowboybingus/vehicle_stability', 'mods/cowboybingus/hover_pack_cancel', 'mods/cowboybingus/enemy_intelligence'}

local function environment(audio)
    local env = setmetatable({print = function() end, os = {getenv = function() end},
        stingray = {Application = {build = function() return 'release' end}}}, {__index = _G})
    env._G = env
    if audio then env.stingray.Wwise = {} end
    env.loadstring = function(bytes, name)
        local chunk, reason = loadstring(bytes, name)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    return env
end

local function execute(path, env)
    return setfenv(assert(loadfile(path)), env)()
end

for _, audio in ipairs({false, true}) do
  for mask = 0, 8191 do
    for _, failure in ipairs({'none', 'lookup', 'first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth', 'ninth', 'tenth', 'eleventh', 'twelfth', 'thirteenth'}) do
        local env, vanilla = environment(audio), environment(audio)
        local count, updates, hud_updates = {}, 0, 0
        local function required(name)
            assert(name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference')
            return {}
        end
        vanilla.require = required
        execute(build .. '/vanilla-callbacks.ljbc', vanilla)
        execute(build .. '/vanilla-boot.ljbc', env)
        local original_init, original_shutdown = env.init, env.shutdown
        env.update = function(dt, marker)
            assert(dt == 0.1 and marker == 'marker')
            updates = updates + 1
            return 1, nil, 3
        end
        local present = {}
        for i, name in ipairs(names) do present[name] = math.floor(mask / 2^(i-1)) % 2 == 1 end
        env.stingray.Application.can_get = function(kind, name)
            assert(kind == 'lua' and present[name] ~= nil)
            if failure == 'lookup' then error('lookup failure') end
            return present[name]
        end
        env.require = function(name)
            if name == 'core/wwise/lua/wwise_flow_callbacks' then
                execute(build .. '/callbacks.ljbc', env)
                return true
            end
            if present[name] ~= nil then
                assert(present[name], 'Missing resource reached require')
                count[name] = (count[name] or 0) + 1
                if failure == 'first' and name == names[1] or failure == 'second' and name == names[2]
                    or failure == 'third' and name == names[3] or failure == 'fourth' and name == names[4]
                    or failure == 'fifth' and name == names[5] or failure == 'sixth' and name == names[6]
                    or failure == 'seventh' and name == names[7] or failure == 'eighth' and name == names[8]
                    or failure == 'ninth' and name == names[9] or failure == 'tenth' and name == names[10] or failure == 'eleventh' and name == names[11] or failure == 'twelfth' and name == names[12]
                    or failure == 'thirteenth' and name == names[13] then
                    error('module failure')
                end
                local previous = env.update
                env.update = function(...) return previous(...) end
                return true
            end
            return required(name)
        end
        env.init()
        assert(env.CowboyBingusModLoader.version == 13 and env.CowboyBingusModLoader.api == 1)
        local previous = env.update
        env.update = function(...)
            hud_updates = hud_updates + 1
            return previous(...)
        end
        -- HUD+ installs another update wrapper after boot initialization.
        execute(source .. '/shared_loader.lua', env)
        local a, b, c = env.update(0.1, 'marker')
        assert(a == 1 and b == nil and c == 3 and select('#', env.update(0.1, 'marker')) == 3)
        assert(updates == 2 and hud_updates == 2 and env.init == original_init and env.shutdown == original_shutdown)
        for name in pairs(env.CowboyBingusModLoader.modules) do
            assert(present[name] ~= nil, 'Unexpected module reached the coordinator')
        end
        for _, name in ipairs(names) do
            assert((count[name] or 0) == (present[name] and failure ~= 'lookup' and 1 or 0))
            local status = env.CowboyBingusModLoader.modules[name]
            assert(type(status) == 'string')
            if failure == 'none' then assert(status == (present[name] and 'loaded' or 'not installed')) end
        end
        local callbacks = 0
        for name, callback in pairs(vanilla.WwiseFlowCallbacks) do
            assert(string.dump(callback, true) == string.dump(env.WwiseFlowCallbacks[name], true))
            callbacks = callbacks + 1
        end
        assert(callbacks > 25)
    end
  end
end
local env = environment(false)
execute(source .. '/shared_loader.lua', env)
assert(env.CowboyBingusModLoader.modules[names[1]]:find('lookup failed', 1, true))
print('PASS: shared coordinator covers all 8192 mod combinations, lookup/module failure isolation, duplicate loads, update returns and original audio callbacks')
