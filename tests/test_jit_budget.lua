-- Shared LuaJIT cache budget against a recording stand-in for the jit library.
local source = assert(arg[1])
local budget = dofile(source .. '/jit_budget.lua')
local START, CEILING = budget.START, budget.CEILING

local function library(options)
    options = options or {}
    local jit = {calls = {}}
    jit.opt = {start = function(...)
        if options.reject then error('unknown or malformed optimization flag') end
        local call = {...}
        jit.calls[#jit.calls + 1] = table.concat(call, ' ')
        for _, item in ipairs(call) do
            local key, value = item:match('^(%a+)=(%d+)$')
            assert(key == 'maxmcode' or key == 'maxtrace', 'Unexpected JIT option ' .. item)
            jit[key] = tonumber(value)
        end
    end}
    if not options.no_attach then
        jit.attach = function(handler, event)
            if options.attach_error then error('vmevent API disabled') end
            assert(event == 'trace' and jit.handler == nil, 'One trace watcher expected')
            jit.handler = handler
        end
    end
    return jit
end

local function started(options, heap_kb)
    local jit, clock, logs = library(options), {now = 100}, {count = 0}
    local cache = budget.start(jit, {log = function() logs.count = logs.count + 1 end,
        clock = function() return clock.now end, heap = function() return heap_kb or 3000 end})
    return cache, cache.public, jit, clock, logs
end

-- Start: raised limits before anything else, one watcher, no log write of its own.
do
    local cache, s, jit, clock, logs = started()
    assert(s.managed and s.expanded and s.watcher and #jit.calls == 1 and logs.count == 0)
    assert(jit.maxmcode == START.mcode and jit.maxtrace == START.traces)
    assert(s.mcode_kb == START.mcode and s.traces == START.traces and s.flushes == 0 and s.growths == 0)
    assert(cache.describe():find('expanded 16384 KB / 8000 traces', 1, true), cache.describe())
    -- Compiled traces are counted until a flush; other events cost nothing.
    for _ = 1, 5 do jit.handler('start'); jit.handler('stop') end
    jit.handler('abort'); jit.handler('trace_exit')
    assert(#jit.calls == 1 and logs.count == 0)
    -- A flush doubles both limits and is logged at once.
    jit.handler('flush')
    assert(s.flushes == 1 and s.compiled_before_flush == 5 and s.growths == 1 and logs.count == 1)
    assert(jit.maxmcode == 2 * START.mcode and jit.maxtrace == CEILING.traces)
    -- Machine code reaches its ceiling; every growth step is logged.
    jit.handler('flush')
    assert(jit.maxmcode == CEILING.mcode and jit.maxtrace == CEILING.traces and s.growths == 2 and logs.count == 2)
    -- At the ceilings a flush only counts, and the log waits for the interval.
    jit.handler('flush')
    assert(s.flushes == 3 and s.growths == 2 and #jit.calls == 3 and logs.count == 2)
    clock.now = clock.now + budget.LOG_INTERVAL
    jit.handler('flush')
    assert(s.flushes == 4 and logs.count == 3 and #jit.calls == 3)
    assert(cache.describe():find('flushes 4, growth 2; watcher on', 1, true), cache.describe())
end

-- Heap guard: machine code still grows, traces stay while the Lua heap is large.
do
    local _, s, jit = started(nil, budget.HEAP_LIMIT_KB + 1)
    jit.handler('flush')
    assert(s.growths == 1 and jit.maxmcode == 2 * START.mcode and jit.maxtrace == START.traces)
end

-- No jit library, rejected options, and no or broken attach: never an error.
do
    local cache = budget.start(nil)
    assert(not cache.public.managed and cache.describe() == 'LuaJIT cache: unmanaged (jit.opt unavailable)')
    local rejected = started({reject = true})
    assert(not rejected.public.managed and rejected.describe():find('rejected', 1, true))
    local _, s1 = started({no_attach = true})
    local _, s2 = started({attach_error = true})
    assert(s1.managed and not s1.watcher and s2.managed and not s2.watcher)
end
print('PASS: JIT cache limits, flush growth to ceilings, heap guard, log interval and failure isolation')
