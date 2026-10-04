-- Per-mod frame attribution through the real coordinator, on a simulated clock.
-- arg[1]: src; arg[2]: the coordinator with the probe hooks (build.py --probe writes
-- build-probe/shared_loader.probe.lua). Writes probe-header-lines.txt beside it.
local source = assert(arg[1])
local coordinator = assert(arg[2])
local temp = assert(os.getenv('TEMP') or os.getenv('TMP'))
local P = dofile(source .. '/frame_probe.lua')

local now, kb = 0, 1000
local function spend(ms, alloc) now = now + ms / 1000; kb = kb + (alloc or 0) end
-- Every clock read costs a microsecond, so the burn loop terminates.
local function tick() now = now + 1e-6; return now end
P.flush_seconds = 5
-- No LOCALAPPDATA: the coordinator never touches the real log folder.
local quiet_os = setmetatable({getenv = function() return nil end}, {__index = os})
local env = setmetatable({print = function() end, os = quiet_os}, {__index = _G})
env._G = env
local names = {['mods/cowboybingus/consistent_vaulting'] = 'a', ['mods/cowboybingus/shallow_water_dive'] = 'b',
    ['mods/cowboybingus/sentry_aim_retention'] = 'c'}
env.stingray = {Application = {can_get = function(kind, name) return kind == 'lua' and names[name] ~= nil end}}
local failing, late_installed, frames_seen, collect_at, collected, c_ran = false, false, 0, nil, false, false
env.update = function(dt) spend(5, 10); frames_seen = frames_seen + 1; return 'vanilla', dt end
env.render = function() spend(2) end
local shutdowns = 0
env.shutdown = function() shutdowns = shutdowns + 1 end
local installers = {
    a = function()
        local previous = env.update
        env.update = function(...)
            -- One collector step inside this layer frees far more than it allocates.
            local collect = collect_at and frames_seen >= collect_at and not collected
            if collect then collected = true end
            spend(1, collect and -500 or 50)
            if frames_seen >= 120 and not late_installed then
                -- A hook installed from inside a callback, after startup.
                late_installed = true
                local inner = env.update
                env.update = function(...) spend(3); return inner(...) end
            end
            return previous(...)
        end
    end,
    b = function() end,
    c = function()
        local previous_update, previous_render = env.update, env.render
        env.update = function(...)
            c_ran = true
            env.CorpseCollisionRepair.realignments = env.CorpseCollisionRepair.realignments + 1
            spend(.2)
            if failing then error('mod c failed') end
            return previous_update(...)
        end
        env.render = function(...) spend(.5); return previous_render(...) end
    end,
}
env.require = function(name)
    installers[names[name]]()
    return true
end
-- Stands in for ECS's state table (work counters) and the memory context.
env.CorpseCollisionRepair = {realignments = 0, native = {}}
local context_reads = 0
env.frame_probe = {start = function(state)
    return P.start(state, {clock = tick, heap = function() return kb end,
        environment = env, directory = temp, block_seconds = 2, burn_ms = 1, seed = 3,
        focus = 'mods/cowboybingus/sentry_aim_retention',
        context = function() context_reads = context_reads + 1; return 1, 40, 3, 12 end})
end}
setfenv(assert(loadfile(coordinator)), env)()
local state = env.CowboyBingusModLoader
assert(state.revision == 'loader-v19-probe4', 'Probe revision ' .. tostring(state.revision))
for name in pairs(names) do assert(state.modules[name] == 'loaded', name .. ' ' .. tostring(state.modules[name])) end
local probe = assert(state.frame_probe, state.frame_probe_failure)
-- Layer order follows load order: game, then each mod that changed a global.
assert(probe.layers == 5, probe.layers)
local expected = {{'update', 'game'}, {'render', 'game'}, {'update', 'mods/cowboybingus/consistent_vaulting'},
    {'update', 'mods/cowboybingus/sentry_aim_retention'}, {'render', 'mods/cowboybingus/sentry_aim_retention'}}
for i, row in ipairs(expected) do
    assert(probe.kinds[i - 1] == row[1] and probe.names[i - 1] == row[2], i .. ': ' .. tostring(probe.names[i - 1]))
end

