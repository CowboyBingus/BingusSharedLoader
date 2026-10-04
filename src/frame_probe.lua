-- Development-only per-mod frame attribution for real play sessions. Only
-- `build.py --probe` embeds this file; public loader builds never contain it.
--
-- Before any mod loads, the game's own update/render functions become layer 0.
-- After each mod's require, a changed global becomes that mod's layer. Every
-- layer times its call; a mod's exclusive cost is its layer minus the layer it
-- wraps, measured in the same frame. The same subtraction on the Lua heap
-- gives the garbage each mod leaves per frame. Mods that patch game functions
-- directly, rather than wrapping update/render, land inside layer 0.
--
-- Arms: whole-second blocks rotate through four arms in a seeded order per
-- cycle, so every play session - hosting, joining, ship - is its own
-- randomized experiment:
--   normal   every layer runs as usual;
--   burn     as normal, plus a known busy-wait at the start of every frame,
--            outside every layer: how much main-thread time reaches frame
--            time on this machine (pass-through);
--   bypass   the outermost wrapper calls the game's own update/render
--            directly, skipping every mod layer: the frame cost of all mod
--            hooks, including the collector work their garbage causes;
--   without  only the focus mod's layers (Enemy Collision Synchronized by
--            default) are skipped: that mod's own cost, in the same sessions.
-- Function patches stay active in every arm.
--
-- Context: once a second, identically in every arm, the probe reads the
-- mission flag and the ragdoll/corpse manager populations, including how many
-- active ragdolls this machine owns (a client owns few; a host owns most).
-- It uses the offsets Enemy Collision Synchronized verifies for this game
-- build, and only while that mod reports its build check passed; otherwise
-- the context columns stay -1. ECS's work counters give its activity level.
--
-- Timing: the header records the probe's start on the performance counter,
-- in milliseconds, so frames PresentMon records from outside the game
-- (--qpc_time_ms) can be matched to each second and arm.
--
-- Garbage: an incremental collector step runs inside whichever layer pushes
-- the allocation debt over. A layer whose exclusive heap delta is negative ran
-- such a step; that frame counts as a GC step and is left out of its
-- allocation average.
--
-- Rows go once a minute to %LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/
-- BingusFrameProbe-seconds.csv, with names and settings in BingusFrameProbe.log.
local P = {schema = 4, max_layers = 32, flush_seconds = 60, block_seconds = 10, burn_ms = 1.0,
    focus = 'mods/cowboybingus/corpse_collision_repair'}
P.arms = {'normal', 'burn', 'bypass', 'without'}
P.row_flags = {flush = 1, settle = 2}
-- Game offsets, as Enemy Collision Synchronized decodes them (corpse_data.lua).
P.offsets = {mode = 0x33266a0, ragdolls = 0x3326948, corpses = 0x3326920}
P.ecs_counters = {'realignments', 'fling_stops', 'completion_requests', 'claws_disabled'}

-- Mission flag, active ragdolls, owned ragdolls and corpses, read through
-- ReadProcessMemory so a stale pointer fails the read instead of the game.
-- Returns nil unless ECS has passed its game-build check.
function P.context_reader(ffi, environment)
    -- Private names: the first cdef of a name wins for the whole game (see shared_loader.lua).
    pcall(ffi.cdef, [[
        void *bfp_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        void *bfp_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        int bfp_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read) __asm__("ReadProcessMemory");
    ]])
    local kernel = ffi.load('kernel32')
    local read_memory = ffi.cast('int (*)(void *, const void *, void *, size_t, size_t *)', kernel.bfp_ReadProcessMemory) -- lint-ok: R2 development-only probe, never shipped; once per session
    local process = kernel.bfp_GetCurrentProcess()
    local word, number, count = ffi.new('uint64_t[1]'), ffi.new('uint32_t[1]'), ffi.new('size_t[1]')
    -- The same eight bytes as two 32-bit halves: a 64-bit literal in the
    -- comparison would change the bytecode header the build checks.
    local halves = ffi.cast('uint32_t *', word)
    local game
    local function pointer(address)
        if read_memory(process, address, word, 8, count) == 0 or count[0] ~= 8 then return nil end
        local low, high = halves[0], halves[1]
        if high >= 0x8000 or (high == 0 and low < 0x10000) then return nil end
        return ffi.cast('uint8_t *', word[0])
    end
    local function u32(address)
        if read_memory(process, address, number, 4, count) == 0 or count[0] ~= 4 then return nil end
        return number[0]
    end
    return function()
        local ecs = rawget(environment, 'CorpseCollisionRepair')
        if type(ecs) ~= 'table' or ecs.native == nil then return nil end
        if game == nil then
            local handle = kernel.bfp_GetModuleHandleA('game.dll')
            if handle == nil then return nil end
            game = ffi.cast('uint8_t *', handle)
        end
        local mode = pointer(game + P.offsets.mode)
        local mission = mode and u32(mode + 8)
        local ragdolls = pointer(game + P.offsets.ragdolls)
        local corpses = pointer(game + P.offsets.corpses)
        return mission == 1 and 1 or 0, ragdolls and u32(ragdolls + 16), ragdolls and u32(ragdolls + 20),
            corpses and u32(corpses + 24)
    end
