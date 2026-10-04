-- CowboyBingusModLoader.after_startup: a callback registered while the loader
-- starts the modules runs once, after every module of this startup has started
-- and before the first game update; one registered later runs at once. Runs the
-- built coordinator (and, for the JIT check, the bare source) in the workspace
-- LuaJIT and in the game's own lua51.dll (tests/game_lua.py). Files go to
-- build/after-startup-test-*.
local source, build = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

-- The test's own Windows functions, under private names like the loader's.
ffi.cdef [[
    int bsla_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
    uint32_t bsla_GetLastError(void) __asm__("GetLastError");
]]
local kernel = ffi.load('kernel32')
local function mkdirs(path)
    local current = ''
    for part in path:gmatch('[^/]+') do
        current = current == '' and part or current .. '/' .. part
        if not current:match('^%a:$') and kernel.bsla_CreateDirectoryA(current, nil) == 0 then
            assert(kernel.bsla_GetLastError() == 183, 'cannot create ' .. current)
        end
    end
end

local temp = build:gsub('\\', '/') .. '/after-startup-test-' .. jit.version:gsub('[^%w]', '')
local M = {megapack = 'mods/cowboybingus/vanilla_plus_megapack', bounce = 'mods/cowboybingus/better_stratagem_bounce',
           steering = 'mods/cowboybingus/hellpod_steering_unlocked'}
local LOG_PREFIX = '[BingusSharedLoader] '

local function execute(path, env) return setfenv(assert(loadfile(path)), env)() end