collect_at = 400
local failed_once, bypassed_frames = false, 0
for frame = 1, 2600 do
    spend(10)
    failing = frame >= 300 and not failed_once
    c_ran = false
    local seen = frames_seen
    local ok, a, b = pcall(env.update, 0.016)
    if failing and c_ran then
        assert(not ok and tostring(a):find('mod c failed'), 'Errors still propagate'); failed_once = true
    else
        assert(ok and a == 'vanilla' and b == 0.016, 'Return values pass through unchanged')
        assert(frames_seen == seen + 1, 'The game update runs in every arm')
        if not c_ran then bypassed_frames = bypassed_frames + 1 end
    end
    env.render()
end
assert(failed_once and bypassed_frames > 100, 'Bypass blocks skip the mods')
assert(probe.layers == 6 and probe.names[5] == 'late hook', 'Late hook adopted as its own layer')
env.shutdown()
assert(shutdowns == 1, 'The game shutdown still runs')

local header = assert(io.open(temp .. '/BingusFrameProbe.log')):read('*a')
assert(header:find('layer=0 kind=update name=game', 1, true) and header:find('name=late hook', 1, true))
assert(header:find('Bingus Frame Probe schema=4', 1, true)
    and header:find('arms=normal,burn,bypass,without block_seconds=2 burn_ms=1.0000 seed=3', 1, true), header)
