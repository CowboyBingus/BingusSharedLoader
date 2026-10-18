-- The churn guard inside the game's own LuaJIT 2.1.0-alpha (run by test_jit_guard_game.py).
-- Real trace starts that abort (pairs is NYI in this LuaJIT), the real penalty cache, the real
-- watcher. Timings are of this test process, not the game.
local source = assert(arg[1])
-- The game replaces tostring (functions print as '[function]', threads as '[thread (deleted)]',
-- seen in game 2026-10-17): the guard is loaded under such a tostring and must not depend on it.
local real_tostring = tostring
tostring = function(value) return '[' .. type(value) .. ']' end
local guard = dofile(source .. '/jit_guard.lua')
tostring = real_tostring
local budget = dofile(source .. '/jit_budget.lua')
local ffi = require('ffi')
local util = require('jit.util')
assert(jit.version == 'LuaJIT 2.1.0-alpha' and jit.status(), 'Expected the game LuaJIT with the compiler on')
local format, clock = string.format, os.clock
local out = {}
local function note(...) out[#out + 1] = format(...) end
-- A failure shows the measurements so far.
local function assert(condition, message, ...)
    if not condition then error(tostring(message or 'assertion failed') .. '\n  ' .. table.concat(out, '\n  '), 2) end
    return condition, message, ...
end

-- Reference J->param, found independently: an in-process scan from global_State (test only).
local function reference_param()
    local thread = tonumber(tostring(coroutine.create(function() end)):match('0x(%x+)'), 16)
    local g = ffi.cast('const uint32_t *', thread + 8)[0]
    local words = ffi.cast('const int32_t *', g)
    local tail = {56, 10, 4, 4, 15, 3, 2, 64}
    for i = 0, 4095 do
        local hit = true
        for k = 1, 8 do if words[i + k - 1] ~= tail[k] then hit = false; break end end
        if hit then return g + 4 * i - 24 end
    end
end
local PARAM = assert(reference_param(), 'reference J->param not found')
local pen32 = ffi.cast('const uint32_t *', PARAM + 188)
local pen16 = ffi.cast('const uint16_t *', PARAM + 188)
local penslot = ffi.cast('const uint32_t *', PARAM + 700)
-- The limits now in force, read from J->param (the watcher grows them on every flush).
local function current_limits()
    local ints = ffi.cast('const int32_t *', PARAM)
    return {traces = ints[0], mcode_kb = ints[14]}
end

local function start_address(func, pc)
    local address = tonumber(tostring(func):match('0x(%x+)'), 16)
    return ffi.cast('const uint32_t *', address + 16)[0] + 4 * pc
end

-- n trace starts that abort on every recording, each its own chunk; t is created once.
local function make_starts(n, tag)
    local starts = {}
    for i = 1, n do
        local chunk = assert(load('local t = {a = 1, b = 2} return function() local n = 0 '
            .. 'for i = 1, 100 do for k, v in pairs(t) do n = n + v end end return n end',
            format('=churn_%s_%03d', tag, i)))
        starts[i] = chunk()
    end
    return starts
end

local function frames(starts, count)
    for _ = 1, count do
        for i = 1, #starts do starts[i]() end
    end
end

local native = guard.native(ffi)
local bumps, wrong = 0, 0
local function on_bump(slot, pc, penalty)
    bumps = bumps + 1
    local val = pen16[4 * slot + 2]
    local fresh = slot == (penslot[0] - 1) % 64
    if penalty.param ~= PARAM or pen32[2 * slot] ~= pc or val < 72 or val > guard.PENALTY_MAX
        or (fresh and val ~= 72 and penalty.value(slot) ~= val) then
        wrong = wrong + 1
    end
end

-- A started budget with the guard (handle on or off); the watcher replaces any earlier one.
local function started(handle, hooks)
    hooks = hooks or {}
    local made
    local cache = budget.start(jit, {log = hooks.log, guard = function(public, log)
        made = guard.new({identity = native.identity, locate = function() return native.locate(public) end,
            handle = handle, info = function(func, pc)
                local info = util.funcinfo(func, pc)
                return info.source, info.currentline
            end, log = log, clock = function() return 0 end, on_bump = on_bump})
        return made
    end})
    assert(cache.public.churn == made.public)
    return cache, made
end

-- Aborts per window of size frames, for count windows, as a list and as text.
local function series(g, starts, count, size)
    local list = {}
    for w = 1, count do
        local before = g.public.aborts
        frames(starts, size)
        list[w] = g.public.aborts - before
    end
    return list, table.concat(list, ' ')
end

local function per_start(g, starts)
    local low, high = math.huge, 0
    for i = 1, #starts do
        local n = g.aborts_of(starts[i])
        low, high = math.min(low, n), math.max(high, n)
    end
    return low, high
end

jit.flush()

-- (b) 20 starts: LuaJIT penalizes and blacklists them itself (two starts each: the loop, then the function
-- entry); the guard counts them and handles none.
do
    local _, g = started(true)
    local few = make_starts(20, 'few')
    local list, text = series(g, few, 8, 100)
    local low, high = per_start(g, few)
    note('20 starts: aborts per 100 frames %s; per start %d-%d; churning %d, handled %d', text, low, high,
        g.public.starts, g.public.handled)
    -- The function entries' retries back off exponentially (72, 144, ... calls), as LuaJIT intends.
    assert(list[8] * 10 < list[1] and high <= 22 and g.public.starts == 0 and g.public.handled == 0 and bumps == 0)
    assert(not g.public.located, 'Nothing churned, so nothing was located')
end

-- (d) and the baseline: switched off, 100 starts churn without end; counted, never bumped.
do
    local _, g = started(false)
    local starts = make_starts(100, 'off')
    local t0 = clock()
    local list, text = series(g, starts, 10, 100)
    local low, high = per_start(g, starts)
    note('off, 100 starts: aborts per 100 frames %s; per start %d-%d; churning %d, handled %d (%.1f s)',
        text, low, high, g.public.starts, g.public.handled, clock() - t0)
    assert(g.public.mode == 'watch only (switched off)' and not g.public.located)
    assert(g.public.handled == 0 and bumps == 0, 'Switched off: no bumps')
    local churned = 0
    for i = 1, #starts do
        if g.aborts_of(starts[i]) > 10 * guard.CHURN_ABORTS then churned = churned + 1 end
    end
    -- Now and then one start's slot survives long enough for LuaJIT to blacklist it.
    assert(list[10] >= 10000 and churned >= 90, 'Without the guard the starts keep aborting: ' .. churned)
    assert(g.public.starts >= 100, 'Every churning start is counted')
end

-- (a) and (c): the same with the guard on, 100 new starts.
do
    jit.flush()
    local _, g = started(true)
    local starts = make_starts(100, 'on')
    local t0 = clock()
    local list, text = series(g, starts, 40, 100)
    local settled = 0
    for i = 1, #starts do settled = settled - g.aborts_of(starts[i]) end
    local more, more_text = series(g, starts, 10, 100)
    for i = 1, #starts do settled = settled + g.aborts_of(starts[i]) end
    text = text .. " | " .. more_text
    local low, high = per_start(g, starts)
    note('on, 100 starts: aborts per 100 frames %s; per start %d-%d; churning %d, handled %d, bumps %d, '
        .. 'lost bumps %d, blacklisted %d, unmatched %d, retried %d/%d; the 100 starts in the last 1000 frames: %d (%.1f s)', text, low, high, g.public.starts, g.public.handled,
        bumps, g.public.returned, g.public.blacklisted, g.public.unmatched, g.public.retried, g.public.not_retried, settled, clock() - t0)
    assert(g.public.located and g.public.mode == 'on', g.public.mode)
    local tail = 0
    for i = 1, #more do tail = tail + more[i] end
    -- A few slow starts (function entries retried every 72 calls) may still be on their way to
    -- CHURN_ABORTS, or to LuaJIT's own blacklist once fewer than 64 starts abort.
    assert(settled <= 2 * guard.CHURN_ABORTS, 'The 100 starts stop aborting: ' .. settled .. ' in the last 1000 frames')
    assert(tail <= 50 and list[1] > 10 * tail, 'Total aborts settle')
    assert(g.public.handled == g.public.starts and g.public.starts >= 100, 'Every churning start is handled')
    assert(wrong == 0, 'Every bump hits the start\'s own slot: ' .. wrong .. ' wrong')
    local lines = {}
    g.add_lines(lines)
    note('header: %s', lines[1])
    note('%s', lines[2])
    assert(lines[2] == '  churn guard located: thread (%p) glref, ReadProcessMemory 16384 bytes, J->param at global_State + 1964',
        lines[2])
    assert(lines[1]:find('^LuaJIT churn: %d+ starts kept failing %(handled %d+%); top owners: .*churn_on_')
        and lines[1]:find('; guard on$'), lines[1])
    local named
    for i = 2, #lines do named = named or lines[i]:match('^  churn: churn_on_%d+:1 NYI: bytecode; %d+ aborts; handled$') end
    assert(named, 'A churning start is named with its chunk, line, reason and count')
    assert(lines[#lines]:find('^  churn: %d+ more not listed$'), lines[#lines])

    -- (e) No trace events, no work: the handled starts and compiled code run without allocating.
    -- The test's own frame loop stays out of the JIT, so only the starts and compiled code run.
    local compiled = assert(load('local s = 0 return function() for i = 1, 100 do s = s + i end return s end'))()
    local function idle(count)
        for _ = 1, count do
            frames(starts, 1)
            compiled()
        end
    end
    jit.off(idle)
    idle(200)
    -- A straggler (above) may still abort now and then: measure windows until one has no event.
    local grew, quiet, windows = nil, false, 0
    while not quiet and windows < 20 do
        windows = windows + 1
        collectgarbage('stop')
        local aborts, kb = g.public.aborts, collectgarbage('count')
        idle(200)
        grew = collectgarbage('count') - kb
        collectgarbage('restart')
        quiet = g.public.aborts == aborts
    end
    note('200 frames without trace events: %.3f KB allocated (window %d)', grew, windows)
    assert(quiet and grew == 0, 'Idle frames allocate nothing')

end

-- Locate refuses limits other than the ones set; a missing address is not found.
do
    local penalty, reason = native.locate({traces = 1, mcode_kb = 1})
    assert(penalty == nil and reason:find('^limits differ'), tostring(reason))
    local t0 = clock()
    local found
    jit.off()
    jit.flush()
    for _ = 1, 1000 do found = assert(native.locate(current_limits())) end
    jit.on()
    note('locate: %.1f us in this process, interpreted (one ReadProcessMemory of %d bytes)', (clock() - t0) * 1e3,
        guard.SCAN_BYTES)
    assert(found.param == PARAM and found.find(1) == nil)
    local f1 = assert(load('return function() end'))
    local maker = assert(load('return function() return function() return 1 end end'))()
    assert(native.identity(maker()) == native.identity(maker()), 'Closures of one prototype share an identity')
    assert(native.identity(f1()) ~= native.identity(maker()) and native.identity(pairs) == nil, 'Builtins have no prototype')
end

-- Per-event cost in this process, interpreted as in the game (no trace starts inside a trace
-- event handler). Test-process timings, not the game's.
do
    local g = guard.new({identity = native.identity, handle = false, clock = function() return 0 end})
    local f = make_starts(1, 'cost')[1]
    local penalty = assert(native.locate(current_limits()))
    local pc = start_address(f, 14)
    local n = 200000
    local churn_aborts = guard.CHURN_ABORTS
    guard.CHURN_ABORTS = 1e9
    jit.off()
    jit.flush()
    local t0 = clock()
    for _ = 1, n do g.event('start', 1, f, 14, nil) end
    local start_us = (clock() - t0) * 1e6 / n
    t0 = clock()
    for _ = 1, n do
        g.event('start', 1, f, 14, nil)
        g.event('abort', 1, f, 10, 7)
    end
    local pair_us = (clock() - t0) * 1e6 / n
    t0 = clock()
    for _ = 1, n do penalty.find(pc) end
    local find_us = (clock() - t0) * 1e6 / n
    jit.on()
    guard.CHURN_ABORTS = churn_aborts
    note('per event in this process, interpreted: start %.3f us, start + counted abort %.3f us, '
        .. '64-slot match of a churning abort %.3f us', start_us, pair_us, find_us)
end

-- (f) Flush growth is unchanged with the guard attached.
do
    budget.START = {mcode = 64, traces = 1000}
    budget.CEILING = {mcode = 1024, traces = 4000}
    jit.flush()
    local logs = 0
    local cache, g = started(true, {log = function() logs = logs + 1 end})
    local count = 0
    for _ = 1, 3000 do
        count = count + 1
        assert(loadstring('local s = 0 for i = 1, 300 do s = s + i * ' .. count .. ' end return s'))()
    end
    local s = cache.public
    note('flush growth with the guard: %d flushes, %d growth steps to %d KB; guard %s', s.flushes, s.growths,
        s.mcode_kb, g.public.mode)
    assert(s.flushes >= 1 and s.growths >= 1 and s.mcode_kb > 64 and logs >= s.growths and g.public.mode == 'on')
end

-- A guard that raises stops; the watcher and its growth go on.
do
    local failed
    local cache = budget.start(jit, {guard = function()
        return {public = {}, event = function() error('boom') end, failed = function(message) failed = message end}
    end})
    frames({make_starts(1, 'raise')[1]}, 50)
    jit.flush()
    note('raising guard: stopped (%s); flushes after it %d', tostring(failed), cache.public.flushes)
    assert(tostring(failed):find('boom', 1, true) and cache.public.flushes >= 1)
end

print('PASS: churn guard in ' .. jit.version .. '\n  ' .. table.concat(out, '\n  '))
