-- Embedded by build.py; never requires an unverified game resource.
local discovery = {}
local family = '9ba626afa44a3aa3'
local lua_type = '\226\023\209\044\250\141\078\161'

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

local function scan_file(file, hash, seen, names, entries)
    local size = assert(file:seek('end'), 'archive size unavailable')
    assert(size >= 72, 'truncated header')
    local header = read_at(file, 0, 72)
    assert(u32(header, 0) == 0xf0000011, 'invalid archive magic')
    local types, count = u32(header, 4), u32(header, 8)
    local table_start = 72 + 32 * types
    local table_end = table_start + 80 * count
    assert(types > 0 and table_end <= size, 'truncated archive tables')
    for index = 0, count - 1 do
        local row = read_at(file, table_start + index * 80, 80)
        if row:sub(9, 16) == lua_type then
            local key = row:sub(1, 8)
            local offset, length = offset64(row, 16), u32(row, 56)
            if not seen[key] and offset and offset >= table_end and length >= 8
                and offset <= size and length <= size - offset then
                local envelope = read_at(file, offset, 8)
                local body_length = u32(envelope, 0)
                if u32(envelope, 4) == 2 and body_length <= length - 8 then
                    -- Even an unmarked or mismatched override hides an older declaration.
                    seen[key] = true
                    local prefix = read_at(file, offset + 8, math.min(body_length, 256))
                    local name = discovery.declaration(prefix)
                    if name and hash(name) == key and not names[name] then
                        names[name] = true
                        entries[#entries + 1] = name
                    end
                end
            end
        end
    end
end

function discovery.scan(paths, hash, open_file)
    local ordered = {}
    for _, path in ipairs(paths) do
        local suffix = path:match('[/\\]?' .. family .. '%.patch_(%d+)$')
        local basename = path:match('([^/\\]+)$')
        if suffix and basename == family .. '.patch_' .. suffix then
            local number = suffix:gsub('^0+', '')
            ordered[#ordered + 1] = {path = path, number = number}
        end
    end
    table.sort(ordered, function(a, b)
        if #a.number ~= #b.number then return #a.number > #b.number end
        if a.number ~= b.number then return a.number > b.number end
        return a.path < b.path
    end)
    local seen, names, entries, warnings = {}, {}, {}, {}
    for _, item in ipairs(ordered) do
        local ok, file, reason = pcall(open_file, item.path, 'rb')
        if ok and file then
            local parsed, problem = pcall(scan_file, file, hash, seen, names, entries)
            local closed, close_result = pcall(file.close, file)
            if not parsed then warnings[#warnings + 1] = item.path .. ': ' .. tostring(problem) end
            if not closed or close_result == nil then warnings[#warnings + 1] = item.path .. ': close failed' end
        else
            warnings[#warnings + 1] = item.path .. ': ' .. tostring(ok and reason or file)
        end
    end
    return entries, warnings
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

function discovery.discover()
    local ffi, bit = builtin('ffi'), builtin('bit')
    ffi.cdef [[
        uint32_t GetModuleFileNameA(void *module, char *filename, uint32_t size);
        void *FindFirstFileA(const char *pattern, void *data);
        int FindNextFileA(void *handle, void *data);
        int FindClose(void *handle);
        uint32_t GetLastError(void);
    ]]
    local kernel = ffi.load('kernel32')
    local buffer = ffi.new('char[32768]')
    local length = kernel.GetModuleFileNameA(nil, buffer, 32768)
    assert(length > 0 and length < 32768, 'game executable path unavailable or truncated')
    local prefix = discovery.archive_prefix(ffi.string(buffer, length))
    return discovery.scan(discovery.enumerate(ffi, kernel, prefix), discovery.hasher(ffi, bit), io.open)
end

return discovery
