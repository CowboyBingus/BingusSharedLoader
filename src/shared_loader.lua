local state = rawget(_G, 'CowboyBingusModLoader')
if state then return end
state = {version = 17, api = 1, modules = {}}
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

local jit_cache
local function write_log()
    pcall(function()
        local file = state.open_log('BingusSharedLoader.log')
        if not file then return end
        file:write('Bingus Shared Loader loader-v18; API 1\n')
        if state.discovery then file:write('Discovery: ' .. state.discovery .. '\n') end
        if jit_cache then file:write(jit_cache.describe() .. '\n') end
        for module, result in pairs(state.modules) do
            file:write(module .. ': ' .. result .. '\n')
        end
        file:close()
    end)
end

local function report(name, status)
    state.modules[name] = status
    print('[BingusSharedLoader] ' .. name .. ': ' .. status)
    write_log()
end

-- The builder embeds src/jit_budget.lua in this lexical scope. The game's
-- LuaJIT code cache is shared by every mod, so its limits are raised before
-- any mod starts. state.jit also tells older fallbacks the loader manages it.
if jit_budget then
    local ok, cache = pcall(jit_budget.start, rawget(_G, 'jit'), {log = write_log})
    if ok then
        jit_cache, state.jit = cache, cache.public
        print('[BingusSharedLoader] ' .. cache.describe())
    else
        state.jit = {managed = false, reason = tostring(cache)}
    end
end

local application = stingray and stingray.Application
local names = {
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
}

-- The builder embeds discovery in this lexical scope. Direct-source legacy tests
-- can still exercise the coordinator without loading native filesystem APIs.
if addon_discovery then
    local ok, entries, warnings = pcall(addon_discovery.discover)
    if ok then
        state.discovery = tostring(#entries) .. ' declared entries'
        local listed = {}
        for _, name in ipairs(names) do listed[name] = true end
        for _, name in ipairs(entries) do
            if not listed[name] then names[#names + 1] = name; listed[name] = true end
        end
        if warnings and #warnings > 0 then
            state.discovery = state.discovery .. '; ' .. table.concat(warnings, '; ')
        end
    else
        state.discovery = 'failed: ' .. tostring(entries)
    end
    print('[BingusSharedLoader] Discovery: ' .. state.discovery)
end

for _, name in ipairs(names) do
    local other = rawget(_G, 'HD2ModLoader')
    local other_status = other and other.modules and other.modules[name]
    if state.modules[name] then
        -- A previous initialization attempt (including failure) is never retried.
    elseif other_status == 'loaded' or other_status == 'loading' then
        report(name, other_status)
    else
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
            state.modules[name] = 'loading'
            local loaded, reason = pcall(require, name)
            report(name, loaded and 'loaded' or 'load failed: ' .. tostring(reason))
        end
    end
end
