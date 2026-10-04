-- Loader health report, embedded by build.py.
--
-- The loader log is what a player sends with a crash or slowdown report. Besides
-- each module's status it records the game build, how the previous session's log
-- ended, the newest crash dump the game wrote before this start (time, exception
-- code and faulting module offset), and what each module changed in the Lua state
-- every mod shares: globals, library functions, metatables, garbage collector
-- settings and the JIT. Dump file names contain the computer name, so the report
-- never includes them, and module paths are cut to file names.
--
-- Cost: nothing per frame; the report adds no update, render or shutdown hook.
-- Everything runs once while the game starts: one read of the previous log, one
-- listing of the game's dump folder, a few small reads from the newest dump, and
-- per installed module two walks over the shared tables. None of it is compiled
-- (jit.off below), so the report adds no machine code to the JIT code cache every
-- mod shares; tests/test_health.lua checks this in the game's lua51.dll. Startup
-- time unmeasured in game.
local health = {}

-- Captured when the loader starts, before any mod could replace them.
local next, type, rawget, rawequal, pcall, ipairs, tostring = next, type, rawget, rawequal, pcall, ipairs, tostring
local getmetatable, collectgarbage, floor, min = getmetatable, collectgarbage, math.floor, math.min
local sort, concat, format, char, error = table.sort, table.concat, string.format, string.char, error

-- Compiled, the report's functions would hold machine code that never runs
-- again, so the JIT is turned off for the function running this file and every
-- function defined in it, and for nothing else. This file therefore always runs
-- as a function of its own (dofile, or the wrapper build.py puts around it).
-- Under pcall, debug.getinfo level 2 is that function. Both calls are protected:
-- without the debug library, or in a LuaJIT built without the JIT compiler, the
-- report only stays compilable.
if type(debug) == 'table' and type(jit) == 'table' then
    local found, info = pcall(debug.getinfo, 2, 'f')
    if found and type(info) == 'table' then pcall(jit.off, info.func, true) end
end

-- Like assert, without the source position LuaJIT's assert adds to the message.
local function ensure(condition, message)
    if not condition then error(message, 0) end
    return condition
end

-- Library tables compared one level deep, besides the globals themselves.
health.LIBRARIES = {'string', 'table', 'math', 'os', 'io', 'coroutine', 'debug', 'package', 'bit', 'jit'}
health.SHOWN = 6      -- names listed per kind of change; the rest are only counted
health.KEPT = 64      -- names kept per kind of change, so a mod adding thousands costs little
health.LOG_BYTES = 65536
health.DUMP_STREAMS = 256
health.DUMP_MODULES = 4096
health.FOLDER_ENTRIES = 100000

function health.hex(value)
    if type(value) ~= 'number' then return 'unknown' end
    return format('%08X', value)
end

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- Shared state ---------------------------------------------------------------

local function name_of(prefix, key)
    if type(key) == 'string' then return prefix .. key end
    return prefix .. '[' .. type(key) .. ']'
end

local function note(list, name)
    list.total = list.total + 1
    if #list < health.KEPT then list[#list + 1] = name end
end

-- Nil checks use rawequal: comparing a cdata value that has an __eq metamethod
-- (ffi.metatype) with nil runs that metamethod, which is a mod's own code.
local function copy(source)
    local seen, key, value = {}, next(source)
    while not rawequal(key, nil) do
        seen[key] = value
        key, value = next(source, key)
    end
    return seen
end

-- Identity, never a metamethod; NaN counts as unchanged.
local function same(a, b)
    if rawequal(a, b) then return true end
    return type(a) == 'number' and type(b) == 'number' and a ~= a and b ~= b
end

-- Notes what changed in one shared table since its baseline, then advances the
-- baseline so the next module is charged only with its own changes.
local function compare(current, seen, prefix, report_added, found)
    local key, value = next(current)
    while not rawequal(key, nil) do
        local before = seen[key]
        if rawequal(before, nil) then
            if report_added then note(found.added, name_of(prefix, key)) end
            seen[key] = value
        elseif not same(before, value) then
            note(found.replaced, name_of(prefix, key))
            seen[key] = value
        end
        key, value = next(current, key)
    end
    key = next(seen)
    while not rawequal(key, nil) do
        local following = next(seen, key)
        if rawequal(rawget(current, key), nil) then
            note(found.removed, name_of(prefix, key))
            seen[key] = nil
        end
        key = following
    end
