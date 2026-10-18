-- The churn guard's counting, threshold, handling and log lines with fake trace events and a
-- fake penalty cache (the real one: tests/test_jit_guard_game.lua in the game's lua51.dll).
local source = assert(arg[1])
local guard = dofile(source .. '/jit_guard.lua')
local budget = dofile(source .. '/jit_budget.lua')
local CHURN, MAX, RETRY = guard.CHURN_ABORTS, guard.PENALTY_MAX, guard.RETRY

-- A fake penalty cache: slots[i] = {pc, val}; hot[pc] = hot counter.
local function fake_penalty()
    local p = {slots = {}, hot = {}, bumped = {}, located = 0}
    function p.find(pc)
        for i = 0, 63 do
            if p.slots[i] and p.slots[i].pc == pc then return i end
        end
    end
    function p.value(i) return p.slots[i].val end
    function p.bump(i) p.slots[i].val = MAX; p.bumped[#p.bumped + 1] = i end
    function p.retry_now(pc, expected)
        if p.hot[pc] ~= expected then return false end
        p.hot[pc] = 1
        return true
    end
    -- LuaJIT's penalty for an abort of the start at pc: a new slot (72) or a doubled one.
    function p.penalize(pc, slot)
        local i = p.find(pc)
        if i and p.slots[i].val * 2 > MAX then return 'blacklisted' end
        if i then p.slots[i].val = p.slots[i].val * 2 else i = slot; p.slots[i] = {pc = pc, val = 72} end
        p.hot[pc] = p.slots[i].val
    end
    return p
end

-- A guard over fake functions whose identity is a table lookup (base address per function).
local function make(options)
    options = options or {}
    local p, logs, now = fake_penalty(), {count = 0}, {t = 100}
    local bases = options.bases or {}
    local g = guard.new({
        identity = function(func) return bases[func] end,
        locate = options.locate or function() p.located = p.located + 1; return p end,
        handle = options.handle ~= false, info = options.info or function(_, pc) return '@mods/x/y.lua', 10 + pc end,
        log = function() logs.count = logs.count + 1 end, clock = function() return now.t end,
    })
    return g, p, logs, now, bases
end

-- One abort of the start (func, pc) at trace tr with code; the penalty cache is updated first,
-- as LuaJIT does, when a slot is given.
local function abort(g, func, pc, code, p, address, slot)
    if p then p.penalize(address, slot) end
    g.event('start', 7, func, pc, nil)
    g.event('abort', 7, func, pc + 3, code)
end

-- Watch: CHURN_ABORTS aborts are not churn; the next is. Retries and side traces are not counted.
do
    local g, p, logs = make()
    local f = function() end
    for _ = 1, CHURN do abort(g, f, 4, 7) end
    assert(g.public.starts == 0 and g.public.aborts == CHURN and logs.count == 0 and p.located == 0)
    abort(g, f, 4, RETRY)
    g.event('start', 8, f, 4, 3, 1)  -- a side trace of trace 3
    g.event('abort', 8, f, 4, 7)
    g.event('start', 9, f, 4, nil)
    g.event('abort', 10, f, 4, 7)    -- a different trace number
    assert(g.public.aborts == CHURN, 'Retries, side traces and unmatched aborts are not counted')
    abort(g, f, 4, 'a Lua error message')
    assert(g.public.starts == 1 and g.public.aborts == CHURN + 1 and logs.count == 1)
    -- No penalty slot holds this start (no base address): located, unmatched.
    assert(p.located == 1 and g.public.unmatched == 1 and g.public.handled == 0)
    local lines = {}
    g.add_lines(lines)
    assert(lines[1] == 'LuaJIT churn: 1 starts kept failing (handled 0); top owners: mods/x/y.lua 1; guard on', lines[1])
    assert(lines[2]:find('^  churn guard: ' .. (CHURN + 1) .. ' aborts counted; blacklisted 0') and lines[3]
        == '  churn: mods/x/y.lua:14 error thrown or hook called during recording; ' .. (CHURN + 1) .. ' aborts',
        lines[3])
end

-- Handle: the abort after CHURN_ABORTS bumps the start's own slot and lets it record again; the next abort,
-- with the bump in place, is LuaJIT's blacklisting and is not bumped again.
do
    local g, p, logs, _, bases = make()
    local f, other = function() end, function() end
    bases[f], bases[other] = 1000, 5000
    local address = 1000 + 4 * 4
    p.slots[3] = {pc = 5000, val = 300}
    for i = 1, CHURN + 1 do abort(g, f, 4, 7, p, address, 10 + i % 2) end
    local slot = p.find(address)
    assert(g.public.handled == 1 and g.public.retried == 1 and #p.bumped == 1 and p.bumped[1] == slot)
    assert(p.slots[slot].val == MAX and p.hot[address] == 1 and p.slots[3].val == 300, 'Only its own slot changes')
    assert(p.penalize(address) == 'blacklisted')
    g.event('start', 7, f, 4, nil)
    g.event('abort', 7, f, 7, 7)
    assert(g.public.blacklisted == 1 and #p.bumped == 1 and g.public.returned == 0)
    -- Later aborts of a blacklisted record (a flush cleared nothing) are only counted.
    abort(g, f, 4, 7)
    assert(#p.bumped == 1 and g.public.aborts == CHURN + 3)
    local lines = {}
    g.add_lines(lines)
    assert(lines[3] == '  churn: mods/x/y.lua:14 NYI: bytecode; ' .. (CHURN + 3) .. ' aborts; handled', lines[3])
    assert(logs.count == 1, 'One log write within LOG_INTERVAL')
end

-- A bump lost to eviction: the start aborts with a fresh slot; bumped again, at most BUMPS times.
do
    local g, p, _, _, bases = make()
    local f = function() end
    bases[f] = 2000
    local address = 2000
    for i = 1, CHURN + 1 do abort(g, f, 0, 7, p, address, 5) end
    for round = 1, guard.BUMPS + 2 do
        p.slots[p.find(address)] = nil  -- evicted by other starts
        abort(g, f, 0, 7, p, address, 6 + round)
    end
    assert(#p.bumped == guard.BUMPS and g.public.returned == guard.BUMPS + 2 and g.public.handled == 1)
end

-- Closures of one prototype share their counts.
do
    local g, p, _, _, bases = make()
    local a, b = function() end, function() end
    bases[a], bases[b] = 3000, 3000
    for i = 1, CHURN do abort(g, i % 2 == 0 and a or b, 2, 7) end
    assert(g.aborts_of(a) == CHURN and g.aborts_of(b) == CHURN and g.public.starts == 0)
    abort(g, a, 2, 7, p, 3008, 0)
    assert(g.public.starts == 1 and g.public.handled == 1)
end

-- Switched off: counted and logged, never located or bumped.
do
    local g, p, logs = make({handle = false})
    local f = function() end
    for _ = 1, CHURN + 5 do abort(g, f, 1, 7) end
    assert(g.public.starts == 1 and p.located == 0 and g.public.handled == 0 and logs.count == 1)
    local lines = {}
    g.add_lines(lines)
    assert(lines[1]:find('; guard watch only %(switched off%)$'), lines[1])
end

-- Locate fails (returns a reason, or raises): watch only from then on, with the reason.
for _, locate in ipairs({function() return nil, 'J->param not found' end, function() error('bad read', 0) end}) do
    local g, _, logs = make({locate = locate})
    local f, h = function() end, function() end
    for _ = 1, CHURN + 1 do abort(g, f, 1, 7) end
    for _ = 1, CHURN + 1 do abort(g, h, 1, 7) end
    assert(g.public.starts == 2 and g.public.handled == 0 and not g.public.located)
    assert(g.public.mode:find('^watch only %(locate failed: ') and logs.count == 1, g.public.mode)
end

-- The log: at once for the first churn, then at most once per LOG_INTERVAL, at the next event.
do
    local g, _, logs, now = make({handle = false})
    local f = {}
    for i = 1, 3 do f[i] = function() end end
    for _ = 1, CHURN + 1 do abort(g, f[1], 1, 7) end
    assert(logs.count == 1)
    for _ = 1, CHURN + 1 do abort(g, f[2], 1, 7) end
    assert(logs.count == 1, 'Within the interval: no write')
    now.t = now.t + guard.LOG_INTERVAL
    g.event('start', 7, f[3], 1, nil)
    assert(logs.count == 1, 'Start events never write')
    g.event('abort', 7, f[3], 1, RETRY)
    assert(logs.count == 2, 'The pending update is written at the next abort after the interval')
end

-- Header line with nothing churning; the listing stops at LISTED lines.
do
    local g = make()
    local lines = {}
    g.add_lines(lines)
    assert(#lines == 1 and lines[1] == 'LuaJIT churn: no start kept failing; guard on', lines[1])
    local w = make({handle = false, info = function(func) return '=chunk' .. tostring(func):sub(-2), 1 end})
    for _ = 1, guard.LISTED + 3 do
        local f = function() end
        for _ = 1, CHURN + 1 do abort(w, f, 1, 7) end
    end
    lines = {}
    w.add_lines(lines)
    assert(#lines == guard.LISTED + 3 and lines[#lines] == '  churn: 3 more not listed', lines[#lines])
    assert(w.public.starts == guard.LISTED + 3)
end

-- No allocation per event once a start's record exists. Interpreted, as trace event handlers
-- run in the game (no trace starts inside them); compiling traces would allocate here.
do
    local g = make({handle = false})
    local f = function() end
    abort(g, f, 1, 7)
    jit.off()
    jit.flush()
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, CHURN - 2 do abort(g, f, 1, 7) end
    for _ = 1, 1000 do
        g.event('start', 7, f, 1, nil)
        g.event('abort', 7, f, 5, RETRY)
    end
    local grew = collectgarbage('count') - before
    collectgarbage('restart')
    jit.on()
    assert(grew == 0, 'Events of a known start allocate nothing: ' .. grew .. ' KB')
end

-- Through the budget's watcher: start and abort reach the guard, flush growth is unchanged, a
-- guard that raises is stopped and named in its mode, and its lines join the log.
do
    local handler
    local jit = {opt = {start = function() end}, attach = function(f) handler = f end}
    local made
    local logs = 0
    local cache = budget.start(jit, {log = function() logs = logs + 1 end, clock = function() return 0 end,
        heap = function() return 0 end, guard = function(public, log)
            assert(public.managed and type(log) == 'function')
            made = guard.new({handle = false, log = log})
            return made
        end})
    assert(cache.public.churn == made.public)
    local f = function() end
    for _ = 1, CHURN + 1 do
        handler('start', 1, f, 2)
        handler('abort', 1, f, 2, 7)
    end
    assert(made.public.starts == 1 and logs == 1)
    handler('flush')
    assert(cache.public.flushes == 1 and cache.public.growths == 1)
    local lines = {}
    cache.add_churn_lines(lines)
    assert(lines[1]:find('^LuaJIT churn: 1 starts kept failing'), lines[1])
end
do
    local handler, failed
    local jit = {opt = {start = function() end}, attach = function(f) handler = f end}
    local cache = budget.start(jit, {clock = function() return 0 end, heap = function() return 0 end,
        guard = function()
            return {public = {}, event = function() error('boom', 0) end, failed = function(m) failed = m end}
        end})
    handler('start', 1, function() end, 0)
    handler('abort', 1, function() end, 0, 7)
    assert(failed == 'boom', 'The guard is told why it stopped')
    failed = nil
    handler('start', 1, function() end, 0)
    assert(failed == nil, 'A stopped guard gets no more events')
    handler('flush')
    assert(cache.public.flushes == 1 and cache.public.growths == 1, 'Growth goes on')
    local stopped = guard.new({})
    stopped.failed('boom')
    assert(stopped.public.mode == 'stopped (boom)')
end
do
    -- Without a guard the watcher and the log are as in v19.
    local jit = {opt = {start = function() end}, attach = function() end}
    local cache = budget.start(jit, {})
    local lines = {}
    cache.add_churn_lines(lines)
    assert(#lines == 0 and cache.public.churn == nil)
end

-- Reason names: verified codes and the fallback.
assert(guard.reason_name(7) == 'NYI: bytecode' and guard.reason_name(RETRY) == 'retry recording')
assert(guard.reason_name(0):find('^error thrown') and guard.reason_name(99) == 'trace error 99')

print('PASS: churn guard (counting, threshold, handling, log lines)')
