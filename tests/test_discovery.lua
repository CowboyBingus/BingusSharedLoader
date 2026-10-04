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
local function scan(files, extra, registry, hasher)
    local closed, opened, largest = 0, 0, 0
    local names = {}; for path in pairs(files) do names[#names + 1] = path end
    if extra then names[#names + 1] = extra end
    local entries, warnings, copies = d.scan(names, hasher or hash, function(path, mode)
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
    end, registry)
    assert(closed == opened - (extra and 1 or 0), 'file leak')
    assert(largest <= 256, 'unbounded body read')
    return entries, warnings, copies
end
local entries = scan({[paths[1]] = archive({marked(a), marked(b)}), [paths[2]] = archive({marked(a)})})
assert(#entries == 2 and entries[1] == a and entries[2] == b, 'numeric priority or deduplication')
for _, override in ipairs({{name = a, body = 'return true'}, {name = a, body = marked(b).body}}) do
    entries = scan({[paths[1]] = archive({marked(a), marked(b)}), [paths[2]] = archive({override})})
    assert(#entries == 1 and entries[1] == b, 'overridden declaration revived')
end

-- Copies of one resource in several archives. The report names the copy the game
-- loads (highest patch) and the hidden ones for every name the loader starts, and
-- says when a compiled or undeclared copy hides a declared entry, which is then
-- not started. Nothing about which entries start changes.
do
    local ei, cv = 'mods/cowboybingus/enemy_intelligence', 'mods/cowboybingus/consistent_vaulting'
    local registry = {ei, cv}
    local function at(number) return '/game/data/9ba626afa44a3aa3.patch_' .. number end
    local function compiled(name) return {name = name, body = '\27LJ\2compiled'} end
    local function plain(name) return {name = name, body = 'return true'} end
    local warnings, copies
    -- Two archives declare the same entry.
    entries, warnings, copies = scan({[at(2)] = archive({marked(a)}), [at(10)] = archive({marked(a)})}, nil, registry)
    assert(#entries == 1 and entries[1] == a and #warnings == 0 and #copies.notes == 0)
    assert(copies.by_name[a] == '9ba626afa44a3aa3.patch_10 (declared) used; hidden: 9ba626afa44a3aa3.patch_2 (declared)',
        copies.by_name[a])
    -- A registry name in three packages (a standalone, a pack option and an older ZIP).
    entries, warnings, copies = scan({[at(3)] = archive({plain(ei)}), [at(7)] = archive({compiled(ei)}),
        [at(12)] = archive({marked(ei)})}, nil, registry)
    assert(#entries == 1 and entries[1] == ei and #copies.notes == 0)
    assert(copies.by_name[ei] == '9ba626afa44a3aa3.patch_12 (declared) used; hidden: 9ba626afa44a3aa3.patch_7 (compiled),'
        .. ' 9ba626afa44a3aa3.patch_3 (undeclared)', copies.by_name[ei])
    -- A registry name without any declaration is found by its hash.
    entries, warnings, copies = scan({[at(4)] = archive({plain(cv)}), [at(9)] = archive({compiled(cv)})}, nil, registry)
    assert(#entries == 0 and #copies.notes == 0)
    assert(copies.by_name[cv] == '9ba626afa44a3aa3.patch_9 (compiled) used; hidden: 9ba626afa44a3aa3.patch_4 (undeclared)',
        copies.by_name[cv])
    -- A registry module still starts behind a compiled copy, so there is no note.
    entries, warnings, copies = scan({[at(2)] = archive({marked(ei)}), [at(10)] = archive({compiled(ei)})}, nil, registry)
    assert(#entries == 0 and #copies.notes == 0)
    assert(copies.by_name[ei] == '9ba626afa44a3aa3.patch_10 (compiled) used; hidden: 9ba626afa44a3aa3.patch_2 (declared)',
        copies.by_name[ei])
    -- A compiled copy hides a declared entry: not started, and the report says so.
    entries, warnings, copies = scan({[at(2)] = archive({marked(a), marked(b)}), [at(10)] = archive({compiled(a)})},
        nil, registry)
    assert(#entries == 1 and entries[1] == b and next(copies.by_name) == nil)
    assert(#copies.notes == 1 and copies.notes[1] == 'not started: ' .. a .. ', declared in 9ba626afa44a3aa3.patch_2,'
        .. ' is hidden by 9ba626afa44a3aa3.patch_10 (compiled)', copies.notes[1])
    -- So do an undeclared copy and one declaring another name.
    for _, override in ipairs({plain(a), {name = a, body = marked(b).body}}) do
        entries, warnings, copies = scan({[at(2)] = archive({marked(a)}), [at(10)] = archive({override})}, nil, registry)
        assert(#entries == 0 and #copies.notes == 1 and copies.notes[1] == 'not started: ' .. a .. ', declared in'
            .. ' 9ba626afa44a3aa3.patch_2, is hidden by 9ba626afa44a3aa3.patch_10 (undeclared)', copies.notes[1])
    end
    -- Every hidden declaration is named, highest patch first.
    entries, warnings, copies = scan({[at(2)] = archive({marked(a)}), [at(5)] = archive({marked(a)}),
        [at(10)] = archive({compiled(a)})}, nil, registry)
    assert(copies.notes[1] == 'not started: ' .. a .. ', declared in 9ba626afa44a3aa3.patch_5, 9ba626afa44a3aa3.patch_2,'
        .. ' is hidden by 9ba626afa44a3aa3.patch_10 (compiled)', copies.notes[1])
    -- Long lists name discovery.SHOWN archives and count the rest: a pack that carries
    -- its own entry in every option repeats it once per enabled option.
    local many, labels = {}, {}
    for number = 1, d.SHOWN + 3 do many[at(number)] = archive({marked(a)}) end
    for number = d.SHOWN + 2, 3, -1 do labels[#labels + 1] = '9ba626afa44a3aa3.patch_' .. number .. ' (declared)' end
    entries, warnings, copies = scan(many, nil, registry)
    assert(#entries == 1 and copies.by_name[a] == '9ba626afa44a3aa3.patch_' .. (d.SHOWN + 3) .. ' (declared) used;'
        .. ' hidden: ' .. table.concat(labels, ', ') .. ' (+2 more)', copies.by_name[a])
    many, labels = {[at(50)] = archive({compiled(a)})}, {}
    for number = 1, d.SHOWN + 2 do many[at(number)] = archive({marked(a)}) end
    for number = d.SHOWN + 2, 3, -1 do labels[#labels + 1] = '9ba626afa44a3aa3.patch_' .. number end
    entries, warnings, copies = scan(many, nil, registry)
    assert(#entries == 0 and copies.notes[1] == 'not started: ' .. a .. ', declared in ' .. table.concat(labels, ', ')
        .. ' (+2 more), is hidden by 9ba626afa44a3aa3.patch_50 (compiled)', copies.notes[1])
    -- Without repeated resources nothing is reported and no registry name is hashed:
    -- the only hashes are the two declarations' own checks.
    local hashed = 0
    local function counting(name) hashed = hashed + 1; return hash(name) end
    entries, warnings, copies = scan({[at(2)] = archive({marked(a)}), [at(10)] = archive({marked(b)})}, nil, registry,
        counting)
    assert(#entries == 2 and next(copies.by_name) == nil and #copies.notes == 0 and hashed == 2, hashed)
    -- The report never stops discovery: its failure becomes one note.
    entries, warnings, copies = scan({[at(2)] = archive({marked(a)}), [at(10)] = archive({marked(a), marked(b)})}, nil,
        {42})
    assert(#entries == 2 and next(copies.by_name) == nil and #copies.notes == 1)
    assert(copies.notes[1]:find('^copies unavailable %('), copies.notes[1])
    -- io.open over in-memory archives; a read starting at failures[path] raises.
    local function opener(files, failures)
        return function(path)
            local bytes, position, fail = files[path], 0, failures and failures[path]
            return {seek = function(_, whence, offset)
                position = whence == 'end' and #bytes or offset; return position
            end, read = function(_, count)
                if position == fail then error('injected read failure') end
                local part = bytes:sub(position + 1, position + count); position = position + count; return part
            end, close = function() return true end}
        end
    end
    -- The first copy's own reads stop its archive's scan, as they always have, and a
    -- first copy whose body cannot be read still hides the older declaration.
    local first_body = 104 + 80 + 8 -- header and type table, one row, the envelope
    entries, warnings, copies = d.scan({at(10), at(2)}, hash, opener({[at(10)] = archive({compiled(a)}),
        [at(2)] = archive({marked(a), marked(b)})}, {[at(10)] = first_body}), registry)
    assert(#entries == 1 and entries[1] == b and #warnings == 1, 'an unreadable copy no longer hides the declaration')
    assert(copies.notes[1] == 'not started: ' .. a .. ', declared in 9ba626afa44a3aa3.patch_2, is hidden by'
        .. ' 9ba626afa44a3aa3.patch_10 (unreadable)', copies.notes[1])
    -- Reads made only for the report never change discovery: a hidden copy whose
    -- envelope or body cannot be read is listed as unreadable, and the rest of its
    -- archive is scanned exactly as without the report (same entries and order, no
    -- warning). patch_2 holds the hidden copy of a first, then two more entries.
    local c = 'mods/new_author/after_unreadable'
    local files = {[at(10)] = archive({marked(a)}), [at(2)] = archive({marked(a), marked(b), marked(c)})}
    local plain_entries, plain_warnings, plain_copies = d.scan({at(10), at(2)}, hash, opener(files), registry)
    assert(table.concat(plain_entries, ' ') == a .. ' ' .. b .. ' ' .. c and #plain_warnings == 0)
    assert(plain_copies.by_name[a] == '9ba626afa44a3aa3.patch_10 (declared) used; hidden: 9ba626afa44a3aa3.patch_2'
        .. ' (declared)', plain_copies.by_name[a])
    local hidden_at = 104 + 80 * 3 -- patch_2's first resource, after three rows
    for part, offset in pairs({envelope = hidden_at, body = hidden_at + 8}) do
        entries, warnings, copies = d.scan({at(10), at(2)}, hash, opener(files, {[at(2)] = offset}), registry)
        assert(table.concat(entries, ' ') == table.concat(plain_entries, ' ') and #warnings == 0,
            'a failed ' .. part .. ' read of a hidden copy changed discovery: ' .. table.concat(entries, ' ') .. '; '
            .. table.concat(warnings, '; '))
        assert(copies.by_name[a] == '9ba626afa44a3aa3.patch_10 (declared) used; hidden: 9ba626afa44a3aa3.patch_2'
            .. ' (unreadable)', copies.by_name[a])
    end
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

-- Kept out of the JIT: discovery's loops run hot at startup (a row per resource,
-- a byte per hashed name, an entry per listed archive); none may start a trace.
do
    local util, chunk = require('jit.util'), '@' .. source .. '/discover.lua'
    local started = {}
    local function watch(what, _, func)
        if what ~= 'start' then return end
        local info = util.funcinfo(func)
        if info.source == chunk then started[#started + 1] = info.linedefined end
    end
    jit.attach(watch, 'trace')
    local rows = {}
    for index = 1, 400 do
        rows[index] = index % 4 == 0 and marked('mods/jit_author/entry' .. index)
            or {name = 'assets/item' .. index, kind = string.rep('\7', 8), body = 'asset'}
    end
    for round = 1, 3 do
        assert(#scan({['/game/data/9ba626afa44a3aa3.patch_' .. round] = archive(rows)}) == 100)
    end
    local listed = 0
    local kernel = {GetLastError = function() return 18 end, FindClose = function() return 1 end}
    function kernel.FindFirstFileA(_, buffer)
        listed = 1
        ffi.copy(buffer + 44, '9ba626afa44a3aa3.patch_1')
        return ffi.cast('void *', 1)
    end
    function kernel.FindNextFileA(_, buffer)
        listed = listed + 1
        if listed > 300 then return 0 end
        ffi.copy(buffer + 44, '9ba626afa44a3aa3.patch_' .. listed)
        return 1
    end
    assert(#d.enumerate(ffi, kernel, '/game/data/9ba626afa44a3aa3') == 300)
    jit.attach(watch)
    assert(#started == 0, 'trace started in discovery at lines ' .. table.concat(started, ', '))
    -- Only discovery: a loop in this test (another chunk) still compiles.
    local function spin()
        local total = 0
        for index = 1, 300 do total = total + index end
        return total
    end
    local spun = 0
    local function count(what, _, func) if what == 'start' and func == spin then spun = spun + 1 end end
    jit.attach(count, 'trace')
    spin()
    jit.attach(count)
    assert(jit.status() == false or spun > 0, 'code outside discovery no longer compiles')
end
print('PASS: discovery hashes, declarations, bounds, numeric priority, shadowing, copies report (used and hidden'
    .. ' copies, hidden declarations), bounded reads, handle cleanup and kept out of the JIT (' .. jit.version .. ')')
