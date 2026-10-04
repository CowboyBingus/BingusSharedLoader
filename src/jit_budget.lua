-- Shared LuaJIT code cache for the whole game VM.
--
-- Helldivers 2 ships LuaJIT 2.1.0-alpha with its 2015 limits: 512 KB of machine
-- code and 1000 traces, shared by the game and every mod. Crossing either limit
-- discards every compiled trace, so a busy mission keeps recompiling and runs
-- uncompiled in between. The loader raises both limits before any mod starts
-- and doubles them if a flush still happens. Machine code starts at 64 MB: it
-- is committed only as code is compiled, so a high limit costs nothing until
-- used. LuaJIT never exceeds 65,535 traces whatever maxtrace says.
--
-- Machine code is placed beside lua51.dll, where address space is plentiful.
-- Each trace also keeps about 1 KB of records in the Lua heap, which this LuaJIT
-- must place below 2 GB, where little is free, so the trace limit only grows
-- while the Lua heap is small. LuaJIT keeps one handler per event: another
-- jit.attach(..., 'trace') replaces this watcher and only stops the growth.
--
-- Cost: no work on any frame. The watcher runs only when the JIT starts, stops,
-- aborts or flushes a trace; a flush adds one jit.opt.start call and at most one
-- log write per LOG_INTERVAL seconds (plus one per growth step).
local budget = {}

-- Captured when the loader starts, before any mod could replace them.
local format, min, collectgarbage = string.format, math.min, collectgarbage
local pcall, rawget, rawequal, next, type, tostring = pcall, rawget, rawequal, next, type, tostring

-- jit.opt units: KB of machine code, number of traces.
budget.GAME = {mcode = 512, traces = 1000}
budget.START = {mcode = 65536, traces = 8000}
budget.CEILING = {mcode = 262144, traces = 16000}
budget.HEAP_LIMIT_KB = 24 * 1024
budget.LOG_INTERVAL = 30

local function default_clock()
    local time = type(os) == 'table' and os.time
    if type(time) == 'function' then return time end
    return function() return 0 end
end

-- library: the game's jit table. hooks: log() rewrites the loader log;
-- clock() in seconds and heap() in KB are replaceable for tests; registry()
-- returns the Lua registry (debug.getregistry), used to check the watcher.
function budget.start(library, hooks)
    hooks = hooks or {}
    local log = hooks.log or function() end
    local clock = hooks.clock or default_clock()
    local heap = hooks.heap or function() return collectgarbage('count') end
    local registry = hooks.registry
    local public = {managed = false, expanded = false, watcher = false, flushes = 0, growths = 0,
                    mcode_kb = budget.GAME.mcode, traces = budget.GAME.traces}
    local cache = {public = public}
    -- The loader is the only code that should set these limits (lint rule R5).
    local opt = type(library) == 'table' and type(library.opt) == 'table' and library.opt.start -- lint-ok: R5 owner
    local target = {mcode = budget.START.mcode, traces = budget.START.traces}
    local compiled, logged_at = 0, nil

    local function apply(limits)
        if not pcall(opt, 'maxmcode=' .. limits.mcode, 'maxtrace=' .. limits.traces) then return false end
        public.mcode_kb, public.traces = limits.mcode, limits.traces
        return true
    end

    -- Doubles both limits up to the ceilings. Traces only grow while the Lua
    -- heap is under HEAP_LIMIT_KB; machine code does not use the Lua heap.
    local function grow()
        local mcode = min(target.mcode * 2, budget.CEILING.mcode)
        local traces = target.traces
        if heap() < budget.HEAP_LIMIT_KB then traces = min(target.traces * 2, budget.CEILING.traces) end
        if mcode == target.mcode and traces == target.traces then return false end
        local limits = {mcode = mcode, traces = traces}
        if not apply(limits) then return false end
        target = limits
        public.growths = public.growths + 1
        return true
    end

    local function on_trace(what)
        if what == 'stop' then
            compiled = compiled + 1
        elseif what == 'flush' then
            public.flushes, public.compiled_before_flush, compiled = public.flushes + 1, compiled, 0
            local grew = grow()
            local now = clock()
            if grew or not logged_at or now - logged_at >= budget.LOG_INTERVAL then
                logged_at = now
                log()
            end
        end
    end

    -- Whether the watcher is still attached. LuaJIT keeps one handler per event
    -- in the registry's _VMEVENTS table, so another jit.attach(f, 'trace')
    -- silently replaces it and stops the growth. nil when that is unknown.
    function cache.watching()
        if not public.watcher then return false end
        if type(registry) ~= 'function' then return nil end
        local ok, values = pcall(registry)
        local events = ok and type(values) == 'table' and rawget(values, '_VMEVENTS')
        if type(events) ~= 'table' then return nil end
        for _, handler in next, events do
            if rawequal(handler, on_trace) then return true end
        end
        return false
    end

    function cache.describe()
        if not public.managed then return 'LuaJIT cache: unmanaged (' .. tostring(public.reason) .. ')' end
        local watcher = 'watcher off'
        if public.watcher then watcher = cache.watching() == false and 'watcher replaced' or 'watcher on' end
        return format('LuaJIT cache: expanded %d KB / %d traces; flushes %d, growth %d; %s',
            public.mcode_kb, public.traces, public.flushes, public.growths, watcher)
    end

    if type(opt) ~= 'function' then
        public.reason = 'jit.opt unavailable'
        return cache
    end
    if not apply(target) then
        public.reason = 'jit.opt rejected the limits'
        return cache
    end
    public.managed, public.expanded = true, true
    if type(library.attach) == 'function' then
        public.watcher = pcall(library.attach, on_trace, 'trace')
    end
    return cache
end

return budget
