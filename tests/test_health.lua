-- Loader health report: the shared-state observer, the previous-session summary,
-- the game build stamp, the dump folder and minidump reader, and the whole report
-- written by the built coordinator. Runs in the workspace LuaJIT and in the
-- game's own lua51.dll (tests/game_lua.py). Files go to build/health-test-*.
local source, build = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local health = dofile(source .. '/health.lua')
local floor = math.floor

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

-- The test's own Windows functions, under private names like the loader's.
ffi.cdef [[
    int bslt_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
    uint32_t bslt_GetLastError(void) __asm__("GetLastError");
    uint32_t bslt_GetModuleFileNameA(void *module, char *filename, uint32_t size) __asm__("GetModuleFileNameA");
    void *bslt_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    void *bslt_FindFirstFileA(const char *pattern, void *data) __asm__("FindFirstFileA");
    int bslt_FindNextFileA(void *handle, void *data) __asm__("FindNextFileA");
    int bslt_FindClose(void *handle) __asm__("FindClose");
]]
local library, kernel = ffi.load('kernel32'), {}
for _, name in ipairs({'CreateDirectoryA', 'GetLastError', 'GetModuleFileNameA', 'GetModuleHandleA',
                       'FindFirstFileA', 'FindNextFileA', 'FindClose'}) do
    kernel[name] = library['bslt_' .. name]
end

local function mkdirs(path)
    local current = ''
    for part in path:gmatch('[^/]+') do
        current = current == '' and part or current .. '/' .. part
        if not current:match('^%a:$') and kernel.CreateDirectoryA(current, nil) == 0 then
            assert(kernel.GetLastError() == 183, 'cannot create ' .. current)
        end
    end
end
local function write(path, bytes)
    local file = assert(io.open(path, 'wb'))
    assert(file:write(bytes)); file:close()
