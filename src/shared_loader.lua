local state = rawget(_G, 'CowboyBingusModLoader')
if state then return end
state = {version = 8, api = 1, modules = {}}
rawset(_G, 'CowboyBingusModLoader', state)

local function report(name, status)
    state.modules[name] = status
    print('[BingusSharedLoader] ' .. name .. ': ' .. status)
    pcall(function()
        local directory = os.getenv('LOCALAPPDATA')
        if not directory then return end
        local file = io.open(directory .. '/BingusSharedLoader.log', 'w')
        if not file then return end
        file:write('Bingus Shared Loader loader-v7; API 1\n')
        for module, result in pairs(state.modules) do
            file:write(module .. ': ' .. result .. '\n')
        end
        file:close()
    end)
end

local application = stingray and stingray.Application
for _, name in ipairs({
    'mods/cowboybingus/vanilla_plus_megapack',
    'mods/cowboybingus/better_stratagem_bounce',
    'mods/cowboybingus/hellpod_steering_unlocked',
    'mods/cowboybingus/wide_angle_stratagems',
    'mods/cowboybingus/reinforcement_beacon_fix_data',
    'mods/cowboybingus/consistent_vaulting',
    'mods/cowboybingus/shallow_water_dive',
    'mods/cowboybingus/sentry_aim_retention',
    'mods/codex/gun_calibration',
}) do
    local ok, available = pcall(function()
        assert(application and type(application.can_get) == 'function', 'resource lookup unavailable')
        return application.can_get('lua', name)
    end)
    if not ok then
        report(name, 'lookup failed: ' .. tostring(available))
    elseif not available then
        -- Missing resources must never reach the engine's require path.
        report(name, 'not installed')
    else
        local loaded, reason = pcall(require, name)
        report(name, loaded and 'loaded' or 'load failed: ' .. tostring(reason))
    end
end
