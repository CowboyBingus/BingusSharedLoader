local state = rawget(_G, 'CowboyBingusModLoader')
if state then return end
-- version stays 17, as in v18: mods compare it, and nothing they can rely on changed.
state = {version = 17, api = 1, modules = {}, revision = 'loader-v19'}
rawset(_G, 'CowboyBingusModLoader', state)

-- Captured before any mod loads: a mod that replaces one of these globals
-- must not change how the loader reports or loads the mods after it.
local pcall, tostring, ipairs, type, assert, rawget = pcall, tostring, ipairs, type, assert, rawget
local concat, error, setmetatable = table.concat, error, setmetatable
local function ensure(condition, message)
    if not condition then error(message, 0) end
    return condition
end
local open = type(io) == 'table' and io.open or nil
local getenv = type(os) == 'table' and os.getenv or nil

-- What this loader build supports, for mods to test instead of comparing
-- version: api (the API number), logs (open_log and the shared log folder),
-- discovery (declared addon entries), jit_budget (the shared LuaJIT code cache),
-- health (the health report) and after_startup (callbacks run once every module
-- has started). Whether a feature worked this session shows in its own field:
-- discovery, jit.managed, log_directory. Read-only: assigning a field raises.
-- The fields are looked up through the metatable, so pairs() sees none of them.
local capabilities = {api = 1, logs = true, discovery = addon_discovery ~= nil, jit_budget = jit_budget ~= nil,
                      health = loader_health ~= nil, after_startup = true}
state.capabilities = setmetatable({}, {__index = capabilities, __metatable = false,
    __newindex = function() error('CowboyBingusModLoader.capabilities is read-only', 2) end})

local LOG_NAME = 'BingusSharedLoader.log'
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

-- Windows functions under private names, declared once per session. The first
-- ffi.cdef of a name wins for the whole game: plain Windows names would bind the
-- loader to whatever prototype another mod declared first, and impose the
-- loader's prototypes on every mod that declares them later.
local WINDOWS = [[
    int bsl_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
    uint32_t bsl_GetLastError(void) __asm__("GetLastError");
    uint32_t bsl_GetModuleFileNameA(void *module, char *filename, uint32_t size) __asm__("GetModuleFileNameA");
    void *bsl_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    void *bsl_FindFirstFileA(const char *pattern, void *data) __asm__("FindFirstFileA");
    int bsl_FindNextFileA(void *handle, void *data) __asm__("FindNextFileA");
    int bsl_FindClose(void *handle) __asm__("FindClose");
]]
local FUNCTIONS = {'CreateDirectoryA', 'GetLastError', 'GetModuleFileNameA', 'GetModuleHandleA',
                   'FindFirstFileA', 'FindNextFileA', 'FindClose'}

-- Loader v18 also declared these plain names, for every mod: the log pair when
-- a log was first opened, the discovery set before any mod loaded. Mods written
-- against v18 may call them without declaring them, and get these prototypes in
-- place of their own later declarations. v19 makes the same declarations at the
-- same moments, so every mod sees what it saw under v18; the loader itself
-- calls only the private names above.
local V18_LOG_DECLARATIONS = [[
    int CreateDirectoryA(const char *path, void *security); /* -- lint-ok: R1 v18 contract for other mods */
    uint32_t GetLastError(void); /* -- lint-ok: R1 v18 contract for other mods */
]]
local V18_DISCOVERY_DECLARATIONS = [[
    uint32_t GetModuleFileNameA(void *module, char *filename, uint32_t size); /* -- lint-ok: R1 v18 contract */
    void *FindFirstFileA(const char *pattern, void *data); /* -- lint-ok: R1 v18 contract for other mods */
    int FindNextFileA(void *handle, void *data); /* -- lint-ok: R1 v18 contract for other mods */
    int FindClose(void *handle); /* -- lint-ok: R1 v18 contract for other mods */
    uint32_t GetLastError(void); /* -- lint-ok: R1 v18 contract for other mods */
]]

