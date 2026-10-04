-- Embedded by build.py; never requires an unverified game resource.
--
-- Discovery runs once, while the game starts, and is never compiled (jit.off
-- below): compiled, its loops would keep machine code that never runs again in
-- the JIT code cache the game and every mod share. tests/test_discovery.lua
-- checks this in the workspace LuaJIT and in the game's lua51.dll.
local discovery = {}
local family = '9ba626afa44a3aa3'
local lua_type = '\226\023\209\044\250\141\078\161'

-- The JIT is turned off for the function running this file and every function
-- defined in it, and for nothing else. This file therefore always runs as a
-- function of its own (dofile, or the wrapper build.py puts around it). Under
-- pcall, debug.getinfo level 2 is that function. Both calls are protected:
-- without the debug library, or in a LuaJIT built without the JIT compiler,
-- discovery only stays compilable.
if type(debug) == 'table' and type(jit) == 'table' then
    local found, info = pcall(debug.getinfo, 2, 'f')
    if found and type(info) == 'table' then pcall(jit.off, info.func, true) end
end

local function builtin(name)
    local loaded = package and package.loaded and package.loaded[name]
    if loaded then return loaded end
    assert(package and package.preload and package.preload[name], name .. ' builtin unavailable')
    return require(name)
end

function discovery.hasher(ffi, bit)
    -- Construct constants at runtime so the bootstrap retains the stock
    -- bytecode flags and can still fall back when the FFI builtin is absent.
    local mix = ffi.new('uint64_t', 0xc6a4a793) * ffi.new('uint64_t', 4294967296) + 0x5bd1e995
    local base = ffi.new('uint64_t', 256)
    local function word(bytes)
        local value = ffi.new('uint64_t', 0)
        for i = #bytes, 1, -1 do value = value * base + bytes:byte(i) end
        return value
    end
    return function(name)
        local h = ffi.new('uint64_t', #name) * mix
        local finish = #name - #name % 8
        for i = 1, finish, 8 do
            local k = word(name:sub(i, i + 7)) * mix
            k = bit.bxor(k, bit.rshift(k, 47)) * mix
            h = bit.bxor(h, k) * mix
        end
        if finish < #name then h = bit.bxor(h, word(name:sub(finish + 1))) * mix end
        h = bit.bxor(h, bit.rshift(h, 47)) * mix
        h = bit.bxor(h, bit.rshift(h, 47))
        local bytes = {}
        for i = 1, 8 do
            bytes[i] = string.char(tonumber(h % base))
            h = h / base
        end
        return table.concat(bytes)
    end
end

function discovery.declaration(prefix)
    local name = prefix:match('^%-%- HD2%-Addon: (mods/[A-Za-z0-9_]+/[A-Za-z0-9_/]+)\r?\n')
    if name and not name:find('//', 1, true) and name:sub(-1) ~= '/'
        and name ~= 'mods/codex/loader' then return name end
end

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function offset64(bytes, offset)
    local high = u32(bytes, offset + 4)
    if high > 2097151 then return nil end -- Lua number's exact integer range.
    return u32(bytes, offset) + high * 4294967296
end

local function read_at(file, offset, count)
    assert(file:seek('set', offset) == offset, 'archive seek failed')
    if count == 0 then return '' end
    local bytes = file:read(count)
    assert(bytes and #bytes == count, 'truncated archive')
    return bytes
end

-- The Lua resource a table row describes: its key, data offset and length, or
-- nil for another resource type or invalid bounds. Reads nothing.
local function lua_row(row, table_end, size)
    if row:sub(9, 16) ~= lua_type then return nil end
    local offset, length = offset64(row, 16), u32(row, 56)
    if not (offset and offset >= table_end and length >= 8 and offset <= size and length <= size - offset) then
        return nil
    end
    return row:sub(1, 8), offset, length
end

-- The body offset and length behind a valid Lua envelope (body length, then
-- version 2), or nil.
local function lua_body(file, offset, length)
    local envelope = read_at(file, offset, 8)
    local body_length = u32(envelope, 0)
    if u32(envelope, 4) ~= 2 or body_length > length - 8 then return nil end
    return offset + 8, body_length
end

-- What a Lua body starts with: 'declared' and the name when its declaration
-- names this very resource, 'compiled' for LuaJIT bytecode, 'undeclared' for
-- any other source (including a declaration of another name).
local function body_kind(prefix, key, hash)
    local name = discovery.declaration(prefix)
    if name and hash(name) == key then return 'declared', name end
    if prefix:sub(1, 3) == '\27LJ' then return 'compiled' end
    return 'undeclared'
end

-- The first copy of a key, from the highest patch, is the one the game loads:
-- even an undeclared or compiled one hides the older declarations, so it is
-- noted before its body is read. A failed read here stops this archive's scan,
-- as it always has. reader: {file, archive, hash, found}.
local function scan_first(reader, key, offset, length)
    local body, body_length = lua_body(reader.file, offset, length)
    if not body then return end
    local copy, found = {archive = reader.archive}, reader.found
    found.copies[key] = {copy}
    found.keys[#found.keys + 1] = key
    copy.kind, copy.name = body_kind(read_at(reader.file, body, math.min(body_length, 256)), key, reader.hash)
    if copy.name then found.entries[#found.entries + 1] = copy.name end
end

-- What a hidden copy is: its kind and declared name, or false when its
-- envelope is not a Lua envelope.
local function hidden_kind(reader, key, offset, length)
    local body, body_length = lua_body(reader.file, offset, length)
    if not body then return false end
    return body_kind(read_at(reader.file, body, math.min(body_length, 256)), key, reader.hash)
end

-- A copy hidden by a higher one only feeds the copies report, and v18 never
-- read it. Its reads therefore never stop the scan: a copy that cannot be read
-- is listed as unreadable, and the scan goes on exactly as without the report.
local function note_hidden(reader, key, offset, length)
    local read, kind, name = pcall(hidden_kind, reader, key, offset, length)
    if read and not kind then return end
    local list = reader.found.copies[key]
    list[#list + 1] = {archive = reader.archive, kind = read and kind or 'unreadable', name = read and name or nil}
end

local function scan_file(file, archive, hash, found)
    local size = assert(file:seek('end'), 'archive size unavailable')
    assert(size >= 72, 'truncated header')
    local header = read_at(file, 0, 72)
    assert(u32(header, 0) == 0xf0000011, 'invalid archive magic')
    local types, count = u32(header, 4), u32(header, 8)
    local table_start = 72 + 32 * types
    local table_end = table_start + 80 * count
    assert(types > 0 and table_end <= size, 'truncated archive tables')
    local reader = {file = file, archive = archive, hash = hash, found = found}
    for index = 0, count - 1 do
        -- Every read seeks to an absolute offset, and LuaJIT clears the stream's
        -- error flag before each read, so a failed hidden-copy read leaves
        -- nothing behind for the next row.
        local key, offset, length = lua_row(read_at(file, table_start + index * 80, 80), table_end, size)
        if key and found.copies[key] then
            note_hidden(reader, key, offset, length)
        elseif key then
            scan_first(reader, key, offset, length)
        end
    end
end

-- Numeric patch order, highest first; the path breaks ties.
local function higher_patch(a, b)
    if #a.number ~= #b.number then return #a.number > #b.number end
    if a.number ~= b.number then return a.number > b.number end
    return a.path < b.path
end

-- The deployed patch archives among paths, in the game's priority order.
local function by_priority(paths)
    local ordered = {}
    for _, path in ipairs(paths) do
        local suffix = path:match('[/\\]?' .. family .. '%.patch_(%d+)$')
        local basename = path:match('([^/\\]+)$')
        if suffix and basename == family .. '.patch_' .. suffix then
            local number = suffix:gsub('^0+', '')
            ordered[#ordered + 1] = {path = path, name = basename, number = number}
        end
    end
    table.sort(ordered, higher_patch)
    return ordered
end

-- Scans one archive into found. Warnings name the archive file only.
local function scan_archive(item, hash, open_file, found)
    local warnings = found.warnings
    local ok, file, reason = pcall(open_file, item.path, 'rb')
    if not (ok and file) then
        -- io.open's reason starts with the full path; keep only the cause.
        local cause = tostring(ok and reason or file):match('([^:]*)$'):gsub('^%s+', '')
        warnings[#warnings + 1] = item.name .. ': cannot open (' .. cause .. ')'
        return
    end
    local parsed, problem = pcall(scan_file, file, item.name, hash, found)
    local closed, close_result = pcall(file.close, file)
    if not parsed then warnings[#warnings + 1] = item.name .. ': ' .. tostring(problem) end
    if not closed or close_result == nil then warnings[#warnings + 1] = item.name .. ': close failed' end
end

local function copy_label(copy)
    return copy.archive .. ' (' .. (copy.kind or 'unreadable') .. ')'
end

-- Archives named per log line; the rest are counted. A pack that carries its
-- own entry in every option repeats that entry once per enabled option.
discovery.SHOWN = 6

-- The first SHOWN items, then how many more.
local function shown(items)
    local text = table.concat(items, ', ', 1, math.min(#items, discovery.SHOWN))
    if #items > discovery.SHOWN then text = text .. ' (+' .. (#items - discovery.SHOWN) .. ' more)' end
    return text
end

-- '<archive> (<kind>) used; hidden: <archive> (<kind>), ...', highest patch first.
local function copies_text(list)
    local hidden = {}
    for index = 2, #list do hidden[#hidden + 1] = copy_label(list[index]) end
    return copy_label(list[1]) .. ' used; hidden: ' .. shown(hidden)
end

-- The name the hidden copies declare and the archives holding them, or nil.
local function hidden_declaration(list)
    local name, archives = nil, {}
    for index = 2, #list do
        local copy = list[index]
        if copy.name then
            name = copy.name
            archives[#archives + 1] = copy.archive
        end
    end
    return name, archives
end

-- Registry names by key, hashed only once an archive repeats a resource.
local function registry_keys(registry, hash)
    local keys = {}
    for _, name in ipairs(registry) do keys[hash(name)] = name end
    return keys
end

-- One resource found in more than one archive. started: the name the loader
-- starts it under (its declared entry or a registry name), or nil.
local function describe(list, started, copies)
    local declared, archives = hidden_declaration(list)
    if started then
        copies.by_name[started] = copies_text(list)
    elseif declared then
        copies.notes[#copies.notes + 1] = 'not started: ' .. declared .. ', declared in ' .. shown(archives)
            .. ', is hidden by ' .. copy_label(list[1])
    end
end

-- Log text for the Lua resources found in more than one archive: by_name, for
-- each started name, which copy the game loads and which are hidden; notes, a
-- line for each declared entry that is not started because the copy the game
-- loads is compiled or undeclared.
local function describe_copies(found, hash, registry)
    local copies, listed = {by_name = {}, notes = {}}, nil
    for _, key in ipairs(found.keys) do
        local list = found.copies[key]
        if #list > 1 then
            listed = listed or registry_keys(registry, hash)
            describe(list, list[1].name or listed[key], copies)
        end
    end
    return copies
end

-- entries: the declared names to start, highest patch first. warnings: archive
-- problems. copies: describe_copies' text. registry: the names the loader
-- starts besides the declared entries.
function discovery.scan(paths, hash, open_file, registry)
    local found = {entries = {}, warnings = {}, copies = {}, keys = {}}
    for _, item in ipairs(by_priority(paths)) do scan_archive(item, hash, open_file, found) end
    -- A diagnostic: if it fails, the entries still start.
    local described, copies = pcall(describe_copies, found, hash, registry or {})
    if not described then copies = {by_name = {}, notes = {'copies unavailable (' .. tostring(copies) .. ')'}} end
    return found.entries, found.warnings, copies
end

function discovery.archive_prefix(executable)
    local path = executable:gsub('\\', '/')
    assert(path:match('^[A-Za-z]:/') or path:match('^//[^/]+/[^/]+/'), 'game path is not absolute')
    local suffix = '/bin/helldivers2.exe'
    assert(path:lower():sub(-#suffix) == suffix, 'unexpected game executable')
    return path:sub(1, -#suffix - 1) .. '/data/' .. family
end

function discovery.enumerate(ffi, kernel, prefix)
    local buffer = ffi.new('uint8_t[320]')
    local handle = kernel.FindFirstFileA(prefix .. '.patch_*', buffer)
    if handle == ffi.cast('void *', -1) then
        local code = kernel.GetLastError()
        assert(code == 2 or code == 18, 'patch enumeration failed: ' .. tostring(code))
        return {}
    end
    local paths = {}
    local ok, reason = pcall(function()
        repeat
            local attributes = tonumber(ffi.cast('uint32_t *', buffer)[0])
            if math.floor(attributes / 16) % 2 == 0 then
                local name = ffi.string(buffer + 44, 260):match('^[^%z]*')
                if name:match('^' .. family .. '%.patch_%d+$') then
                    paths[#paths + 1] = prefix:sub(1, -#family - 1) .. name
                end
            end
            local more = kernel.FindNextFileA(handle, buffer)
            if more == 0 then
                assert(kernel.GetLastError() == 18, 'patch enumeration interrupted')
                break
            end
        until false
    end)
    local closed = kernel.FindClose(handle)
    assert(ok, reason)
    assert(closed ~= 0, 'patch enumeration close failed')
    return paths
end

-- ffi and kernel come from the loader, which declares the Windows functions
-- once under private names and passes them here under their Windows names.
-- registry: the loader's own module names (see scan).
function discovery.discover(ffi, kernel, registry)
    if not (ffi and kernel) then error('Windows functions unavailable', 0) end
    local bit = builtin('bit')
    local buffer = ffi.new('char[32768]')
    local length = kernel.GetModuleFileNameA(nil, buffer, 32768)
    assert(length > 0 and length < 32768, 'game executable path unavailable or truncated')
    local prefix = discovery.archive_prefix(ffi.string(buffer, length))
    return discovery.scan(discovery.enumerate(ffi, kernel, prefix), discovery.hasher(ffi, bit), io.open,
        registry)
end

return discovery
