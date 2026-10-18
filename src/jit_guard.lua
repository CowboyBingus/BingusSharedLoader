-- LuaJIT churn guard: finishes LuaJIT's own blacklisting when its penalty cache is too small.
--
-- When a trace start aborts, LuaJIT records it in a 64-slot penalty cache (J->penalty) and
-- doubles its penalty on each further abort; after about 10 aborts the penalty passes 60000 and
-- LuaJIT blacklists the start, so it is never recorded again. With more than 64 starts aborting
-- in turn, entries are evicted before they get there and are recorded again all session. The
-- 64 is compiled into the game's lua51.dll.
--
-- Watch (always on): the loader's trace watcher passes 'start' and 'abort' events here. Each
-- penalized abort (every code but 'retry recording') counts for its start, keyed by function,
-- then bytecode index; closures of one prototype share their counts. A start that aborted more
-- than CHURN_ABORTS times must have been evicted at least once: it is churning, and is logged
-- once with its chunk, line and reason.
--
-- Handle (on unless switched off): at that abort, the guard finds the start's own penalty slot
-- (its bytecode address) and sets the slot's penalty to PENALTY_MAX with one 16-bit store into
-- the jit_State (Lua heap data, never code). On the start's next abort LuaJIT doubles it past the
-- maximum and blacklists exactly that start through its own path. The jit_State is located once,
-- the first time a start churns: one ReadProcessMemory of SCAN_BYTES from global_State.
--
-- Cost: nothing on any frame. Per trace event a few table operations; a new start key or a
-- churning start allocates once. Log rewrites at most once per LOG_INTERVAL seconds.
local guard = {}

local format, concat, sort = string.format, table.concat, table.sort
local pcall, type, tostring, tonumber, setmetatable = pcall, type, tostring, tonumber, setmetatable
local pairs, ipairs, min = pairs, ipairs, math.min
-- Captured when the loader starts. The game's Lua lacks some base globals (no load): each
-- missing one leaves the guard watch only, with the reason in the log.
local coroutine_create = type(coroutine) == 'table' and coroutine.create or nil

-- LuaJIT blacklists a start it still remembers at its 11th penalized abort (checked in the game's
-- lua51.dll), so a 12th proves the start was evicted at least once. Lost events only lower a count.
guard.CHURN_ABORTS = 12
guard.PENALTY_MAX = 60000  -- checked in the game's lua51.dll: 29990 needs two more aborts, 30010 one
guard.RETRY = 6            -- 'retry recording': LuaJIT retries at once and penalizes nothing
guard.BUMPS = 4             -- most penalty bumps per start (a bump is lost when its slot is evicted first)
guard.LOG_INTERVAL = 30
guard.LISTED = 24          -- churning starts named one per line in the loader log
guard.OWNERS = 4           -- owners named in the header line

-- Trace error codes of the game's LuaJIT 2.1.0-alpha (PerformanceBaseline/ledger/jitnames.py;
-- codes 0-18 forced in the game DLL, the rest in 2.1 source order).
guard.REASONS = {
    [0] = 'error thrown or hook called during recording', 'trace too short', 'trace too long', 'trace too deep',
    'too many snapshots', 'blacklisted', 'retry recording', 'NYI: bytecode',
    'leaving loop in root trace', 'inner loop in root trace', 'loop unroll limit reached',
    'bad argument type', 'JIT compilation disabled for function', 'call unroll limit reached',
    'down-recursion, restarting', 'NYI: C function', 'NYI: FastFunc', 'NYI: unsupported variant of FastFunc',
    'NYI: return to lower frame', 'store with nil or NaN key', 'missing metamethod', 'looping index lookup',
    'NYI: mixed sparse/dense table', 'symbol not in cache', 'NYI: unsupported C type conversion',
    'NYI: unsupported C function type', 'guard would always fail', 'too many PHIs', 'persistent type instability',
    'failed to allocate mcode memory', 'machine code too long', 'hit mcode limit (retrying)',
    'too many spill slots', 'inconsistent register allocation', 'NYI: cannot assemble IR instruction',
    'NYI: PHI shuffling too complex', 'NYI: register coalescing too complex',
}

function guard.reason_name(code)
    return guard.REASONS[code] or ('trace error ' .. tostring(code))
end