-- A builtin library, never a game resource of the same name.
local function builtin(name)
    local loaded = package and package.loaded and package.loaded[name]
    if loaded then return loaded end
    ensure(package and package.preload and package.preload[name], name .. ' builtin unavailable')
    return require(name)
end

-- {ffi, kernel}: kernel holds the functions above under their Windows names.
-- Bound once; nil and the reason when the FFI is unavailable.
local native, native_reason
local function windows()
    if native == nil then
        local ok, ffi, kernel = pcall(function()
            local ffi = builtin('ffi')
            ffi.cdef(WINDOWS)
            local library, kernel = ffi.load('kernel32'), {}
            for _, name in ipairs(FUNCTIONS) do kernel[name] = library['bsl_' .. name] end
            return ffi, kernel
        end)
        native = ok and {ffi = ffi, kernel = kernel} or false
        if not ok then native_reason = tostring(ffi) end
    end
    return native or nil, native_reason
end

-- One directory and one filesystem setup per session for every mod's logs.
-- Failure to create/write diagnostics must never stop gameplay loading.
local logs_initialized = false
local function log_directory()
    if not logs_initialized then
        logs_initialized = true
        local ok, directory = pcall(function()
            local base = getenv('LOCALAPPDATA')
            if not base or base == '' then return nil end
            local found = windows()
            if not found then return nil end
            for _, part in ipairs({'CowboyBingus', 'Helldivers2', 'Logs'}) do
                base = base .. '/' .. part
                if found.kernel.CreateDirectoryA(base, nil) == 0 and found.kernel.GetLastError() ~= 183 then
                    return nil
                end
            end
            return base
        end)
        if ok then state.log_directory = directory end
    end
    return state.log_directory
end

-- v18 declared its log pair the first time any log was opened (by a mod, by a
-- module report or by a JIT cache log), and only with LOCALAPPDATA set.
local v18_log_names_declared = false
local function declare_v18_log_names()
    if v18_log_names_declared then return end
    v18_log_names_declared = true
    local base = getenv and getenv('LOCALAPPDATA')
    local found = base and base ~= '' and windows()
    if found then pcall(found.ffi.cdef, V18_LOG_DECLARATIONS) end
end

-- The loader's own log writes, which v18 did not have before a module report.
local function open_file(name)
    local directory = log_directory()
    if not directory then return nil end
    local ok, file = pcall(open, directory .. '/' .. name, 'w')
    if ok then return file end
end

function state.open_log(name)
    if type(name) ~= 'string' or not name:match('^[%w_-]+%.log$') then return nil end
    declare_v18_log_names()
    return open_file(name)
end

-- Health report (src/health.lua, embedded by the builder in this lexical scope;
-- direct-source tests run without it). Startup only: no per-frame work.
local header, changes, finished = {}, {}, nil
state.health = {header = header, changes = changes}
local date = type(os) == 'table' and os.date or nil
local function date_text(seconds)
    return date('%Y-%m-%d %H:%M:%S', seconds)
end
local previous_log
if loader_health then
    -- Read before the first write of this session replaces it.
    pcall(function()
        local directory = log_directory()
        local file = directory and open(directory .. '/' .. LOG_NAME, 'rb')
        if not file then return end
        local ok, text = pcall(file.read, file, loader_health.LOG_BYTES)
        file:close()
        if ok then previous_log = text end
    end)
    local ok, text = pcall(date_text)
    header[#header + 1] = 'Started: ' .. (ok and tostring(text) or 'unknown')
end

-- Discovery's report on Lua resources deployed in more than one archive (log
-- only): by_name, which copy of a started module the game loads and which are
-- hidden; notes, declared entries not started because a compiled or
-- undeclared copy hides them.
local copies = {by_name = {}, notes = {}}

