-- The cache budget inside the game's own LuaJIT 2.1.0-alpha (run by test_jit_budget_game.py).
local source = assert(arg[1])
local budget = dofile(source .. '/jit_budget.lua')
assert(jit.version == 'LuaJIT 2.1.0-alpha' and jit.status(), 'Expected the game LuaJIT with the compiler on')

-- The real limits are accepted as jit.opt options.
assert(pcall(jit.opt.start, 'maxmcode=' .. budget.CEILING.mcode, 'maxtrace=' .. budget.CEILING.traces))

-- Shrink the scale so real overflows happen quickly: one 64 KB area at first.
budget.START = {mcode = 64, traces = 1000}
budget.CEILING = {mcode = 1024, traces = 4000}
jit.flush()
local logs = 0
local cache = budget.start(jit, {log = function() logs = logs + 1 end})
local s = cache.public
assert(s.managed and s.expanded and s.watcher)

-- Each chunk is a separate function with its own hot loop, so each compiles to its own trace.
local count = 0
local function compile(batch)
    for _ = 1, batch do
        count = count + 1
        assert(loadstring('local s = 0 for i = 1, 300 do s = s + i * ' .. count .. ' end return s'))()
    end
end
compile(3000)
assert(s.flushes >= 1, 'The alpha JIT should flush when its machine-code limit is reached')
assert(s.growths >= 1 and s.mcode_kb > 64 and logs >= s.growths)

-- Growth converges: a later batch of new code compiles without any flush.
local settled = false
for _ = 1, 20 do
    local before = s.flushes
    compile(500)
    if s.flushes == before then settled = true; break end
end
assert(settled, 'Grown limits should eventually hold new code without a flush')
assert(s.mcode_kb <= budget.CEILING.mcode and s.traces <= budget.CEILING.traces)

return string.format('%s: %d flushes, %d growth steps to %d KB / %d traces',
    jit.version, s.flushes, s.growths, s.mcode_kb, s.traces)