end

function P.start(state, options)
    options = options or {}
    local ffi = require('ffi')
    local clock = options.clock
    if not clock then
        pcall(ffi.cdef, 'int bfp_QueryPerformanceCounter(void *counter) __asm__("QueryPerformanceCounter"); '
            .. 'int bfp_QueryPerformanceFrequency(void *frequency) __asm__("QueryPerformanceFrequency");')
        local kernel = ffi.load('kernel32')
        local counter = ffi.cast('int (*)(void *)', kernel.bfp_QueryPerformanceCounter) -- lint-ok: R2 development-only probe, never shipped; once per session
        local frequency = ffi.new('int64_t[1]')
        assert(ffi.cast('int (*)(void *)', kernel.bfp_QueryPerformanceFrequency)(frequency) ~= 0, 'No performance counter') -- lint-ok: R2 development-only probe, never shipped; once per session
        local hz, halves = tonumber(frequency[0]), ffi.new('uint32_t[2]')
        -- Two 32-bit halves: a 64-bit read would box a cdata on every call.
        clock = function() counter(halves); return (halves[0] + halves[1] * 4294967296) / hz end
    end
    local heap = options.heap or function() return collectgarbage('count') end
    local environment = options.environment or _G
    local block_seconds = options.block_seconds or P.block_seconds
    local burn_seconds = (options.burn_ms or P.burn_ms) / 1000
    local focus = options.focus or P.focus
    local read_context = options.context
    if read_context == nil then
        local ok, reader = pcall(P.context_reader, ffi, environment)
        read_context = ok and reader or false
    end
    local max = P.max_layers
    local p = {names = {}, kinds = {}, layers = 0, frames = 0, started = clock(), written_seconds = 0,
        write_failures = 0, seed = options.seed or math.floor((clock() % 1) * 2147483646) + 1,
        block_seconds = block_seconds, burn_ms = burn_seconds * 1000, focus = focus, focus_layers = 0,
        context_failures = 0}
    -- Per-frame scratch, then per-second accumulators, all preallocated.
    local inclusive, inclusive_heap = ffi.new('double[?]', max), ffi.new('double[?]', max)
    local called = ffi.new('uint8_t[?]', max)
    local sum_ms, sum_kb = ffi.new('double[?]', max), ffi.new('double[?]', max)
    local max_ms, clean, gc_steps = ffi.new('double[?]', max), ffi.new('uint32_t[?]', max), ffi.new('uint32_t[?]', max)
    local second_frames, second_dt, second_max_dt, second_gc, second_burn, second_flags = 0, 0, 0, 0, 0, 0
    local current_second, last_top_entry, last_heap_out = nil, nil, nil
    local burning, bypassing, skipping, pending_flags = false, false, false, 0
    local context = {-1, -1, -1, -1, 0}
    local last_work
    local rows, row_count = {}, 0
    local installed, game_layer = {}, {}
    local order, order_cycle = {1, 2, 3, 4}, nil

    -- Deterministic Fisher-Yates per cycle of blocks; the order table is reused.
    local function shuffle(cycle)
        local seed = (p.seed + cycle * 7919) % 2147483647
        for i = 1, #P.arms do order[i] = i end
        for i = #P.arms, 2, -1 do
            seed = (seed * 48271) % 2147483647
            local j = seed % i + 1
            order[i], order[j] = order[j], order[i]
        end
    end
    -- Arm index (1 normal, 2 burn, 3 bypass, 4 without) for a second since start.
    function p.arm_for(second)
        local block = math.floor(second / block_seconds)
        local cycle = math.floor(block / #P.arms)
        if cycle ~= order_cycle then order_cycle = cycle; shuffle(cycle) end
        return order[block % #P.arms + 1]
    end

    -- Once a second, before any layer runs, identically in every arm.
    local function sample_context()
        context[1], context[2], context[3], context[4], context[5] = -1, -1, -1, -1, 0
        if read_context then
            local ok, mission, active, owned, corpses = pcall(read_context)
            if ok and mission ~= nil then
                context[1], context[2], context[3], context[4] = mission, active or -1, owned or -1, corpses or -1
            elseif not ok then
                p.context_failures = p.context_failures + 1
            end
        end
        local ecs = rawget(environment, 'CorpseCollisionRepair')
        if type(ecs) == 'table' then
            local work = 0
            for _, key in ipairs(P.ecs_counters) do work = work + (tonumber(ecs[key]) or 0) end
            context[5] = last_work and work - last_work or 0
            last_work = work
        end
    end

    local function flush_second(second)
        if second_frames == 0 then return end
        -- Row: second, frames, mean frame ms, max frame ms, gc drops, arm, burn ms/frame, heap KB, flags,
        -- mission, active ragdolls, owned ragdolls, corpses, ECS work, then per layer ms/frame, max ms,
        -- KB per GC-free frame, GC steps.
        local parts = {string.format('%d,%d,%.4f,%.4f,%d,%d,%.4f,%.1f,%d,%d,%d,%d,%d,%d', second, second_frames,
            second_dt / second_frames, second_max_dt, second_gc, p.arm_for(second) - 1, second_burn / second_frames,
            last_heap_out or heap(), second_flags, context[1], context[2], context[3], context[4], context[5])}
        for i = 0, max - 1 do
            if i < p.layers then
                parts[#parts + 1] = string.format('%.5f,%.4f,%.3f,%d', sum_ms[i] / second_frames, max_ms[i],
                    clean[i] > 0 and sum_kb[i] / clean[i] or 0, gc_steps[i])
            end
            sum_ms[i], sum_kb[i], max_ms[i], clean[i], gc_steps[i] = 0, 0, 0, 0, 0
        end
        row_count = row_count + 1
        rows[row_count] = table.concat(parts, ',')
        second_frames, second_dt, second_max_dt, second_gc, second_burn, second_flags = 0, 0, 0, 0, 0, 0
    end

    local function directory()
        local loader = rawget(environment, 'CowboyBingusModLoader') or state
        if loader and not loader.log_directory and loader.open_log then
            local file = loader.open_log('BingusFrameProbe.log'); if file then file:close() end
        end
        return options.directory or (loader and loader.log_directory)
    end

    function p.write()
        local folder = directory()
        if not folder then p.write_failures = p.write_failures + 1; return false end
        local ok = pcall(function()
            local header = assert(io.open(folder .. '/BingusFrameProbe.log', 'w'))
            header:write('Bingus Frame Probe schema=' .. P.schema .. '\n')
            header:write('Row columns: second,frames,frame_ms_mean,frame_ms_max,gc_drops,arm,burn_ms_per_frame,'
                .. 'heap_kb,flags,mission,ragdolls_active,ragdolls_owned,corpses,ecs_work, then per layer: '
                .. 'ms_per_frame,max_ms,kb_per_clean_frame,gc_steps\n')
            header:write(string.format('arms=%s block_seconds=%d burn_ms=%.4f seed=%d flags=flush:%d,settle:%d\n',
                table.concat(P.arms, ','), block_seconds, burn_seconds * 1000, p.seed, P.row_flags.flush,
                P.row_flags.settle))
            header:write(string.format('start_qpc_ms=%.3f focus=%s focus_layers=%d context=%s context_failures=%d\n',
                p.started * 1000, focus, p.focus_layers, read_context and 'ecs_offsets' or 'unavailable',
                p.context_failures))
            for i = 0, p.layers - 1 do
                header:write(string.format('layer=%d kind=%s name=%s\n', i, p.kinds[i], p.names[i]))
            end
            header:write(string.format('frames=%d seconds_written=%d write_failures=%d\n', p.frames,
                p.written_seconds + row_count, p.write_failures))
            header:close()
            local mode = p.written_seconds == 0 and 'w' or 'a'
            local file = assert(io.open(folder .. '/BingusFrameProbe-seconds.csv', mode))
            for i = 1, row_count do file:write(rows[i], '\n') end
            file:close()
        end)
        if ok then
            p.written_seconds = p.written_seconds + row_count
            for i = 1, row_count do rows[i] = nil end
            row_count = 0
        else p.write_failures = p.write_failures + 1 end
        return ok
    end

    -- The outermost update layer marks the frame; it finishes after all others.
    local function frame_begin(now)
        local second = math.floor(now - p.started)
        if current_second and second ~= current_second then
            flush_second(current_second)
            -- Before this frame's layers start, so no layer is charged for it.
            -- The write lands in this second's frame times; the row says so.
            if row_count >= P.flush_seconds then p.write(); pending_flags = P.row_flags.flush end
        end
        if second ~= current_second then
            second_flags = pending_flags; pending_flags = 0
            if second % block_seconds == 0 then second_flags = second_flags + P.row_flags.settle end
            sample_context()
        end
        current_second = second
        if last_top_entry then
            local dt = (now - last_top_entry) * 1000
            second_frames, second_dt = second_frames + 1, second_dt + dt
            if dt > second_max_dt then second_max_dt = dt end
        end
        last_top_entry = now
        local arm = p.arm_for(second)
        burning, bypassing, skipping = arm == 2, arm == 3, arm == 4
        local h = heap()
        if last_heap_out and h < last_heap_out - 1 then second_gc = second_gc + 1 end
        for i = 0, max - 1 do if p.kinds[i] == 'update' then called[i] = 0 end end
    end

    -- Known main-thread work, outside every layer's timing.
    local function burn()
        local start = clock()
        local stop = start + burn_seconds
        local now = start
        while now < stop do now = clock() end
        second_burn = second_burn + (now - start) * 1000
    end

    -- Exclusive cost: each called layer of this kind minus the nearest called
    -- layer of the same kind inside it, all from the same call chain.
    local function settle(kind) -- lint-ok: R10 development-only probe, never shipped
        -- Outermost first: an inner layer's flag must survive until its outer
        -- layer has subtracted it.
        for i = p.layers - 1, 0, -1 do
            if called[i] == 1 and p.kinds[i] == kind then
                local inner = i - 1
                while inner >= 0 and (p.kinds[inner] ~= kind or called[inner] == 0) do inner = inner - 1 end
                local ms, kb = inclusive[i], inclusive_heap[i]
                if inner >= 0 then ms, kb = ms - inclusive[inner], kb - inclusive_heap[inner] end
                sum_ms[i] = sum_ms[i] + ms
                if kb < 0 then gc_steps[i] = gc_steps[i] + 1
                else sum_kb[i] = sum_kb[i] + kb; clean[i] = clean[i] + 1 end
                if ms > max_ms[i] then max_ms[i] = ms end
                called[i] = 0
            end
        end
    end

    local function frame_end()
        p.frames = p.frames + 1
        settle('update')
        last_heap_out = heap()
        -- A hook installed after startup is adopted as its own layer next frame.
        if rawget(environment, 'update') ~= installed.update or rawget(environment, 'render') ~= installed.render then
            p.late()
        end
    end

    local function top_finished(kind, ...)
        if kind == 'update' then frame_end() else settle('render') end
        return ...
    end

    -- inner: the wrapper this layer's function calls, i.e. the global it
    -- replaced; skipping the layer calls it directly.
    local function wrap(kind, name, fn, inner)
        if p.layers >= max then return fn end
        local index = p.layers
        p.layers = index + 1
        p.names[index], p.kinds[index] = name, kind
        local is_focus = name == focus and inner ~= nil
        if is_focus then p.focus_layers = p.focus_layers + 1 end
        local function finish(start, start_heap, top, ...)
            inclusive[index] = (clock() - start) * 1000
            inclusive_heap[index] = heap() - start_heap
            called[index] = 1
            if top then return top_finished(kind, ...) end
            return ...
        end
        local wrapped
        -- The outermost layer is whichever wrapper the global currently holds;
        -- no counter can be left stale if a mod's update raises.
        wrapped = function(...)
            local top = installed[kind] == wrapped
            if top and kind == 'update' then
                frame_begin(clock())
                if burning then burn() end
            end
            if top and bypassing and game_layer[kind] and game_layer[kind] ~= wrapped then
                -- Straight to the game's own function: no mod layer runs.
                return top_finished(kind, game_layer[kind](...))
            end
            if skipping and is_focus then
                -- Only the focus mod is skipped: continue down the chain.
                if top then return top_finished(kind, inner(...)) end
                return inner(...)
            end
            local start, start_heap = clock(), heap()
            return finish(start, start_heap, top, fn(...))
        end
        return wrapped
    end

    local function adopt(kind, label)
        local current = rawget(environment, kind)
        if type(current) == 'function' and current ~= installed[kind] then
            installed[kind] = wrap(kind, label, current, installed[kind])
            rawset(environment, kind, installed[kind])
            if label == 'game' then game_layer[kind] = installed[kind] end
        end
    end
    adopt('update', 'game')
    adopt('render', 'game')

    -- Called by the coordinator after each module's require.
    function p.after(name)
        adopt('update', name)
        adopt('render', name)
    end
    -- A hook installed after startup (from a mod's own callback) is adopted on
    -- the next frame. Its owner is unknown to the loader.
    function p.late()
        adopt('update', 'late hook')
        adopt('render', 'late hook')
    end
    function p.shutdown()
        if current_second then flush_second(current_second); current_second = nil end
        return p.write()
    end
    -- Innermost shutdown hook: mods that wrap shutdown later call it last.
    local previous_shutdown = rawget(environment, 'shutdown')
    rawset(environment, 'shutdown', function(...)
        pcall(p.shutdown)
        if previous_shutdown then return previous_shutdown(...) end
    end)
    return p
end

return P