-- Native layout of the game's non-GC64 LuaJIT 2.1.0-alpha (checked in its lua51.dll, 2026-10-17).
-- GC objects: GCHeader {GCRef nextgc; uint8 marked; uint8 gct}. lua_State: glref (global_State)
-- at +8. GCfuncL: ffid at +6 (0 for Lua functions), MRef pc (first instruction) at +16; a
-- prototype's 64-byte header precedes its first instruction. jit_State follows global_State in
-- GG_State; J->param (15 int32) ends in 56, 10, 4, 4, 15, 3, 2, 64, 24 bytes in, maxtrace first,
-- maxmcode last; J->penalty[64] {MRef pc; uint16 val; uint16 reason} at param + 188 and
-- J->penaltyslot at param + 700. In the game DLL J->param is global_State + 1964. GG_State's
-- hot counters (uint16 hotcount[64], indexed by (start address + 4) / 4 mod 64) follow the
-- jit_State at param + 956; a penalty stores the new penalty value there (not value - 1).
local GCT_THREAD, GCT_PROTO, GCT_FUNC = 6, 7, 8
local G_REF, FUNC_PC, PROTO_SIZE = 8, 16, 64
local TAIL = {56, 10, 4, 4, 15, 3, 2, 64}
local TAIL_OFFSET, MAXMCODE_OFFSET = 24, 56
local PENALTY_OFFSET, SLOT_OFFSET, SLOTS = 188, 700, 64
local HOTCOUNT_OFFSET, HOTCOUNTS = 956, 64
guard.SCAN_BYTES = 16384

-- A GC object's address: string.format('%p') (C, unaffected by a replaced tostring: the game's
-- tostring gives '[function]' and '[thread (deleted)]'), else tostring's 'kind: 0x...'.
local function address_of(value, kind)
    local ok, text = pcall(format, '%p', value)
    local hex = ok and type(text) == 'string' and text:match('^0x(%x+)$')
    if hex then return tonumber(hex, 16), '%p' end
    text = tostring(value)
    hex = type(text) == 'string' and text:match('^' .. kind .. ': 0x(%x+)$')
    return hex and tonumber(hex, 16), 'tostring'
end

-- The tail's int32 index in words (nil when absent): a bounded scan of the copy.
local function find_tail(words, count)
    for i = 0, count - #TAIL do
        if words[i] == TAIL[1] then
            local found = true
            for k = 2, #TAIL do
                if words[i + k - 1] ~= TAIL[k] then found = false; break end
            end
            if found then return i end
        end
    end
end

-- A copy of SCAN_BYTES (or 4 KB when that crosses the end of readable memory) from address.
local function read_copy(ffi, kernel, address)
    for _, size in ipairs({guard.SCAN_BYTES, 4096}) do
        local buffer, done = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]')
        local ok = kernel.ReadProcessMemory(kernel.GetCurrentProcess(), ffi.cast('const void *', address),
            buffer, size, done) ~= 0
        if ok and tonumber(done[0]) == size then return buffer, size end
    end
end

-- Private names, declared when the guard first locates (the first cdef of a name wins for the
-- whole game).
local WINDOWS = [[
    int bsl_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *done)
        __asm__("ReadProcessMemory");
    void *bsl_GetCurrentProcess(void) __asm__("GetCurrentProcess");
]]

local function bind_kernel(ffi)
    ffi.cdef(WINDOWS)
    local library = ffi.load('kernel32')
    return {ReadProcessMemory = library.bsl_ReadProcessMemory, GetCurrentProcess = library.bsl_GetCurrentProcess}
end

