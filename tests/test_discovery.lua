local source = assert(arg[1])
local ffi, bit = require('ffi'), require('bit')
local d = dofile(source .. '/discover.lua')
local hash = d.hasher(ffi, bit)
local function hex(bytes) return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
for name, expected in pairs({
    lua = 'e217d12cfa8d4ea1',
    ['core/wwise/lua/wwise_flow_callbacks'] = '0a4862bbd9fd5172',
    ['mods/codex/loader'] = '8fd2118723773c32',
    ['mods/example_author/example_addon'] = 'cae1a16c51b15d83',
    ['mods/patpatpatrick/example_addon'] = 'e77ec0a4d774ef48',
    ['mods/new_author/group/Example_2'] = 'cd008e543e02bd52',
}) do assert(hex(hash(name)) == expected, name) end

local function u32(n)
    local out = {}
    for i = 1, 4 do out[i] = string.char(n % 256); n = math.floor(n / 256) end
    return table.concat(out)
end
local function replace(s, offset, value) return s:sub(1, offset) .. value .. s:sub(offset + #value + 1) end
local function archive(rows)
    local header = u32(0xf0000011) .. u32(1) .. u32(#rows) .. string.rep('\0', 60)
    local types = string.rep('\0', 8) .. hash('lua') .. u32(#rows) .. string.rep('\0', 12)
    local table_rows, bodies, offset = {}, {}, 104 + 80 * #rows
    for _, item in ipairs(rows) do
        local body = u32(#item.body) .. u32(2) .. item.body
        local row = (item.key or hash(item.name)) .. (item.kind or hash('lua')) .. u32(offset)
            .. string.rep('\0', 36) .. u32(#body) .. string.rep('\0', 20)
        assert(#row == 80)
        table_rows[#table_rows + 1] = row
        bodies[#bodies + 1] = body
        offset = offset + #body
    end
    return header .. types .. table.concat(table_rows) .. table.concat(bodies)
end
local function marked(name) return {name = name, body = '-- HD2-Addon: ' .. name .. '\nerror("never execute during discovery")'} end
local a, b = 'mods/new_author/group/Example_2', 'mods/patpatpatrick/example_addon'
local paths = {'/game/data/9ba626afa44a3aa3.patch_2', '/game/data/9ba626afa44a3aa3.patch_10'}
local function scan(files, extra)
    local closed, opened, largest = 0, 0, 0
    local names = {}; for path in pairs(files) do names[#names + 1] = path end
    if extra then names[#names + 1] = extra end
    local entries, warnings = d.scan(names, hash, function(path, mode)
        assert(mode == 'rb'); opened = opened + 1
        local bytes = files[path]
        if not bytes then return nil, 'unreadable' end
        local pos = 0
        return {seek = function(_, whence, offset)
            pos = whence == 'end' and #bytes or offset; return pos
        end, read = function(_, count)
            largest = math.max(largest, count)
            local part = bytes:sub(pos + 1, pos + count); pos = pos + count; return part
        end, close = function() closed = closed + 1; return true end}
    end)
    assert(closed == opened - (extra and 1 or 0), 'file leak')
    assert(largest <= 256, 'unbounded body read')
    return entries, warnings
end
local entries = scan({[paths[1]] = archive({marked(a), marked(b)}), [paths[2]] = archive({marked(a)})})
assert(#entries == 2 and entries[1] == a and entries[2] == b, 'numeric priority or deduplication')
for _, override in ipairs({{name = a, body = 'return true'}, {name = a, body = marked(b).body}}) do
    entries = scan({[paths[1]] = archive({marked(a), marked(b)}), [paths[2]] = archive({override})})
    assert(#entries == 1 and entries[1] == b, 'overridden declaration revived')
end
for _, name in ipairs({'mods//entry', 'mods/author//entry', 'mods/author/entry/', 'mods/author/a-b',
    'mods/author/a.b', 'mods/author/a b', 'mods/codex/loader'}) do
    assert(not d.declaration('-- HD2-Addon: ' .. name .. '\n'))
end
assert(d.declaration('-- HD2-Addon: mods/codex/another\r\n') == 'mods/codex/another')
assert(d.declaration('-- HD2-Addon: mods/any/loader\n') == 'mods/any/loader')
for _, prefix in ipairs({'\239\187\191', '\n', ' ', '\27LJ'}) do
    assert(not d.declaration(prefix .. marked(a).body))
end
local invalid = {name = a, body = '-- HD2-Addon: mods/author/' .. string.rep('x', 256) .. '\n'}
assert(#scan({[paths[1]] = archive({invalid})}) == 0, 'overlong declaration')
assert(#scan({[paths[1] .. '.stream'] = archive({marked(a)}),
    [paths[1] .. '.gpu_resources'] = archive({marked(a)}),
    ['/game/data/other9ba626afa44a3aa3.patch_3'] = archive({marked(a)})}) == 0)
local good = archive({marked(a)})
local corrupt = {'', good:sub(1, 70), good:sub(1, -2), replace(good, 0, u32(0)),
    replace(good, 4, u32(0xffffffff)), replace(good, 8, u32(0xffffffff)),
    replace(good, 120, u32(0)), replace(good, 124, u32(0xffffffff)),
    replace(good, 160, u32(7)), replace(good, 160, u32(0xffffffff)),
    replace(good, 184, u32(0xffffffff)), replace(good, 188, u32(1))}
for _, bytes in ipairs(corrupt) do
    entries = scan({[paths[2]] = bytes, [paths[1]] = archive({marked(b)})})
    assert(#entries == 1 and entries[1] == b, 'malformed archive blocked a later mod')
end
local _, warnings = scan({[paths[1]] = good}, paths[2])
assert(#warnings == 1)
assert(d.archive_prefix('D:\\Games\\HD2\\BIN\\HELLDIVERS2.EXE') == 'D:/Games/HD2/data/9ba626afa44a3aa3')
assert(d.archive_prefix('\\\\server\\share\\HD2\\bin\\helldivers2.exe') == '//server/share/HD2/data/9ba626afa44a3aa3')
for _, path in ipairs({'bin/helldivers2.exe', 'D:/game/other.exe', '/bin/helldivers2.exe'}) do
    assert(not pcall(d.archive_prefix, path))
end

-- Native enumeration handle cleanup, directory filtering and interrupted reads.
for _, fail in ipairs({false, true}) do
    local close_count, next_count = 0, 0
    local kernel = {GetLastError = function() return fail and 5 or 18 end,
        FindClose = function() close_count = close_count + 1; return 1 end}
    kernel.FindFirstFileA = function(pattern, buffer)
        assert(pattern == '/game/data/9ba626afa44a3aa3.patch_*')
        ffi.copy(buffer + 44, '9ba626afa44a3aa3.patch_10')
        return ffi.cast('void *', 1)
    end
    kernel.FindNextFileA = function(_, buffer)
        next_count = next_count + 1
        if next_count == 1 then buffer[0] = 16; return 1 end
        return 0
    end
    local ok, result = pcall(d.enumerate, ffi, kernel, '/game/data/9ba626afa44a3aa3')
    assert(close_count == 1 and ok == not fail)
    if ok then assert(#result == 1 and result[1] == paths[2]) end
end
for _, code in ipairs({2, 5, 18}) do
    local kernel = {FindFirstFileA = function() return ffi.cast('void *', -1) end,
        GetLastError = function() return code end, FindClose = function() error('invalid handle closed') end}
    assert(pcall(d.enumerate, ffi, kernel, '/game/data/9ba626afa44a3aa3') == (code ~= 5))
end
-- Files also close after a read throws.
local closed = false
local _, errors = d.scan({paths[1]}, hash, function()
    return {seek = function(_, mode, offset) return mode == 'end' and 1000 or offset end,
        read = function() error('read failed') end, close = function() closed = true; return true end}
end)
assert(closed and #errors == 1)
print('PASS: discovery hashes, declarations, bounds, numeric priority, shadowing, bounded reads and handle cleanup')