end

-- collectgarbage cannot read a setting without writing it: write any value and
-- restore the old one at once. Nothing allocates in between, so no collection
-- step can see the temporary value.
local function gc_setting(collect, option)
    local ok, value = pcall(collect, option, 200)
    if not ok or type(value) ~= 'number' then return nil end
    pcall(collect, option, value)
    return value
end

local function jit_state(library)
    if type(library) ~= 'table' or type(library.status) ~= 'function' then return nil end
    local result = {pcall(library.status)}
    if not result[1] then return nil end
    local flags = {}
    for index = 3, #result do
        if type(result[index]) == 'string' then flags[result[index]] = true end
    end
    return {on = result[2] == true, flags = flags}
end

local function jit_changes(before, after, settings)
    if not before or not after then return end
    if before.on ~= after.on then settings[#settings + 1] = after.on and 'JIT turned on' or 'JIT turned off' end
    local changed = {}
    for flag in next, before.flags do
        if not after.flags[flag] then changed[#changed + 1] = '-' .. flag end
    end
    for flag in next, after.flags do
        if not before.flags[flag] then changed[#changed + 1] = '+' .. flag end
    end
    if #changed > 0 then
        sort(changed)
        settings[#settings + 1] = 'JIT options ' .. concat(changed, ' ')
    end
end

local function setting_change(settings, label, before, after)
    if before ~= nil and after ~= nil and before ~= after then
        settings[#settings + 1] = label .. ' ' .. tostring(before) .. ' -> ' .. tostring(after)
    end
end

-- Collector and JIT settings that changed between two settings() snapshots.
local function settings_changes(settings, before, now)
    setting_change(settings, 'GC pause', before.pause, now.pause)
    setting_change(settings, 'GC step multiplier', before.stepmul, now.stepmul)
    jit_changes(before.jit, now.jit, settings)
    if now.flushes and before.flushes and now.flushes > before.flushes then
        settings[#settings + 1] = 'JIT cache flushed ' .. (now.flushes - before.flushes) .. 'x'
    end
    if before.watching == true and now.watching == false then
        settings[#settings + 1] = "replaced the loader's JIT trace watcher"
    end
end

-- The list a whole shared table goes in when a module swapped it out.
local function swap_kind(found, before, current)
    if rawequal(before, nil) then return found.added end
    if rawequal(current, nil) then return found.removed end
    return found.replaced
end

-- Notes what changed in one scope (a shared table) since the previous module.
local function scope_changes(item, found)
    local current = item.resolve()
    if rawequal(current, item.value) then
        if item.seen then compare(current, item.seen, item.prefix, item.report_added, found) end
        return
    end
    if item.identity then note(swap_kind(found, item.value, current), item.identity) end
    item.value, item.seen = current, type(current) == 'table' and copy(current) or nil
end

-- globals: the table every mod shares. hooks: collect (collectgarbage), jit (the
-- jit library), clock (seconds), flushes() (the loader's JIT flush count) and
-- watching() (whether the loader's JIT watcher is still attached); all optional.
function health.observer(globals, hooks)
    hooks = hooks or {}
    local collect = hooks.collect or collectgarbage
    local scopes = {}
    local function scope(prefix, resolve, identity, report_added)
        local value = resolve()
        scopes[#scopes + 1] = {prefix = prefix, resolve = resolve, identity = identity,
            report_added = report_added, value = value, seen = type(value) == 'table' and copy(value) or nil}
    end
    scope('', function() return globals end, nil, true)
    for _, name in ipairs(health.LIBRARIES) do
        scope(name .. '.', function() return rawget(globals, name) end, nil, true)
    end
    -- Every require adds an entry here, so only replaced or removed entries count.
    scope('package.loaded.', function()
        local package = rawget(globals, 'package')
        if type(package) == 'table' then return rawget(package, 'loaded') end
    end, 'package.loaded', false)
    scope('string metatable.', function() return getmetatable('') end, 'string metatable', true)
    scope('_G metatable.', function() return getmetatable(globals) end, '_G metatable', true)

    local function settings()
        local current = {pause = gc_setting(collect, 'setpause'), stepmul = gc_setting(collect, 'setstepmul'),
            jit = jit_state(hooks.jit)}
        if hooks.flushes then current.flushes = hooks.flushes() end
        if hooks.watching then current.watching = hooks.watching() end
        return current
    end
    local baseline = settings()
    local observer = {initial = {heap_kb = floor(collect('count') + 0.5), pause = baseline.pause,
        stepmul = baseline.stepmul, jit_on = baseline.jit and baseline.jit.on}}

    -- Just before a module loads.
    function observer.mark()
        local mark = {heap = collect('count')}
        if hooks.clock then mark.clock = hooks.clock() end
        return mark
    end

    -- Right after it loaded (or failed): what it changed.
    function observer.changes(mark)
        local heap = collect('count')
        local stop = hooks.clock and hooks.clock()
        local found = {heap_kb = floor(heap - mark.heap + 0.5), settings = {},
            added = {total = 0}, replaced = {total = 0}, removed = {total = 0}}
        if stop and mark.clock then found.ms = floor((stop - mark.clock) * 1000 + 0.5) end
        for _, item in ipairs(scopes) do scope_changes(item, found) end
        local now = settings()
        settings_changes(found.settings, baseline, now)
        baseline = now
        return found
    end
    return observer
end

function health.describe_start(initial)
    local parts = {'heap ' .. initial.heap_kb .. ' KB'}
    if initial.pause then parts[#parts + 1] = 'GC pause ' .. initial.pause end
    if initial.stepmul then parts[#parts + 1] = 'GC step multiplier ' .. initial.stepmul end
    if initial.jit_on ~= nil then parts[#parts + 1] = initial.jit_on and 'JIT on' or 'JIT off' end
    return concat(parts, ', ')
end

local function listed(label, list)
    if list.total == 0 then return nil end
    sort(list)
    local shown = {}
    for index = 1, min(#list, health.SHOWN) do shown[index] = list[index] end
    local text = label .. ' ' .. concat(shown, ', ')
    if list.total > #shown then text = text .. ' (+' .. (list.total - #shown) .. ' more)' end
    return text
end

-- One line: heap change and load time, then changed settings and names.
function health.describe(found)
    local first = 'heap ' .. (found.heap_kb >= 0 and '+' or '') .. found.heap_kb .. ' KB'
    if found.ms then first = first .. ', ' .. found.ms .. ' ms' end
    local parts = {first}
    for _, text in ipairs(found.settings) do parts[#parts + 1] = text end
    for _, kind in ipairs({'added', 'replaced', 'removed'}) do
        local text = listed(kind, found[kind])
        if text then parts[#parts + 1] = text end
    end
    return concat(parts, '; ')
end

-- Game build -----------------------------------------------------------------

-- The PE timestamp of a loaded module (nil for the executable), which
-- identifies the game build. Reads the module's own mapped header.
function health.image_stamp(ffi, kernel, name)
    local base = kernel.GetModuleHandleA(name)
    if base == nil then return nil end
    local bytes = ffi.cast('const uint8_t *', base)
    local header = ffi.cast('const int32_t *', bytes + 0x3C)[0]
    ensure(header >= 64 and header <= 4096, 'unexpected PE header offset')
    ensure(ffi.cast('const uint32_t *', bytes + header)[0] == 0x4550, 'not a PE image')
    return tonumber(ffi.cast('const uint32_t *', bytes + header + 8)[0])
end

-- Previous session -------------------------------------------------------------

-- How the previous session's log ended. The loader writes "Startup finished"
-- last; a log without it ended during startup, and the module it was then
-- loading is the one marked "loading". A log that still reads "After startup:
-- running" ended while the after_startup callbacks ran.
function health.previous_session(text)
    if type(text) ~= 'string' or text == '' then return 'no log' end
    local version = text:match('^Bingus Shared Loader (loader%-v%d+)') or 'unknown loader'
    local started = text:match('\nStarted: ([^\r\n]+)')
    if not started then return version .. ' log without session details' end
    local result = 'started ' .. started .. ' (' .. version .. ')'
    local finished = text:match('\n(Startup finished[^\r\n]*)')
    if finished then
        result = result .. '; ' .. finished:sub(1, 1):lower() .. finished:sub(2)
        if text:find('\nAfter startup: running ', 1, true) then
            return result .. '; its log ended while after_startup callbacks ran'
        end
        return result
    end
    local loading
    for line in text:gmatch('[^\r\n]+') do
        loading = line:match('^(mods/[^:]+): loading$') or loading
    end
    if loading then return result .. '; its log ended while loading ' .. loading end
    return result .. '; its log ended during startup'
end

-- Crash dumps ------------------------------------------------------------------

-- FILETIME (100 ns steps since 1601) to seconds since 1970.
function health.filetime(high, low)
    return floor((high * 4294967296 + low) / 10000000 - 11644473600)
end

-- 'dump' for a crash dump, 'gpu' for a GPU crash report, nil for anything else.
local function entry_kind(name)
    local lower = name:lower()
    if lower:match('%.dmp$') then return 'dump' end
    if lower:match('^gpu_dump') then return 'gpu' end
    return nil
end

-- Whether last write time (high, low) is later than the newest entry's.
local function later(newest, high, low)
    if not newest or high > newest.high then return true end
    return high == newest.high and low > newest.low
end

-- Counts one listed entry; words reads data (WIN32_FIND_DATAA) as uint32s.
-- Directories (attribute 0x10) are skipped.
local function folder_entry(ffi, data, words, found)
    if words[0] % 32 >= 16 then return end
    local name = ffi.string(data + 44, 260):match('^[^%z]*')
    local kind = entry_kind(name)
    if not kind then return end
    local low, high = words[5], words[6]
    if kind == 'dump' then found.dumps = found.dumps + 1 end
    if later(found[kind], high, low) then found[kind] = {name = name, high = high, low = low} end
end

-- The newest crash dump and GPU crash report by last write time, and the dump
-- count. WIN32_FIND_DATAA: attributes at 0, last write time at 20, name at 44.
function health.dump_folder(ffi, kernel, folder)
    local data = ffi.new('uint8_t[320]')
    local handle = kernel.FindFirstFileA(folder .. '/*', data)
    local found = {dumps = 0}
    if handle == ffi.cast('void *', -1) then
        local code = kernel.GetLastError()
        ensure(code == 2 or code == 3 or code == 18, 'dump folder unreadable (error ' .. tostring(code) .. ')')
        return found
    end
    local ok, reason = pcall(function()
        local words = ffi.cast('const uint32_t *', data)
        for _ = 1, health.FOLDER_ENTRIES do
            folder_entry(ffi, data, words, found)
            if kernel.FindNextFileA(handle, data) == 0 then
                ensure(kernel.GetLastError() == 18, 'dump folder listing interrupted')
                return
            end
        end
    end)
    local closed = kernel.FindClose(handle)
    ensure(ok, reason)
    ensure(closed ~= 0, 'dump folder listing close failed')
    return found
end

local function module_name(at, rva)
    local length = u32(at(rva, 4), 0)
    ensure(length <= 2048 and length % 2 == 0, 'unexpected module name')
    local raw, chars = at(rva + 4, length), {}
    for index = 1, length - 1, 2 do
        local low, high = raw:byte(index, index + 1)
        chars[#chars + 1] = (high == 0 and low >= 32 and low < 127) and char(low) or '?'
    end
    return (concat(chars):match('[^\\/]*$'))
end

-- Where the first exception stream (6) and module list stream (4) start, from
-- the stream directory (12 bytes per entry: kind at 0, offset at 8).
local function stream_offsets(entries, count)
    local exception, modules
    for index = 0, count - 1 do
        local kind, rva = u32(entries, index * 12), u32(entries, index * 12 + 8)
        if kind == 6 and not exception then exception = rva end
        if kind == 4 and not modules then modules = rva end
    end
    return exception, modules
end

-- Adds the module holding result.address and the executable's stamp. Each
-- MINIDUMP_MODULE is 108 bytes: base at 0, size at 8, stamp at 16, name at 20.
local function add_modules(at, modules, result)
    local total = u32(at(modules, 4), 0)
    ensure(total <= health.DUMP_MODULES, 'unexpected module count')
    local list = at(modules + 4, total * 108)
    for index = 0, total - 1 do
        local entry = index * 108
        local base = u32(list, entry) + u32(list, entry + 4) * 4294967296
        if result.address >= base and result.address - base < u32(list, entry + 8) then
            result.module, result.offset = module_name(at, u32(list, entry + 20)), result.address - base
            result.stamp = u32(list, entry + 16)
            break
        end
    end
    -- The executable is listed first; its stamp names the build that crashed.
    if total > 0 and module_name(at, u32(list, 20)):lower() == 'helldivers2.exe' then
        result.game_stamp = u32(list, 16)
    end
end

-- The exception record of a minidump (stream 6) and the module it hit (stream
-- 4): {code, address, module, offset, stamp, game_stamp}, or {} without one.
function health.read_dump(file)
    local function at(offset, count)
        ensure(file:seek('set', offset) == offset, 'dump seek failed')
        if count == 0 then return '' end
        local bytes = file:read(count)
        ensure(bytes and #bytes == count, 'truncated dump')
        return bytes
    end
    local header = at(0, 32)
    ensure(u32(header, 0) == 0x504D444D, 'not a minidump')
    local count, directory = u32(header, 8), u32(header, 12)
    ensure(count > 0 and count <= health.DUMP_STREAMS, 'unexpected stream count')
    local exception, modules = stream_offsets(at(directory, count * 12), count)
    if not exception then return {} end
    local record = at(exception, 32)
    local result = {code = u32(record, 8), address = u32(record, 24) + u32(record, 28) * 4294967296}
    if modules then add_modules(at, modules, result) end
    return result
end

-- What read_dump found, as the rest of the crash dump line.
local function exception_text(dump)
    if not dump.code then return ', no exception record' end
    local text = ', exception ' .. format('0x%08X', dump.code) .. ' at '
    if dump.module then
        text = text .. dump.module .. format('+0x%X', dump.offset) .. ' (module stamp ' .. health.hex(dump.stamp) .. ')'
    else
        text = text .. format('0x%X', dump.address) .. ' (outside every module)'
    end
    if dump.game_stamp then text = text .. ', executable stamp ' .. health.hex(dump.game_stamp) end
    return text
end

-- Opens, reads and closes one dump. The path is never part of the result: dump
-- file names contain the computer name.
local function dump_text(open, path)
    local file = open(path, 'rb')
    if not file then return ', unreadable (cannot open)' end
    local ok, dump = pcall(health.read_dump, file)
    pcall(file.close, file)
    if not ok then return ', unreadable (' .. tostring(dump) .. ')' end
    return exception_text(dump)
end

-- Report lines for the dump folder. open: io.open; date(seconds): local time text.
function health.crashes(ffi, kernel, folder, open, date)
    local found = health.dump_folder(ffi, kernel, folder)
    local lines = {'Newest crash dump: none'}
    if found.dump then
        local when = date(health.filetime(found.dump.high, found.dump.low))
        local details = dump_text(open, folder .. '/' .. found.dump.name)
        local total = found.dumps .. (found.dumps == 1 and ' dump' or ' dumps') .. ' in total'
        lines[1] = 'Newest crash dump: ' .. when .. details .. '; ' .. total
    end
    if found.gpu then
        lines[#lines + 1] = 'Newest GPU crash report: ' .. date(health.filetime(found.gpu.high, found.gpu.low))
    end
    return lines
end

return health