-- Native accessors: identity(func) gives a Lua function's bytecode address, shared by every
-- closure of its prototype; locate(limits) finds J->param once and returns the penalty cache.
-- kernel (tests): ReadProcessMemory and GetCurrentProcess; bound at the first locate otherwise.
function guard.native(ffi, kernel)
    local native = {}
    local u8, u32 = 'const uint8_t *', 'const uint32_t *'

    function native.identity(func)
        local address = address_of(func, 'function')
        if not address then return nil end
        local head = ffi.cast(u8, address)
        if head[5] ~= GCT_FUNC or head[6] ~= 0 then return nil end
        local base = ffi.cast(u32, address + FUNC_PC)[0]
        if base < PROTO_SIZE or ffi.cast(u8, base - PROTO_SIZE)[5] ~= GCT_PROTO then return nil end
        return base
    end

    -- limits: {traces = maxtrace, mcode_kb = maxmcode} as the loader set them.
    function native.locate(limits)
        if type(coroutine_create) ~= 'function' then return nil, 'coroutine.create unavailable' end
        -- Kept referenced until locate returns, so the collector cannot free it while it is read.
        local coroutine_object = coroutine_create(function() end)
        local thread, method = address_of(coroutine_object, 'thread')
        if not thread then return nil, 'no thread address' end
        if ffi.cast(u8, thread)[5] ~= GCT_THREAD then return nil, 'thread header not recognised' end
        local g = ffi.cast(u32, thread + G_REF)[0]
        kernel = kernel or bind_kernel(ffi)
        local copy, size = read_copy(ffi, kernel, g)
        if not copy then return nil, 'global_State not readable' end
        local index = find_tail(ffi.cast('const int32_t *', copy), size / 4)
        if not index then return nil, 'J->param not found' end
        local param = g + index * 4 - TAIL_OFFSET
        local ints = ffi.cast('const int32_t *', param)
        if ints[0] ~= limits.traces or ints[MAXMCODE_OFFSET / 4] ~= limits.mcode_kb then
            return nil, format('limits differ (%d traces, %d KB)', ints[0], ints[MAXMCODE_OFFSET / 4])
        end
        local slot = ffi.cast(u32, param + SLOT_OFFSET)
        if slot[0] >= SLOTS then return nil, 'penalty slot index out of range' end
        local pcs = ffi.cast('uint32_t *', param + PENALTY_OFFSET)
        local vals = ffi.cast('uint16_t *', param + PENALTY_OFFSET)
        local penalty = {param = param, global = g,
            route = format('thread (%s) glref, ReadProcessMemory %d bytes, J->param at global_State + %d',
                method, size, param - g)}
        function penalty.find(pc)
            for i = 0, SLOTS - 1 do
                if pcs[2 * i] == pc then return i end
            end
        end
        local hot = ffi.cast('uint16_t *', param + HOTCOUNT_OFFSET)
        function penalty.value(i) return vals[4 * i + 2] end
        function penalty.bump(i) vals[4 * i + 2] = guard.PENALTY_MAX end
        function penalty.slot() return slot[0] end
        -- The start's hot counter, as LuaJIT's 'retry recording' sets it: the next run records.
        -- Only while it still holds what LuaJIT's penalty just set (the slot's old value), which
        -- also confirms the counter's address; false otherwise.
        function penalty.retry_now(pc, expected)
            local i = (pc + 4) / 4 % HOTCOUNTS
            if hot[i] ~= expected then return false end
            hot[i] = 1
            return true
        end
        function penalty.hotcount(pc) return hot[(pc + 4) / 4 % HOTCOUNTS] end
        return penalty
    end
    return native
end

local WEAK_KEYS, WEAK_VALUES = {__mode = 'k'}, {__mode = 'v'}

local function owner_of(info, func, pc)
    local ok, owner, line = pcall(info, func, pc)
    if not ok or type(owner) ~= 'string' then return '?', 0 end
    return (owner:gsub('^[@=]', '')), tonumber(line) or 0
end

