local state = rawget(_G, 'CowboyBingusModLoader')
if state then return end
state = {version = 15, api = 1, modules = {}}
rawset(_G, 'CowboyBingusModLoader', state)

-- One directory and one filesystem setup per session for every mod's logs.
-- Failure to create/write diagnostics must never stop gameplay loading.
local logs_initialized = false
function state.open_log(name)
    if type(name) ~= 'string' or not name:match('^[%w_-]+%.log$') then return nil end
    if not logs_initialized then
        logs_initialized = true
        local ok, directory = pcall(function()
            local base = os.getenv('LOCALAPPDATA')
            if not base or base == '' then return nil end
            local ffi = require('ffi')
            ffi.cdef [[int CreateDirectoryA(const char *path, void *security); uint32_t GetLastError(void);]]
            local kernel = ffi.load('kernel32')
            for _, part in ipairs({'CowboyBingus', 'Helldivers2', 'Logs'}) do
                base = base .. '/' .. part
                if kernel.CreateDirectoryA(base, nil) == 0 and kernel.GetLastError() ~= 183 then return nil end
            end
            return base
        end)
        if ok then state.log_directory = directory end
    end
    if not state.log_directory then return nil end
    local ok, file = pcall(io.open, state.log_directory .. '/' .. name, 'w')
    if ok then return file end
end

local function report(name, status)
    state.modules[name] = status
    print('[BingusSharedLoader] ' .. name .. ': ' .. status)
    pcall(function()
        local file = state.open_log('BingusSharedLoader.log')
        if not file then return end
        file:write('Bingus Shared Loader loader-v14; API 1\n')
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
    'mods/cowboybingus/corpse_collision_repair',
    'mods/cowboybingus/vehicle_stability',
    'mods/cowboybingus/hover_pack_cancel',
    'mods/cowboybingus/enemy_intelligence',
    'mods/codex/gun_calibration',
    'mods/cowboybingus/armory_preview_cache',
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