-- Callbacks registered with after_startup (below). queue and owners: the
-- callbacks waiting to run and the module that registered each (false when
-- none was starting); next: the next one to run; accepted: registrations this
-- session; starting: the module being started; owner: the registering module
-- of the callback that is running; running: a run is in progress; ready: this
-- startup has finished, so a registration runs at once. summary and lines: the
-- log lines after "Startup finished".
local CALLBACK_LIMIT = 256
local callbacks = {queue = {}, owners = {}, next = 1, accepted = 0, running = false, ready = false, lines = {}}

local function add_callback_lines(lines)
    if callbacks.summary then lines[#lines + 1] = callbacks.summary end
    for _, line in ipairs(callbacks.lines) do lines[#lines + 1] = line end
end

-- Each listed module's status line, then its copies and changes lines.
local function add_module_lines(lines)
    for _, name in ipairs(names) do
        local status = state.modules[name]
        if status then
            lines[#lines + 1] = name .. ': ' .. status
            if copies.by_name[name] then lines[#lines + 1] = '  copies: ' .. copies.by_name[name] end
            if changes[name] then lines[#lines + 1] = '  changes: ' .. changes[name] end
        end
    end
end

local jit_cache
local function write_log()
    pcall(function()
        local file = open_file(LOG_NAME)
        if not file then return end
        local lines = {'Bingus Shared Loader loader-v19; API 1'}
        for _, line in ipairs(header) do lines[#lines + 1] = line end
        if state.discovery then lines[#lines + 1] = 'Discovery: ' .. state.discovery end
        for _, note in ipairs(copies.notes) do lines[#lines + 1] = '  ' .. note end
        if jit_cache then lines[#lines + 1] = jit_cache.describe() end
        add_module_lines(lines)
        if finished then lines[#lines + 1] = finished end
        add_callback_lines(lines)
        lines[#lines + 1] = ''
        pcall(file.write, file, concat(lines, '\n'))
        file:close()
    end)
end

local function report(name, status)
    state.modules[name] = status
    pcall(print, '[BingusSharedLoader] ' .. name .. ': ' .. status)
    declare_v18_log_names()
end

-- after_startup ----------------------------------------------------------------
-- A callback runs once, after every module of this startup has started (the
-- registry, then the discovered entries) and before the first game update; one
-- registered after that runs at once. Callbacks run one at a time, in
-- registration order, each under pcall: one registered while another runs waits
-- until that one returns. An error is logged once, with the module that
-- registered the callback, and never reaches the caller. Nothing runs per frame.

-- An error value as one line of text; never raises.
local function error_text(value)
    local printable, text = pcall(tostring, value)
    if not printable or type(text) ~= 'string' then return 'an error value without text' end
    return (text:gsub('[\r\n]+', ' '))
end

local function callback_failed(owner, message)
    local who = owner and ('callback of ' .. owner) or 'callback registered after startup'
    local line = 'After startup: ' .. who .. ' failed: ' .. error_text(message)
    callbacks.lines[#callbacks.lines + 1] = line
    pcall(print, '[BingusSharedLoader] ' .. line)
end

-- Runs every queued callback in order, including the ones queued while they
-- run. Returns how many ran and how many raised. Kept out of the JIT (below).
local function run_callbacks()
    local ran, failed = 0, 0
    local queue, owners = callbacks.queue, callbacks.owners
    while callbacks.next <= #queue do
        local index = callbacks.next
        local fn, owner = queue[index], owners[index]
        callbacks.next, queue[index], owners[index] = index + 1, false, false
        callbacks.owner = owner
        local ok, message = pcall(fn)
        ran = ran + 1
        if not ok then
            failed = failed + 1
            callback_failed(owner, message)
        end
    end
    return ran, failed
end

-- One run of the queue. A registration made during a run joins that run.
local function drain()
    if callbacks.running then return 0, 0 end
    callbacks.running = true
    local ok, ran, failed = pcall(run_callbacks)
    callbacks.running, callbacks.owner = false, nil
    callbacks.queue, callbacks.owners, callbacks.next = {}, {}, 1
    if not ok then
        callbacks.lines[#callbacks.lines + 1] = 'After startup: callbacks stopped: ' .. error_text(ran)
        return 0, 0
    end
    return ran, failed
end

-- A registration after startup runs at once. The log is rewritten only when
-- that run added a line, never for callbacks that returned normally.
local function run_now()
    local before = #callbacks.lines
    drain()
    if #callbacks.lines > before then write_log() end
end

-- The limit stops a callback that registers itself again from keeping the game
-- in its startup forever. Logged once.
local function refuse()
    if not callbacks.refused then
        callbacks.refused = true
        local line = 'After startup: ' .. CALLBACK_LIMIT .. ' callbacks registered; later registrations refused'
        callbacks.lines[#callbacks.lines + 1] = line
        pcall(print, '[BingusSharedLoader] ' .. line)
        if callbacks.ready and not callbacks.running then write_log() end
    end
    return false, 'after_startup: ' .. CALLBACK_LIMIT .. ' callbacks already registered'
end

-- Returns true, or false and a reason when fn is not a function or the limit
-- is reached.
function state.after_startup(fn)
    if type(fn) ~= 'function' then return false, 'after_startup needs a function' end
    if callbacks.accepted >= CALLBACK_LIMIT then return refuse() end
    callbacks.accepted = callbacks.accepted + 1
    local index = #callbacks.queue + 1
    callbacks.queue[index] = fn
    callbacks.owners[index] = callbacks.owner or callbacks.starting or false
    if callbacks.ready then run_now() end
    return true
end

-- Before the last startup write: the log names the callbacks about to run, so a
-- session that stops inside one ends with this line.
local function note_callbacks()
    local count = #callbacks.queue
    if count > 0 then
        callbacks.summary = 'After startup: running ' .. count .. (count == 1 and ' callback' or ' callbacks')
    end
end

-- After it: the callbacks registered while the modules started, then one more
-- write with the summary in place of the note. From here on a registration runs
-- at once.
local function run_startup_callbacks()
    callbacks.ready = true
    if not callbacks.summary then return end
    local ran, failed = drain()
    callbacks.summary = 'After startup: ' .. ran .. (ran == 1 and ' callback' or ' callbacks') .. ' run, '
        .. failed .. ' failed'
    write_log()
end

-- The queue runs at startup and on rare later registrations: compiled, its loop
-- would keep machine code that never runs again in the cache every mod shares.
do
    local library = rawget(_G, 'jit')
    if type(library) == 'table' and type(library.off) == 'function' then pcall(library.off, run_callbacks) end
end

-- The builder embeds src/jit_budget.lua in this lexical scope. The game's
-- LuaJIT code cache is shared by every mod, so its limits are raised before
-- any mod starts. state.jit also tells older fallbacks the loader manages it.
if jit_budget then
    local registry = type(debug) == 'table' and debug.getregistry or nil
    local function log()
        declare_v18_log_names()
        write_log()
    end
    local ok, cache = pcall(jit_budget.start, rawget(_G, 'jit'), {log = log, registry = registry})
    if ok then
        jit_cache, state.jit = cache, cache.public
        pcall(print, '[BingusSharedLoader] ' .. cache.describe())
    else
        state.jit = {managed = false, reason = tostring(cache)}
    end
end

-- The rest of the header, and the observer that records what each module
-- changes in the shared Lua state.
local observer
if loader_health then
    local function line(label, step)
        local ok, text = pcall(step)
        if not ok then text = 'unavailable (' .. tostring(text) .. ')' end
        if text then header[#header + 1] = label .. ': ' .. text end
    end
    line('Game build stamps', function()
        local found, reason = windows()
        ensure(found, reason)
        return 'executable ' .. loader_health.hex(loader_health.image_stamp(found.ffi, found.kernel, nil))
            .. ', game.dll ' .. loader_health.hex(loader_health.image_stamp(found.ffi, found.kernel, 'game.dll'))
    end)
    line('Lua at start', function()
        local clock = type(os) == 'table' and os.clock -- lint-ok: R6 load time per module, startup only
        if type(clock) ~= 'function' then clock = nil end
        observer = loader_health.observer(_G, {collect = collectgarbage, jit = rawget(_G, 'jit'), clock = clock,
            flushes = jit_cache and function() return jit_cache.public.flushes end,
            watching = jit_cache and jit_cache.watching})
        return loader_health.describe_start(observer.initial)
    end)
    line('Previous session', function() return loader_health.previous_session(previous_log) end)
    previous_log = nil
    local ok, lines = pcall(function()
        local found, reason = windows()
        ensure(found, reason)
        local base = getenv('APPDATA')
        ensure(base and base ~= '', 'APPDATA unavailable')
        return loader_health.crashes(found.ffi, found.kernel, base .. '/Arrowhead/Helldivers2/dumps', open,
            date_text)
    end)
    if not ok then lines = {'Newest crash dump: unavailable (' .. tostring(lines) .. ')'} end
    for _, text in ipairs(lines) do header[#header + 1] = text end
end

local application = stingray and stingray.Application

-- The builder embeds discovery in this lexical scope. Direct-source legacy tests
-- can still exercise the coordinator without loading native filesystem APIs.
if addon_discovery then
    local found, reason = windows()
    local ok, entries, warnings, report = false, reason
    if found then
        pcall(found.ffi.cdef, V18_DISCOVERY_DECLARATIONS)
        -- names holds only the registry here; discovered entries follow below.
        ok, entries, warnings, report = pcall(addon_discovery.discover, found.ffi, found.kernel, names)
    end
    if ok then
        state.discovery = tostring(#entries) .. ' declared entries'
        local listed = {}
        for _, name in ipairs(names) do listed[name] = true end
        for _, name in ipairs(entries) do
            if not listed[name] then names[#names + 1] = name; listed[name] = true end
        end
        if warnings and #warnings > 0 then
            state.discovery = state.discovery .. '; ' .. concat(warnings, '; ')
        end
        if type(report) == 'table' and type(report.by_name) == 'table' and type(report.notes) == 'table' then
            copies = report
        end
    else
        state.discovery = 'failed: ' .. tostring(entries)
    end
    pcall(print, '[BingusSharedLoader] Discovery: ' .. state.discovery)
end

-- What a module changed, measured around its require. A failure here only
-- stops the measurements; loading continues.
local function observed_require(name)
    local ok, mark = pcall(function() return observer and observer.mark() end)
    local loaded, reason = pcall(require, name)
    if ok and mark then
        local measured, found = pcall(observer.changes, mark)
        if measured then measured, found = pcall(loader_health.describe, found) end
        if measured then
            changes[name] = found
        else
            changes[name] = 'unavailable (' .. tostring(found) .. ')'
            observer = nil
        end
    end
    return loaded, reason
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
            -- Written before the module runs: if the game stops inside it, the
            -- log ends with this module marked "loading".
            write_log()
            callbacks.starting = name
            local loaded, reason = observed_require(name)
            callbacks.starting = nil
            report(name, loaded and 'loaded' or 'load failed: ' .. tostring(reason))
        end
    end
end

local loaded_count, failed_count = 0, 0
for _, name in ipairs(names) do
    local status = state.modules[name]
    if status == 'loaded' then
        loaded_count = loaded_count + 1
    elseif status and status ~= 'not installed' and status ~= 'loading' then
        failed_count = failed_count + 1
    end
end
finished = 'Startup finished: ' .. loaded_count .. ' loaded, ' .. failed_count .. ' failed'
note_callbacks()
write_log()
run_startup_callbacks()