-- The header line: count, handled, top owners, mode.
local function header_line(public, owners)
    if public.starts == 0 then return 'LuaJIT churn: no start kept failing; guard ' .. public.mode end
    local names = {}
    for owner in pairs(owners) do names[#names + 1] = owner end
    sort(names, function(a, b)
        if owners[a] ~= owners[b] then return owners[a] > owners[b] end
        return a < b
    end)
    local top = {}
    for i = 1, min(#names, guard.OWNERS) do top[i] = names[i] .. ' ' .. owners[names[i]] end
    return format('LuaJIT churn: %d starts kept failing (handled %d); top owners: %s; guard %s',
        public.starts, public.handled, concat(top, ', '), public.mode)
end

-- options: identity(func) -> bytecode address or nil; locate() -> penalty accessor or nil and a
-- reason; handle (bool); info(func, pc) -> chunk name, line; log() rewrites the loader log;
-- clock() in seconds; on_bump(slot, pc address) for tests.
function guard.new(options)
    local identity, locate, info = options.identity, options.locate, options.info
    local log, clock, on_bump = options.log or function() end, options.clock or function() return 0 end, options.on_bump
    local handling = options.handle and type(locate) == 'function'
    local public = {aborts = 0, starts = 0, handled = 0, returned = 0, unmatched = 0, unlisted = 0, located = false,
                    retried = 0, not_retried = 0, blacklisted = 0, notes = options.notes,
                    mode = handling and 'on' or (options.handle and 'watch only (no native access)'
                        or 'watch only (switched off)')}
    local self = {public = public}
    local by_func, by_base = setmetatable({}, WEAK_KEYS), setmetatable({}, WEAK_VALUES)
    local listed, owners = {}, {}
    local penalty, logged_at, dirty = nil, nil, false
    local start_tr, start_func, start_pc = nil, nil, 0

    local function request_log()
        dirty = true
        local now = clock()
        if logged_at and now - logged_at < guard.LOG_INTERVAL then return end
        logged_at, dirty = now, false
        log()
    end

    -- The starts table of func's prototype: [bytecode index] = record, plus base.
    local function starts_of(func)
        local starts = by_func[func]
        if starts then return starts end
        local base = identity and identity(func)
        starts = base and by_base[base]
        if not starts then
            starts = {base = base}
            if base then by_base[base] = starts end
        end
        by_func[func] = starts
        return starts
    end

    local function churn(record, func, pc, code)
        record.churning = true
        public.starts = public.starts + 1
        local owner, line = owner_of(info or function() end, func, pc)
        owners[owner] = (owners[owner] or 0) + 1
        if #listed < guard.LISTED then
            listed[#listed + 1] = {record = record, where = owner .. ':' .. line, reason = guard.reason_name(code)}
        else
            public.unlisted = public.unlisted + 1
        end
        request_log()
    end

    local function stop_handling(reason)
        handling = false
        public.mode = 'watch only (' .. reason .. ')'
        request_log()
    end

    -- The penalty cache, located at the first churning start; nil (and watch only) when that fails.
    local function penalty_cache()
        if penalty or not handling then return penalty end
        local ok, found, reason = pcall(locate)
        if not ok then found, reason = nil, found end
        if not found then
            stop_handling('locate failed: ' .. tostring(reason))
            return nil
        end
        penalty, public.located, public.route = found, true, found.route
        return penalty
    end

    -- Sets the slot's penalty to the maximum and lets the start record again at its next run, so
    -- LuaJIT's next abort blacklists it before other starts can evict the slot.
    local function bump(record, slot, address)
        if on_bump then on_bump(slot, address, penalty) end
        local value = penalty.value(slot)
        penalty.bump(slot)
        if penalty.retry_now(address, value) then
            public.retried = public.retried + 1
        else
            public.not_retried = public.not_retried + 1
        end
        record.bumps = record.bumps + 1
        if record.bumps == 1 then
            public.handled = public.handled + 1
            request_log()
        end
    end

    -- At an abort of a churning start: finds its penalty slot by its bytecode address. Still at
    -- the maximum, the bump held and LuaJIT has just blacklisted the start; otherwise it bumps
    -- (again, when the slot was evicted before the start ran: at most BUMPS times).
    local function handle(record, base, pc)
        if not penalty_cache() then return end
        local address = base and base + 4 * pc
        local slot = address and penalty.find(address)
        if not slot then
            public.unmatched = public.unmatched + 1
            return
        end
        if record.bumps > 0 then
            if penalty.value(slot) == guard.PENALTY_MAX then
                record.blacklisted, public.blacklisted = true, public.blacklisted + 1
                return
            end
            public.returned = public.returned + 1
        end
        if record.bumps < guard.BUMPS then bump(record, slot, address) end
    end

    local function count(func, pc, code)
        local starts = starts_of(func)
        local record = starts[pc]
        if not record then
            record = {aborts = 0, bumps = 0}
            starts[pc] = record
        end
        record.aborts = record.aborts + 1
        public.aborts = public.aborts + 1
        if record.aborts <= guard.CHURN_ABORTS then return end
        if not record.churning then churn(record, func, pc, code) end
        if handling and not record.blacklisted then handle(record, starts.base, pc) end
    end

    -- The trace watcher's 'start' and 'abort' events (what, trace, function, bytecode index,
    -- abort code, abort info). Side and stitched traces (otr set on 'start') are never penalized.
    function self.event(what, tr, func, pc, otr)
        if what == 'start' then
            if otr == nil then
                start_tr, start_func, start_pc = tr, func, pc
            else
                start_tr, start_func = nil, nil
            end
        elseif what == 'abort' then
            local f = tr == start_tr and start_func
            start_tr, start_func = nil, nil
            if f and otr ~= guard.RETRY then count(f, start_pc, type(otr) == 'number' and otr or 0) end
            if dirty then request_log() end
        end
    end

    -- Penalized aborts counted for func's prototype, all its starts (diagnostics and tests).
    function self.aborts_of(func)
        local starts, total = by_func[func], 0
        for key, record in pairs(starts or {}) do
            if type(key) == 'number' then total = total + record.aborts end
        end
        return total
    end

    function self.failed(message)
        handling = false
        public.mode = 'stopped (' .. tostring(message) .. ')'
        log()
    end

    -- Appends the header line and one line per listed churning start.
    function self.add_lines(lines)
        lines[#lines + 1] = header_line(public, owners)
        if public.route then lines[#lines + 1] = "  churn guard located: " .. public.route end
        if public.notes then lines[#lines + 1] = "  churn guard: " .. public.notes end
        if public.starts > 0 then
            lines[#lines + 1] = format('  churn guard: %d aborts counted; blacklisted %d, lost bumps %d, unmatched %d, '
                .. 'retried %d/%d', public.aborts, public.blacklisted, public.returned, public.unmatched, public.retried,
                public.retried + public.not_retried)
        end
        for _, entry in ipairs(listed) do
            lines[#lines + 1] = format('  churn: %s %s; %d aborts%s', entry.where, entry.reason,
                entry.record.aborts, entry.record.bumps > 0 and '; handled' or '')
        end
        if public.unlisted > 0 then lines[#lines + 1] = '  churn: ' .. public.unlisted .. ' more not listed' end
    end
    return self
end

return guard