-- One game start. modules: resource name -> function(loader, run) run as that
-- module's require (it may raise). coordinator: 'built' (default) or 'bare'.
-- run.events lists module starts, callbacks and updates in the order they ran;
-- run.writes counts the rewrites of the loader log.
local scenarios = 0
local function startup(modules, options)
    options = options or {}
    scenarios = scenarios + 1
    local localappdata = temp .. '/run' .. scenarios
    mkdirs(localappdata)
    local run = {events = {}, prints = {}, writes = 0, logs = localappdata .. '/CowboyBingus/Helldivers2/Logs'}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    if options.jit then rawset(env, 'jit', jit) end
    env.print = function(...)
        local parts = {}
        for index = 1, select('#', ...) do parts[index] = tostring((select(index, ...))) end
        run.prints[#run.prints + 1] = table.concat(parts, ' ')
    end
    env.os = setmetatable({getenv = function(name)
        if name == 'LOCALAPPDATA' then return localappdata end
    end}, {__index = os})
    env.io = setmetatable({open = function(path, mode)
        if mode == 'w' and path:find('/BingusSharedLoader.log', 1, true) then run.writes = run.writes + 1 end
        return io.open(path, mode)
    end}, {__index = io})
    env.stingray = {Application = {build = function() return 'release' end,
        can_get = function(kind, name) return kind == 'lua' and modules[name] ~= nil end}}
    env.loadstring = function(bytes, label)
        local chunk, reason = loadstring(bytes, label)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    env.require = function(name)
        if name == 'core/wwise/lua/wwise_flow_callbacks' then execute(build .. '/callbacks.ljbc', env); return true end
        if name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference' then
            return {}
        end
        local module = assert(modules[name], 'unexpected require ' .. name)
        run.events[#run.events + 1] = 'start ' .. name:match('[^/]+$')
        module(env.CowboyBingusModLoader, run)
        return true
    end
    run.env = env
    if options.coordinator == 'bare' then
        execute(source .. '/shared_loader.lua', env)
    else
        execute(build .. '/vanilla-boot.ljbc', env)
        env.update = function() run.events[#run.events + 1] = 'update' end
        env.init()
    end
    run.loader = env.CowboyBingusModLoader
    return run
end

local function log_lines(run)
    local file = assert(io.open(run.logs .. '/BingusSharedLoader.log', 'rb'), 'no loader log')
    local text = file:read('*a'); file:close()
    local lines = {}
    for line in text:gmatch('([^\r\n]*)\r?\n') do lines[#lines + 1] = line end
    return lines
end

-- The lines after "Startup finished", which must be the last module line.
local function tail(lines)
    for index, line in ipairs(lines) do
        if line:find('^Startup finished') then return {unpack(lines, index + 1)} end
    end
    error('no Startup finished line')
end

local function count(list, value)
    local found = 0
    for _, item in ipairs(list) do if item == value then found = found + 1 end end
    return found
end

local function joined(list) return table.concat(list, ', ') end

-- The performance tools read "<module>: <status>" lines; no after_startup line may match.
local function check_statuses(name, run)
    local parsed = {}
    for _, line in ipairs(log_lines(run)) do
        local module, status = line:match('^%s*([%w_./-]+/[%w_./-]+): (.+)$')
        if module then parsed[module] = status end
    end
    for module, status in pairs(run.loader.modules) do check(name .. ': status line ' .. module, parsed[module] == status) end
    for module in pairs(parsed) do check(name .. ': no stray status line ' .. module, run.loader.modules[module] ~= nil) end
end

local function callback(run, label, body)
    return function()
        run.events[#run.events + 1] = 'callback ' .. label
        if body then body() end
    end
end

-- 1. No callbacks: nothing changes ------------------------------------------------------

do
    local run = startup({[M.megapack] = function() end, [M.bounce] = function() end})
    local loader = run.loader
    check('capability', loader.capabilities.after_startup == true and type(loader.after_startup) == 'function')
    local lines = log_lines(run)
    check('no after_startup lines', lines[#lines] == 'Startup finished: 2 loaded, 0 failed' and #tail(lines) == 0,
        lines[#lines])
    check('one write per module and one at the end, as before', run.writes == 3, run.writes)
    for _, line in ipairs(run.prints) do check('no after_startup print', not line:find('After startup', 1, true), line) end
    for _ = 1, 100 do run.env.update() end
    check('no per-frame work', joined(run.events) == 'start vanilla_plus_megapack, start better_stratagem_bounce, '
        .. string.rep('update', 100, ', ') and run.writes == 3, run.writes)
end

-- 2. Once each, in registration order, after every module started, before the first update

do
    local seen, note
    local run = startup({
        [M.megapack] = function(loader, current)
            loader.after_startup(callback(current, 'm1', function()
                local modules = loader.modules
                seen = modules[M.megapack] .. ' | ' .. modules[M.bounce] .. ' | ' .. modules[M.steering]
                local lines = log_lines(current)
                note = lines[#lines]
            end))
        end,
        [M.bounce] = function(loader, current)
            check('registration accepted', loader.after_startup(callback(current, 'b1')) == true)
            loader.after_startup(callback(current, 'b2'))
        end,
        -- Registers, then fails to start: its callback still runs.
        [M.steering] = function(loader, current)
            loader.after_startup(callback(current, 's1'))
            error('steering failed', 0)
        end,
    })
    check('not run during startup, then run once each in registration order', joined(run.events)
        == 'start vanilla_plus_megapack, start better_stratagem_bounce, start hellpod_steering_unlocked, '
        .. 'callback m1, callback b1, callback b2, callback s1', joined(run.events))
    check('every module had started', seen == 'loaded | loaded | load failed: steering failed', seen)
    check('the log names the callbacks before they run', note == 'After startup: running 4 callbacks', note)
    run.env.update()
    check('before the first update', run.events[#run.events] == 'update' and #run.events == 8)
    local after = tail(log_lines(run))
    check('summary replaces the note', joined(after) == 'After startup: 4 callbacks run, 0 failed', joined(after))
    check('one more write than without callbacks', run.writes == 5, run.writes)
    check_statuses('order', run)
end

-- 3. A callback that raises: logged once with its module, never propagates ------------------

do
    local run = startup({
        [M.megapack] = function(loader, current)
            loader.after_startup(callback(current, 'a', function() error('boom\nsecond line', 0) end))
            loader.after_startup(callback(current, 'b'))
            loader.after_startup(callback(current, 'c', function()
                error(setmetatable({}, {__tostring = function() error('no text') end}))
            end))
            loader.after_startup(callback(current, 'd', function()
                error(setmetatable({}, {__tostring = function() return 'table error' end}))
            end))
        end,
        [M.bounce] = function(loader, current)
            loader.after_startup(callback(current, 'e', function() error('bounce error', 0) end))
        end,
    })
    check('every callback ran despite the errors', joined(run.events) == 'start vanilla_plus_megapack, '
        .. 'start better_stratagem_bounce, callback a, callback b, callback c, callback d, callback e',
        joined(run.events))
    local expected = {
        'After startup: 5 callbacks run, 4 failed',
        'After startup: callback of mods/cowboybingus/vanilla_plus_megapack failed: boom second line',
        'After startup: callback of mods/cowboybingus/vanilla_plus_megapack failed: an error value without text',
        'After startup: callback of mods/cowboybingus/vanilla_plus_megapack failed: table error',
        'After startup: callback of mods/cowboybingus/better_stratagem_bounce failed: bounce error',
    }
    local after = tail(log_lines(run))
    check('one line per failure, with the registering module', joined(after) == joined(expected), joined(after))
    for index = 2, #expected do
        check('printed once: ' .. index, count(run.prints, LOG_PREFIX .. expected[index]) == 1)
    end
    check('module statuses unchanged', run.loader.modules[M.megapack] == 'loaded'
        and run.loader.modules[M.bounce] == 'loaded')
    check_statuses('errors', run)
end

-- 4. Registered during another callback: waits for it, keeps registration order ----------

do
    local registered_while_running, outer_returned
    local run = startup({
        [M.megapack] = function(loader, current)
            loader.after_startup(callback(current, 'outer', function()
                registered_while_running = loader.after_startup(callback(current, 'inner', function()
                    loader.after_startup(callback(current, 'innermost', function() error('nested failure', 0) end))
                end))
                outer_returned = joined(current.events)
            end))
        end,
        [M.bounce] = function(loader, current) loader.after_startup(callback(current, 'second')) end,
    })
    check('accepted while another runs', registered_while_running == true)
    check('not run inside the callback that registered it', not outer_returned:find('inner', 1, true), outer_returned)
    check('registration order, all before the first update', joined(run.events) == 'start vanilla_plus_megapack, '
        .. 'start better_stratagem_bounce, callback outer, callback second, callback inner, callback innermost',
        joined(run.events))
    local after = tail(log_lines(run))
    check('nested callbacks counted, owner inherited', joined(after) == 'After startup: 4 callbacks run, 1 failed, '
        .. 'After startup: callback of mods/cowboybingus/vanilla_plus_megapack failed: nested failure', joined(after))
end

-- 5. Registered after startup: runs at once ------------------------------------------------

for _, with_startup_callback in ipairs({false, true}) do
    local run = startup({[M.megapack] = function(loader, current)
        if with_startup_callback then loader.after_startup(callback(current, 'startup')) end
    end})
    local loader, writes = run.loader, run.writes
    run.env.update()
    local ran = 0
    check('late registration accepted', loader.after_startup(function() ran = ran + 1 end) == true)
    check('late callback ran before after_startup returned', ran == 1, ran)
    check('a late callback that returns writes nothing', run.writes == writes, run.writes)
    local ok, result = pcall(loader.after_startup, function() error('late boom', 0) end)
    check('a late error never reaches the caller', ok and result == true, result)
    check('a late failure rewrites the log once', run.writes == writes + 1, run.writes)
    local order = {}
    loader.after_startup(function()
        order[#order + 1] = 'outer start'
        loader.after_startup(function() order[#order + 1] = 'inner' end)
        order[#order + 1] = 'outer end'
    end)
    check('late nesting waits for the outer callback', joined(order) == 'outer start, outer end, inner', joined(order))
    local after = tail(log_lines(run))
    local expected = 'After startup: callback registered after startup failed: late boom'
    if with_startup_callback then expected = 'After startup: 1 callback run, 0 failed, ' .. expected end
    check('late failure logged without a module name', joined(after) == expected, joined(after))
    check('late failure printed once', count(run.prints, LOG_PREFIX .. 'After startup: callback registered after '
        .. 'startup failed: late boom') == 1)
    check('late runs leave the update chain alone', run.events[#run.events] == 'update')
end

-- 6. Not a function: refused, nothing logged ---------------------------------------------------

do
    local run = startup({[M.megapack] = function(loader)
        for _, value in ipairs({false, 'text', 7, {}, setmetatable({}, {__call = function() end})}) do
            local ok, reason = loader.after_startup(value)
            check('refuses ' .. type(value), ok == false and reason == 'after_startup needs a function', reason)
        end
        local ok, reason = loader.after_startup()
        check('refuses nil', ok == false and reason == 'after_startup needs a function', reason)
    end})
    check('nothing queued or logged', #tail(log_lines(run)) == 0 and run.writes == 2, run.writes)
end

-- 7. The limit: 256 callbacks a session ---------------------------------------------------------

do
    -- A callback that registers itself again every time it runs.
    local runs, refusal
    local run = startup({[M.megapack] = function(loader)
        local function again()
            runs = (runs or 0) + 1
            local ok, reason = loader.after_startup(again)
            if not ok then refusal = reason end
        end
        loader.after_startup(again)
    end})
    check('a self-registering callback stops at the limit', runs == 256, runs)
    check('the refused registration says why', refusal == 'after_startup: 256 callbacks already registered', refusal)
    local limit = 'After startup: 256 callbacks registered; later registrations refused'
    local after = tail(log_lines(run))
    check('limit logged once', joined(after) == 'After startup: 256 callbacks run, 0 failed, ' .. limit, joined(after))
    local writes = run.writes
    local ok = run.loader.after_startup(function() error('never runs') end)
    check('later registrations refused without another write', ok == false and run.writes == writes
        and count(run.prints, LOG_PREFIX .. limit) == 1)

    -- Too many registrations while the modules start: the first 256 run.
    local ran = 0
    run = startup({[M.megapack] = function(loader)
        for _ = 1, 300 do loader.after_startup(function() ran = ran + 1 end) end
    end})
    after = tail(log_lines(run))
    check('the first 256 run', ran == 256 and joined(after) == 'After startup: 256 callbacks run, 0 failed, '
        .. limit, joined(after))
end

-- 8. Kept out of the JIT --------------------------------------------------------------------------

do
    local path = source .. '/shared_loader.lua'
    local file = assert(io.open(path, 'rb'))
    local text = file:read('*a'); file:close()
    local line = 0
    for current in (text .. '\n'):gmatch('([^\n]*)\n') do
        line = line + 1
        if current:find('^local function run_callbacks%(') then break end
    end
    local util, started, ran = require('jit.util'), 0, 0
    local function watch(what, _, func)
        if what ~= 'start' then return end
        local info = util.funcinfo(func)
        if info.source == '@' .. path and info.linedefined == line then started = started + 1 end
    end
    jit.attach(watch, 'trace')
    startup({[M.megapack] = function(loader)
        for _ = 1, 256 do loader.after_startup(function() ran = ran + 1 end) end
    end}, {coordinator = 'bare', jit = true})
    jit.attach(watch)
    check('the queue ran', ran == 256, ran)
    check('no trace starts in the queue loop', started == 0, started)
end

print('PASS: after_startup (' .. passed .. ' checks in ' .. scenarios .. ' starts; ' .. jit.version .. '): once each,'
    .. ' in registration order, after every module started and before the first update; errors logged once with'
    .. ' the registering module and never propagated; nested and late registrations; refusals; the 256 limit;'
    .. ' no log change without callbacks; kept out of the JIT')