assert(header:find('focus=mods/cowboybingus/sentry_aim_retention focus_layers=2 context=ecs_offsets', 1, true), header)
assert(tonumber(header:match('start_qpc_ms=([%d.]+)')) >= 0, 'Start time on the performance counter')
local BASE = 14
local sums, counts, clean = {}, {}, {}
local arm_ms, arm_frames, arms_seen, gc_total, flushes, settles, rows = {0, 0, 0, 0}, {0, 0, 0, 0}, {}, 0, 0, 0, 0
local heap_rows, work_rows, idle_rows = 0, 0, 0
for line in io.lines(temp .. '/BingusFrameProbe-seconds.csv') do
    local values = {}
    for value in line:gmatch('[^,]+') do values[#values + 1] = tonumber(value) end
    rows = rows + 1
    local second, frames, frame_ms, arm, burn_ms, heap_kb, flags = values[1], values[2], values[3], values[6],
        values[7], values[8], values[9]
    assert(arm == probe.arm_for(second) - 1, 'Row arm matches the schedule')
    arms_seen[arm] = true
    -- Context is sampled in every arm, including those that skip mods.
    assert(values[10] == 1 and values[11] == 40 and values[12] == 3 and values[13] == 12, 'context ' .. line)
    if values[14] > 0 then work_rows = work_rows + 1 else idle_rows = idle_rows + 1 end
    if heap_kb > 0 then heap_rows = heap_rows + 1 end
    if flags % 2 == 1 then flushes = flushes + 1 end
    local settle = math.floor(flags / 2) % 2 == 1
    if settle then settles = settles + 1; assert(second % 2 == 0, 'Settle marks block starts only') end
    if arm == 1 then assert(burn_ms > .99 and burn_ms < 1.05, 'burn ' .. burn_ms)
    else assert(burn_ms == 0, 'No burn outside burn blocks') end
    -- The late hook arrives within the first few seconds; compare only after it.
    if not settle and second > 9 then
        arm_ms[arm + 1] = arm_ms[arm + 1] + frame_ms * frames; arm_frames[arm + 1] = arm_frames[arm + 1] + frames
    end
    assert((#values - BASE) % 4 == 0, 'Four values per layer')
    for layer = 0, (#values - BASE) / 4 - 1 do
        local ms, kbf, steps = values[BASE + 1 + layer * 4], values[BASE + 3 + layer * 4], values[BASE + 4 + layer * 4]
        if arm == 2 then
            -- Bypass: the game's layers run, no mod layer does.
            assert((layer <= 1) == (ms > 0), 'bypass layer ' .. layer .. ' ms ' .. ms)
        elseif arm == 3 then
            -- Without: only the focus mod's layers (3 update, 4 render) are skipped.
            assert((layer == 3 or layer == 4) == (ms == 0), 'without layer ' .. layer .. ' ms ' .. ms)
        else
            sums[layer] = sums[layer] or {ms = 0, kb = 0}
            sums[layer].ms = sums[layer].ms + ms * frames; sums[layer].kb = sums[layer].kb + kbf * (frames - steps)
            counts[layer] = (counts[layer] or 0) + frames; clean[layer] = (clean[layer] or 0) + frames - steps
            if layer == 2 then gc_total = gc_total + steps end
        end
    end
end
assert(arms_seen[0] and arms_seen[1] and arms_seen[2] and arms_seen[3], 'Every arm scheduled')
assert(context_reads >= rows and work_rows > 0 and idle_rows > 0, 'ECS work counted when it runs')
local function mean(layer, key) return sums[layer][key] / (key == 'kb' and clean[layer] or counts[layer]) end
-- Exclusive time: each layer minus the one it wraps, in the same frame. The
-- burn runs outside every layer, so no layer absorbs it.
assert(math.abs(mean(0, 'ms') - 5) < .05, 'game update ' .. mean(0, 'ms'))
assert(math.abs(mean(2, 'ms') - 1) < .05, 'mod a ' .. mean(2, 'ms'))
assert(math.abs(mean(3, 'ms') - .2) < .02, 'mod c ' .. mean(3, 'ms'))
assert(math.abs(mean(1, 'ms') - 2) < .05 and math.abs(mean(4, 'ms') - .5) < .02, 'render layers')
assert(math.abs(mean(5, 'ms') - 3) < .1, 'late hook ' .. mean(5, 'ms'))
-- The collector step is counted, not averaged in as zero or negative garbage.
assert(gc_total == 1, 'GC steps in mod a ' .. gc_total)
assert(math.abs(mean(0, 'kb') - 10) < .5 and math.abs(mean(2, 'kb') - 50) < 1, 'per-mod garbage ' .. mean(2, 'kb'))
local function arm_mean(arm) return arm_ms[arm + 1] / arm_frames[arm + 1] end
-- Burn blocks are slower by the burn: this is what calibration measures.
local burned = arm_mean(1) - arm_mean(0)
assert(math.abs(burned - 1) < .1, 'burn frame-time difference ' .. burned)
-- Bypass blocks are faster by every mod layer: 1 + .2 + 3 update, .5 render.
local saved = arm_mean(0) - arm_mean(2)
assert(math.abs(saved - 4.7) < .15, 'bypass frame-time difference ' .. saved)
-- Without blocks are faster by the focus mod only: .2 update, .5 render.
local focus_saved = arm_mean(0) - arm_mean(3)
assert(math.abs(focus_saved - .7) < .1, 'without frame-time difference ' .. focus_saved)
assert(flushes >= 2 and settles >= 5 and heap_rows == rows, 'flush, settle and heap columns')
print('PASS: per-mod exclusive update/render time and garbage, GC steps kept out of garbage averages, burn, '
    .. 'mod-bypass and focus-mod arms, context in every arm, flush/settle flags, load order, late hooks, error '
    .. 'propagation, unchanged returns and shutdown flush')

-- The loader log's first lines in both outcomes (probe running, probe failed to start),
-- for tests/test_probe_header.py: line 1 from the coordinator, then the header lines.
do
    local text = assert(io.open(coordinator)):read('*a')
    local first = assert(text:match("local lines = {'([^']+)'}"))
    local out = assert(io.open(coordinator:gsub('[^/\\]+$', '') .. 'probe-header-lines.txt', 'w'))
    local function emit(outcome, header)
        out:write(outcome, '\t', first, '\n')
        for _, line in ipairs(header) do out:write(outcome, '\t', line, '\n') end
    end
    emit('running', state.health.header)
    assert(state.health.header[1]:find('Development build loader-v19-probe4: frame probe schema 4 running', 1, true))
    local failing = setmetatable({print = function() end, os = quiet_os, update = function() end,
        stingray = env.stingray, require = function() return true end, frame_probe = {start = function() error('No performance counter') end}},
        {__index = _G})
    failing._G = failing
    setfenv(assert(loadfile(coordinator)), failing)()
    local other = failing.CowboyBingusModLoader
    assert(other.frame_probe == nil and other.frame_probe_failure:find('No performance counter', 1, true))
    assert(other.health.header[1]:find('not running', 1, true), 'The log names a probe that did not start')
    emit('not running', other.health.header)
    out:close()
    print('PASS: probe revision and loader log line in both outcomes')
end

-- The real context reader: silent unless ECS passed its build check and game.dll is loaded.
do
    local ffi = require('ffi')
    local environment = {}
    local read = P.context_reader(ffi, environment)
    assert(read() == nil, 'No ECS: no context')
    environment.CorpseCollisionRepair = {native = {}}
    assert(read() == nil, 'No game.dll in this process: no context')
    print('PASS: context reader stays silent outside a verified game')
end