end
local function read(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a'); file:close()
    return text
end
local function pause(seconds)
    local start = os.clock()
    while os.clock() - start < seconds do end
end

local temp = build:gsub('\\', '/') .. '/health-test-' .. jit.version:gsub('[^%w]', '')
mkdirs(temp)

-- On-disk PE timestamp of a file, to check the in-memory read against.
local function file_stamp(path)
    local bytes = assert(read(path))
    local header = bytes:byte(0x3D) + bytes:byte(0x3E) * 256
    local a, b, c, d = bytes:byte(header + 9, header + 12)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- Minidump bytes ---------------------------------------------------------------

local function le32(v) return string.char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216) % 256) end
local function le64(v) return le32(v % 4294967296) .. le32(floor(v / 4294967296)) end
local function utf16(text) return (text:gsub('.', function(c) return c .. '\0' end)) end
local function layout(pieces)
    local offsets = {}
    for offset in pairs(pieces) do offsets[#offsets + 1] = offset end
    table.sort(offsets)
    local out, position = {}, 0
    for _, offset in ipairs(offsets) do
        assert(offset >= position, 'overlapping minidump pieces')
        out[#out + 1] = string.rep('\0', offset - position)
        out[#out + 1] = pieces[offset]
        position = offset + #pieces[offset]
    end
    return table.concat(out)
end
-- spec: modules {path, base, size, stamp}, code, address, streams (header count override)
local function minidump(spec)
    local pieces, entries = {}, {}
    if spec.modules then
        local list = {le32(#spec.modules)}
        for index, module in ipairs(spec.modules) do
            local name_rva = 4096 + index * 512
            pieces[name_rva] = le32(#module.path * 2) .. utf16(module.path)
            list[#list + 1] = le64(module.base) .. le32(module.size) .. le32(0) .. le32(module.stamp)
                .. le32(name_rva) .. string.rep('\0', 108 - 24)
        end
        pieces[1024] = table.concat(list)
        entries[#entries + 1] = le32(4) .. le32(#pieces[1024]) .. le32(1024)
    end
    if spec.code then
        pieces[512] = le32(1234) .. le32(0) .. le32(spec.code) .. le32(0) .. le64(0) .. le64(spec.address)
            .. string.rep('\0', 168 - 32)
        entries[#entries + 1] = le32(6) .. le32(168) .. le32(512)
    end
    pieces[256] = string.rep('\0', 56)
    entries[#entries + 1] = le32(7) .. le32(56) .. le32(256)
    pieces[32] = table.concat(entries)
    pieces[0] = le32(0x504D444D) .. le32(0xA793) .. le32(spec.streams or #entries) .. le32(32) .. le32(0)
        .. le32(0) .. le64(0)
    return layout(pieces)
end
-- Dumps store full Windows paths; the report keeps only the file name.
local function windows_path(...) return table.concat({'D:', 'Games', 'HD2', 'bin', ...}, string.char(92)) end
local EXE = {path = windows_path('helldivers2.exe'), base = 0x7FF600000000, size = 0x5000000, stamp = 0x6AB382E4}
local GAME = {path = windows_path('game.dll'), base = 0x7FFA10000000, size = 0x4000000, stamp = 0x6AB3B43F}
local CRASH = {modules = {EXE, GAME}, code = 0xC0000005, address = GAME.base + 0x6C07A6}

-- 1. Observer -------------------------------------------------------------------

do
    local gc = {pause = 200, stepmul = 200, count = 1000.4}
    local function collect(option, value)
        if option == 'count' then return gc.count end
        if option == 'setpause' then local old = gc.pause; gc.pause = value; return old end
        if option == 'setstepmul' then local old = gc.stepmul; gc.stepmul = value; return old end
        error('unexpected collectgarbage option ' .. tostring(option))
    end
    local status = {true, 'SSE2', 'fold', 'cse'}
    local fake_jit = {status = function() return unpack(status) end}
    local clock, flushes, watching = 10, 0, true
    local G = {string = {format = string.format, len = string.len}, table = {}, update = function() end,
               shutdown = function() end, keep = 1, package = {loaded = {ffi = 'ffi module'}}}
    G._G = G
    local observer = health.observer(G, {collect = collect, jit = fake_jit, clock = function() return clock end,
        flushes = function() return flushes end, watching = function() return watching end})
    check('start summary', health.describe_start(observer.initial)
        == 'heap 1000 KB, GC pause 200, GC step multiplier 200, JIT on', health.describe_start(observer.initial))
    check('reading GC settings leaves them unchanged', gc.pause == 200 and gc.stepmul == 200)

    -- A module that changes a bit of everything.
    local mark = observer.mark()
    local previous = G.update
    G.update = function(...) return previous(...) end
    G.Foo, G.keep = {}, nil
    G.string.format = function() end
    G.string.split = function() end
    G.package.loaded.ffi = 'replacement'
    G.package.loaded['mods/example/new'] = true
    gc.pause, gc.count, clock, flushes, watching = 400, 1123.6, 10.012, 2, false
    table.remove(status, 3)
    local text = health.describe(observer.changes(mark))
    check('every kind of change is reported', text == 'heap +123 KB, 12 ms; GC pause 200 -> 400; JIT options -fold;'
        .. " JIT cache flushed 2x; replaced the loader's JIT trace watcher; added Foo, string.split;"
        .. ' replaced package.loaded.ffi, string.format, update; removed keep', text)
    check('measuring keeps the module\'s GC settings', gc.pause == 400 and gc.stepmul == 200)

    -- The baseline advanced: the next module is charged with nothing.
    mark = observer.mark()
    text = health.describe(observer.changes(mark))
    check('baselines advance', text == 'heap +0 KB, 0 ms', text)

    -- Replacing a library table reports the global only; a _G metatable and JIT off.
    mark = observer.mark()
    G.string = {format = string.format}
    setmetatable(G, {__index = function() error('strict globals') end, __newindex = function() error('strict') end})
    status[1] = false
    gc.stepmul, gc.count = 150, 900
    text = health.describe(observer.changes(mark))
    check('identity changes', text == 'heap -224 KB, 0 ms; GC step multiplier 200 -> 150; JIT turned off;'
        .. ' added _G metatable; replaced string', text)
    mark = observer.mark()
    getmetatable(G).__call = function() end
    text = health.describe(observer.changes(mark))
    check('metatable contents', text == 'heap +0 KB, 0 ms; added _G metatable.__call', text)
    setmetatable(G, nil)
    observer.changes(observer.mark())

    -- Many names: six listed, the rest counted; NaN and metamethods never misreport or run.
    mark = observer.mark()
    for index = 1, 100 do rawset(G, string.format('g%03d', index), index) end
    G.nan = 0 / 0
    local eq = {__eq = function() error('__eq must not run') end}
    G.weird = setmetatable({}, eq)
    ffi.cdef('struct bslt_cell { int value; };')
    local cell = ffi.metatype('struct bslt_cell', {__eq = function() error('cdata __eq must not run') end})
    G.cell = cell(1)
    text = health.describe(observer.changes(mark))
    check('long lists are bounded', text:match('^heap %+0 KB, 0 ms; added [%w_]+, [%w_]+, [%w_]+, [%w_]+, [%w_]+, [%w_]+'
        .. ' %(%+97 more%)$'), text)
    mark = observer.mark()
    G.weird, G.cell = setmetatable({}, eq), cell(1)
    text = health.describe(observer.changes(mark))
    check('NaN unchanged; replaced values with __eq compared by identity', text
        == 'heap +0 KB, 0 ms; replaced cell, weird', text)

    -- The real string metatable is a shared table too.
    mark = observer.mark()
    getmetatable('').__bslt_probe = true
    text = health.describe(observer.changes(mark))
    getmetatable('').__bslt_probe = nil
    check('string metatable additions', text == 'heap +0 KB, 0 ms; added string metatable.__bslt_probe', text)
    text = health.describe(observer.changes(observer.mark()))
    check('string metatable removals', text == 'heap +0 KB, 0 ms; removed string metatable.__bslt_probe', text)
end

-- 2. Previous session -----------------------------------------------------------

do
    local cases = {
        {nil, 'no log'},
        {'', 'no log'},
        {'Bingus Shared Loader loader-v18; API 1\nmods/cowboybingus/a: loaded\n', 'loader-v18 log without session details'},
        {'garbage', 'unknown loader log without session details'},
        {'Bingus Shared Loader loader-v19; API 1\r\nStarted: 2026-10-02 21:00:01\r\nmods/a/b: loaded\r\n'
            .. 'Startup finished: 1 loaded, 0 failed\r\n',
         'started 2026-10-02 21:00:01 (loader-v19); startup finished: 1 loaded, 0 failed'},
        {'Bingus Shared Loader loader-v19; API 1\nStarted: 2026-10-02 21:00:01\nmods/a/b: loading\nmods/c/d: loaded\n'
            .. 'mods/e/f: loading\n',
         'started 2026-10-02 21:00:01 (loader-v19); its log ended while loading mods/e/f'},
        {'Bingus Shared Loader loader-v19; API 1\nStarted: 2026-10-02 21:00:01\nmods/a/b: not installed\n',
         'started 2026-10-02 21:00:01 (loader-v19); its log ended during startup'},
        -- after_startup: the note written before the callbacks run, then the summary in its place.
        {'Bingus Shared Loader loader-v19; API 1\r\nStarted: 2026-10-02 21:00:01\r\nmods/a/b: loaded\r\n'
            .. 'Startup finished: 1 loaded, 0 failed\r\nAfter startup: running 2 callbacks\r\n',
         'started 2026-10-02 21:00:01 (loader-v19); startup finished: 1 loaded, 0 failed; its log ended while'
            .. ' after_startup callbacks ran'},
        {'Bingus Shared Loader loader-v19; API 1\nStarted: 2026-10-02 21:00:01\nmods/a/b: loaded\n'
            .. 'Startup finished: 1 loaded, 0 failed\nAfter startup: 2 callbacks run, 1 failed\n'
            .. 'After startup: callback of mods/a/b failed: running out of ideas\n',
         'started 2026-10-02 21:00:01 (loader-v19); startup finished: 1 loaded, 0 failed'},
    }
    for index, case in ipairs(cases) do
        local text = health.previous_session(case[1])
        check('previous session case ' .. index, text == case[2], text)
    end
end

-- 3. Game build stamp -------------------------------------------------------------

do
    local image = ffi.new('uint8_t[512]')
    ffi.cast('int32_t *', image + 0x3C)[0] = 0x80
    ffi.copy(image + 0x80, 'PE\0\0', 4)
    ffi.cast('uint32_t *', image + 0x88)[0] = 0x6AB3B43F
    local fake = {GetModuleHandleA = function(name) if name == 'game.dll' then return image end return nil end}
    check('PE stamp from the mapped header', health.image_stamp(ffi, fake, 'game.dll') == 0x6AB3B43F)
    check('missing module', health.image_stamp(ffi, fake, 'other.dll') == nil)
    check('stamp text', health.hex(0x6AB3B43F) == '6AB3B43F' and health.hex(nil) == 'unknown')
    ffi.copy(image + 0x80, 'XX\0\0', 4)
    check('not a PE image', not pcall(health.image_stamp, ffi, fake, 'game.dll'))
    ffi.cast('int32_t *', image + 0x3C)[0] = -5
    check('bad header offset', not pcall(health.image_stamp, ffi, fake, 'game.dll'))
    -- This process: the in-memory stamp equals the executable file's own.
    local path = ffi.new('char[32768]')
    local length = kernel.GetModuleFileNameA(nil, path, 32768)
    local stamp = health.image_stamp(ffi, kernel, nil)
    check('real executable stamp matches its file', stamp == file_stamp(ffi.string(path, length)), stamp)
end

-- 4. Dump folder ------------------------------------------------------------------

local function listing(entries, options)
    options = options or {}
    local state = {closed = 0, index = 0}
    local fake = {}
    local function fill(data, entry)
        ffi.fill(data, 320)
        ffi.cast('uint32_t *', data)[0] = entry.directory and 16 or 32
        ffi.cast('uint32_t *', data + 20)[0] = entry.low or 0
        ffi.cast('uint32_t *', data + 24)[0] = entry.high or 0
        ffi.copy(data + 44, entry.name)
    end
    function fake.FindFirstFileA(pattern, data)
        state.pattern = pattern
        if options.first_error then return ffi.cast('void *', -1) end
        state.index = 1; fill(data, entries[1]); return ffi.cast('void *', 99)
    end
    function fake.FindNextFileA(_, data)
        state.index = state.index + 1
        if entries[state.index] then fill(data, entries[state.index]); return 1 end
        return 0
    end
    function fake.GetLastError() return options.first_error or options.next_error or 18 end
    function fake.FindClose() state.closed = state.closed + 1; return 1 end
    return fake, state
end

do
    local fake, state = listing({
        {name = 'dump-2026-09-01-PC-1.dmp', high = 1, low = 5},
        {name = 'newest.dmp', high = 9, low = 0, directory = true},
        {name = 'dump-2026-09-30-PC-2.dmp', high = 2, low = 0},
        {name = 'DUMP-2026-09-29-PC-3.DMP', high = 1, low = 4294967295},
        {name = 'gpu_dump_2026-09-24.dred.txt', high = 1, low = 7},
        {name = 'notes.txt', high = 50, low = 0},
    })
    local found = health.dump_folder(ffi, fake, 'C:/dumps')
    check('lists every entry of the folder', state.pattern == 'C:/dumps/*')
    check('counts dump files only, any case', found.dumps == 3, found.dumps)
    check('newest dump by write time, folders skipped', found.dump.name == 'dump-2026-09-30-PC-2.dmp', found.dump.name)
    check('newest GPU report', found.gpu.name == 'gpu_dump_2026-09-24.dred.txt')
    check('listing closed once', state.closed == 1)
    for _, code in ipairs({2, 3, 18}) do
        local missing = listing({}, {first_error = code})
        check('missing folder (' .. code .. ')', health.dump_folder(ffi, missing, 'C:/none').dumps == 0)
    end
    check('unreadable folder', not pcall(health.dump_folder, ffi, listing({}, {first_error = 5}), 'C:/x'))
    local broken, broken_state = listing({{name = 'a.dmp'}}, {next_error = 5})
    check('interrupted listing raises and still closes',
        not pcall(health.dump_folder, ffi, broken, 'C:/x') and broken_state.closed == 1)
    check('FILETIME epoch', health.filetime(27111902, 116444736000000000 - 27111902 * 4294967296) == 0)
    check('FILETIME one second later', health.filetime(27111902, 116444736000000000 - 27111902 * 4294967296
        + 10000000) == 1)
end

-- 5. Minidump reader ----------------------------------------------------------------

local function dump_file(name, bytes)
    local path = temp .. '/' .. name
    write(path, bytes)
    return path
end
local function parse(bytes)
    local file = assert(io.open(dump_file('parse.dmp', bytes), 'rb'))
    local ok, result = pcall(health.read_dump, file)
    file:close()
    return ok, result
end

do
    local ok, result = parse(minidump(CRASH))
    check('dump parsed', ok, result)
    check('exception code', result.code == 0xC0000005)
    check('faulting module and offset', result.module == 'game.dll' and result.offset == 0x6C07A6, result.module)
    check('module and executable stamps', result.stamp == GAME.stamp and result.game_stamp == EXE.stamp)
    ok, result = parse(minidump({modules = {EXE, GAME}, code = 0xE24C4A04, address = 0x10}))
    check('address outside every module', ok and result.code == 0xE24C4A04 and result.module == nil
        and result.game_stamp == EXE.stamp)
    ok, result = parse(minidump({modules = {GAME, EXE}, code = 1, address = EXE.base}))
    check('executable stamp only when the executable is listed first', ok and result.module == 'helldivers2.exe'
        and result.game_stamp == nil)
    ok, result = parse(minidump({modules = {EXE}}))
    check('no exception record', ok and result.code == nil)
    local odd = {path = windows_path('gam\233.dll'), base = 0x1000, size = 0x1000, stamp = 1}
    ok, result = parse(minidump({modules = {odd}, code = 1, address = 0x1800}))
    check('non-ASCII module names are masked', ok and result.module == 'gam?.dll', result.module)
    local bytes = minidump(CRASH)
    for label, broken in pairs({
        ['truncated dump'] = bytes:sub(1, 1100),
        ['not a minidump'] = 'XXXX' .. bytes:sub(5),
        ['unexpected stream count'] = minidump({modules = {EXE}, streams = 1000}),
        ['unexpected module count'] = bytes:sub(1, 1024) .. le32(5000) .. bytes:sub(1029),
    }) do
        ok, result = parse(broken)
        check('rejects: ' .. label, not ok and tostring(result):find(label, 1, true), result)
    end
end

-- 6. Crash report lines, with the real Windows listing ------------------------------

do
    local folder = temp .. '/dumps'
    mkdirs(folder)
    mkdirs(folder .. '/folder.dmp')
    local secret = 'dump-2026-10-01-14.38.22-582da44f-DESKTOP-SECRET-26413.dmp'
    os.remove(folder .. '/' .. secret)
    write(folder .. '/dump-2026-09-01-older-DESKTOP-SECRET-1.dmp', minidump({modules = {EXE}}))
    write(folder .. '/gpu_dump_2026-09-24_17.04.38-21320.dred.txt', 'DRED')
    pause(0.05)
    write(folder .. '/' .. secret, minidump(CRASH))
    local seconds
    local lines = health.crashes(ffi, kernel, folder, io.open, function(value) seconds = seconds or value; return 'D' end)
    check('crash line', lines[1] == 'Newest crash dump: D, exception 0xC0000005 at game.dll+0x6C07A6'
        .. ' (module stamp 6AB3B43F), executable stamp 6AB382E4; 2 dumps in total', lines[1])
    check('GPU line', lines[2] == 'Newest GPU crash report: D' and #lines == 2, lines[2])
    check('dump time is the real write time', math.abs(seconds - os.time()) < 3600, seconds)
    for _, text in ipairs(lines) do check('no file or computer name', not text:find('SECRET', 1, true), text) end
    check('no dumps', health.crashes(ffi, kernel, temp .. '/missing-folder', io.open, tostring)[1]
        == 'Newest crash dump: none')
    lines = health.crashes(ffi, kernel, folder, function() return nil, folder .. ' DESKTOP-SECRET' end, tostring)
    check('unopenable dump', lines[1]:find(', unreadable (cannot open); 2 dumps in total', 1, true)
        and not lines[1]:find('SECRET', 1, true), lines[1])
    write(folder .. '/' .. secret, minidump(CRASH):sub(1, 600))
    lines = health.crashes(ffi, kernel, folder, io.open, tostring)
    check('truncated dump', lines[1]:find(', unreadable (truncated dump); 2 dumps in total', 1, true), lines[1])
end

-- 7. The whole report from the built coordinator --------------------------------------

local NAMES = {megapack = 'mods/cowboybingus/vanilla_plus_megapack', bounce = 'mods/cowboybingus/better_stratagem_bounce',
               steering = 'mods/cowboybingus/hellpod_steering_unlocked'}

-- Another mod declared clashing global prototypes first. The loader's private
-- names are unaffected; with plain names its log folder, discovery and dump
-- listing would all bind to these.
ffi.cdef [[
    typedef struct bslt_hostile { int x; } bslt_hostile;
    void *FindFirstFileA(const char *pattern, bslt_hostile *data);
    int CreateDirectoryA(const char *path, int security);
    uint32_t GetModuleFileNameA(int module, char *filename, uint32_t size);
]]

local function startup(root)
    local appdata, localappdata = root .. '/roaming', root .. '/local'
    local logs = localappdata .. '/CowboyBingus/Helldivers2/Logs'
    -- Like the game's globals: every library and builtin is a field of the table.
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env._G, env.print = env, function() end
    env.os = setmetatable({getenv = function(name)
        if name == 'LOCALAPPDATA' then return localappdata end
        if name == 'APPDATA' then return appdata end
    end}, {__index = os})
    env.stingray = {Application = {build = function() return 'release' end}}
    env.loadstring = function(bytes, label)
        local chunk, reason = loadstring(bytes, label)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    local function execute(path) return setfenv(assert(loadfile(path)), env)() end
    local seen, wrapper = {}, nil
    local function marker(name)
        local text = read(logs .. '/BingusSharedLoader.log') or ''
        seen[name] = text:match('\n' .. name:gsub('%p', '%%%0') .. ': loading\r?\n$') ~= nil
            and not text:find('Startup finished', 1, true)
    end
    env.stingray.Application.can_get = function(kind, name)
        return kind == 'lua' and (name == NAMES.megapack or name == NAMES.bounce or name == NAMES.steering)
    end
    env.require = function(name)
        if name == 'core/wwise/lua/wwise_flow_callbacks' then execute(build .. '/callbacks.ljbc'); return true end
        if name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference' then
            return {}
        end
        marker(name)
        if name == NAMES.megapack then
            local previous = env.update
            wrapper = function(...) return previous(...) end
            env.update, env.VanillaPlusMegapack = wrapper, {}
            return true
        elseif name == NAMES.bounce then
            -- A hostile module: raises the GC pause, replaces tostring, adds globals.
            collectgarbage('setpause', 400)
            env.tostring = function() return 'hostile' end
            env.HostileA, env.HostileB = 1, 2
            string.bslt_extra = function() end
            getmetatable('').__bslt = true
            return true
        end
        assert(name == NAMES.steering, 'unexpected require ' .. name)
        error('intentional load failure')
    end
    execute(build .. '/vanilla-boot.ljbc')
    local original_update, original_shutdown = function() end, env.shutdown
    env.update = original_update
    env.init()
    local text = assert(read(logs .. '/BingusSharedLoader.log'), 'no loader log')
    local lines = {}
    for line in text:gmatch('([^\r\n]*)\r?\n') do lines[#lines + 1] = line end
    return {env = env, lines = lines, seen = seen, wrapper = wrapper, shutdown = original_shutdown, logs = logs,
            appdata = appdata}
end

do
    local root = temp .. '/startup'
    local dumps = root .. '/roaming/Arrowhead/Helldivers2/dumps'
    mkdirs(dumps); mkdirs(root .. '/local/CowboyBingus/Helldivers2/Logs')
    write(dumps .. '/dump-2026-10-01-14.38.22-582da44f-DESKTOP-SECRET-26413.dmp', minidump(CRASH))
    -- The previous session's log ended while a module was loading.
    write(root .. '/local/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log',
        'Bingus Shared Loader loader-v19; API 1\r\nStarted: 2026-10-02 21:00:01\r\n' .. NAMES.megapack
        .. ': loaded\r\n' .. NAMES.bounce .. ': loading\r\n')
    local pause_before = collectgarbage('setpause', 200)
    collectgarbage('setpause', pause_before)

    local run = startup(root)
    local env, lines = run.env, run.lines
    local pause_after = collectgarbage('setpause', pause_before)
    string.bslt_extra, getmetatable('').__bslt = nil, nil
    check('the module keeps its GC pause; measuring never resets it', pause_after == 400, pause_after)
    check('loading marker written before each require', run.seen[NAMES.megapack] and run.seen[NAMES.bounce]
        and run.seen[NAMES.steering])
    check('no per-frame hook: update is the last module wrapper', env.update == run.wrapper)
    check('shutdown untouched', env.shutdown == run.shutdown)

    local path = ffi.new('char[32768]')
    local exe = health.hex(file_stamp(ffi.string(path, kernel.GetModuleFileNameA(nil, path, 32768))))
    local expected = {
        '^Bingus Shared Loader loader%-v19; API 1$',
        '^Started: %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$',
        '^Game build stamps: executable ' .. exe .. ', game%.dll unknown$',
        '^Lua at start: heap %d+ KB, GC pause ' .. pause_before .. ', GC step multiplier %d+, JIT on$',
        '^Previous session: started 2026%-10%-02 21:00:01 %(loader%-v19%); its log ended while loading '
            .. NAMES.bounce:gsub('%p', '%%%0') .. '$',
        '^Newest crash dump: %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d, exception 0xC0000005 at game%.dll%+0x6C07A6'
            .. ' %(module stamp 6AB3B43F%), executable stamp 6AB382E4; 1 dump in total$',
        '^Discovery: failed: ',
        '^LuaJIT cache: expanded 65536 KB / 8000 traces; flushes %d+, growth %d+; watcher on$',
        '^' .. NAMES.megapack:gsub('%p', '%%%0') .. ': loaded$',
        '^  changes: heap [+-]%d+ KB, %d+ ms; added VanillaPlusMegapack; replaced update$',
        '^' .. NAMES.bounce:gsub('%p', '%%%0') .. ': loaded$',
        '^  changes: heap [+-]%d+ KB, %d+ ms; GC pause ' .. pause_before .. ' %-> 400; added HostileA, HostileB,'
            .. ' string metatable%.__bslt, string%.bslt_extra; replaced tostring$',
        '^' .. NAMES.steering:gsub('%p', '%%%0') .. ': load failed: .*intentional load failure$',
        '^  changes: heap [+-]%d+ KB, %d+ ms$',
    }
    for index, pattern in ipairs(expected) do
        check('log line ' .. index, lines[index] and lines[index]:find(pattern), lines[index])
    end
    local others = 0
    for index = #expected + 1, #lines - 1 do
        check('other modules not installed', lines[index]:find(': not installed$'), lines[index])
        others = others + 1
    end
    check('every listed module reported', others == 11, others)
    check('last line', lines[#lines] == 'Startup finished: 2 loaded, 1 failed', lines[#lines])
    check('the dump file name never appears', not table.concat(lines, '\n'):find('SECRET', 1, true))

    -- The performance tools read "<module>: <status>" lines; nothing else matches.
    local parsed = {}
    for _, line in ipairs(lines) do
        local name, status = line:match('^%s*([%w_./-]+/[%w_./-]+): (.+)$')
        if name then parsed[name] = status end
    end
    local statuses = env.CowboyBingusModLoader.modules
    for name, status in pairs(statuses) do check('status line for ' .. name, parsed[name] == status, parsed[name]) end
    for name in pairs(parsed) do check('no stray status line ' .. name, statuses[name] ~= nil) end
    -- Plain names: only the ones loader v18 declared for other mods, with v18's prototypes.
    check('no plain names beyond v18', not pcall(function() return ffi.C.GetModuleHandleA end))
    check('v18 declarations kept for other mods', pcall(function() return ffi.C.FindNextFileA end)
        and pcall(function() return ffi.C.GetLastError() end))
    check('report data exposed', env.CowboyBingusModLoader.health.changes[NAMES.bounce]:find('replaced tostring', 1, true))

    -- The next start reads this session's finished log.
    run = startup(root)
    collectgarbage('setpause', pause_before)
    string.bslt_extra, getmetatable('').__bslt = nil, nil
    local started = lines[2]:match('^Started: (.+)$')
    check('previous session finished', run.lines[5] == 'Previous session: started ' .. started
        .. ' (loader-v19); startup finished: 2 loaded, 1 failed', run.lines[5])
end

-- 8. Kept out of the JIT ---------------------------------------------------------------

-- The report's loops and helpers run hot at startup (a module walk per scope, a
-- dump folder entry per file); none of them may start a trace.
do
    local util, report = require('jit.util'), '@' .. source .. '/health.lua'
    local started = {}
    local function watch(what, _, func)
        if what ~= 'start' then return end
        local info = util.funcinfo(func)
        if info.source == report then started[#started + 1] = info.linedefined end
    end
    jit.attach(watch, 'trace')
    local entries = {}
    for index = 1, 300 do
        local dump = index % 3 == 0
        entries[index] = {name = (dump and 'crash-' or 'note-') .. index .. (dump and '.dmp' or '.txt'), high = index,
            low = 0, directory = index % 7 == 0}
    end
    for _ = 1, 3 do health.dump_folder(ffi, listing(entries), 'C:/dumps') end
    local G = {}
    for key, value in pairs(_G) do G[key] = value end
    local observer = health.observer(G, {jit = jit})
    for round = 1, 30 do
        local mark = observer.mark()
        G['bslt_round_' .. round] = round
        observer.changes(mark)
    end
    jit.attach(watch)
    check('no trace starts in the report', #started == 0, 'lines ' .. table.concat(started, ', '))
    -- Only the report: a loop in this test (another chunk) still compiles.
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
    check('code outside the report still compiles', jit.status() == false or spun > 0, spun)
end

print('PASS: loader health report (' .. passed .. ' checks; ' .. jit.version .. '): shared-state changes per module,'
    .. ' previous session, build stamps, dump folder and minidump reader, whole log from the built coordinator,'
    .. ' kept out of the JIT')
