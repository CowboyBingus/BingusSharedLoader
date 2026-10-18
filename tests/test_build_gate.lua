-- The build gate (src/build_gate.lua, W0): on a game build this release does not
-- support, or when the check fails for any reason, the loader starts nothing (no
-- module required, no JIT cache limits or watcher, no archive enumeration, no
-- crash-dump scan, no after_startup callback) and says so in one log line with
-- both hashes; the stock Wwise callbacks still run. On the supported build it
-- starts everything as before, and the hashes it read stay in the shared runtime
-- table, so a mod's own verify_build afterwards reads no file.
-- Runs the built coordinator (and the bare source for the missing-gate cases) in
-- the workspace LuaJIT and in the game's own lua51.dll (tests/game_lua.py).
-- arg[1]: src; arg[2]: the build folder. Files go to <build>/build-gate-test-*.
-- An unknown build cannot be produced in the game; this test is its proof.
local source, build = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local fixture = dofile(arg[0]:gsub('[%w_]+%.lua$', '') .. 'build_fixture.lua')

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

ffi.cdef [[
    int bslg_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
    uint32_t bslg_GetLastError(void) __asm__("GetLastError");
]]
local kernel = ffi.load('kernel32')
local function mkdirs(path)
    local current = ''
    for part in path:gmatch('[^/]+') do
        current = current == '' and part or current .. '/' .. part
        if not current:match('^%a:$') and kernel.bslg_CreateDirectoryA(current, nil) == 0 then
            assert(kernel.bslg_GetLastError() == 183, 'cannot create ' .. current)
        end
    end
end
local function write(path, text)
    local file = assert(io.open(path, 'wb')); file:write(text); file:close()
end
local function read(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a'); file:close()
    return text
end

local temp = build:gsub('\\', '/') .. '/build-gate-test-' .. jit.version:gsub('[^%w]', '')
mkdirs(temp)
local M = {megapack = 'mods/cowboybingus/vanilla_plus_megapack', bounce = 'mods/cowboybingus/better_stratagem_bounce'}
local WWISE = {['core/wwise/lua/wwise_visualization'] = true, ['core/wwise/lua/wwise_bank_reference'] = true}
local NOT_SUPPORTED = 'Game build not supported by this loader; no mods started ('
local SHA_ABC = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
local SHA_EMPTY = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'

local function execute(path, env) return setfenv(assert(loadfile(path)), env)() end

local vanilla_callbacks
do
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.stingray = {Application = {build = function() return 'release' end}}
    env.require = function(name) assert(WWISE[name]); return {} end
    execute(build .. '/vanilla-callbacks.ljbc', env)
    vanilla_callbacks = env.WwiseFlowCallbacks
end

-- The loader's own Windows calls that only the optional steps make: discovery reads
-- the executable path and enumerates archives, the health report reads build stamps
-- and lists the dump folder.
local function counting_ffi(run)
    return setmetatable({load = function(name)
        local library = ffi.load(name)
        if run.bcrypt_fails and name == 'bcrypt' then error('bcrypt unavailable', 0) end
        if name ~= 'kernel32' then return library end
        local counted = {}
        for _, fn in ipairs({'bsl_FindFirstFileA', 'bsl_GetModuleFileNameA', 'bsl_GetModuleHandleA'}) do
            counted[fn] = function(...)
                run.native[fn] = (run.native[fn] or 0) + 1
                return library[fn](...)
            end
        end
        return setmetatable(counted, {__index = function(_, key) return library[key] end})
    end}, {__index = ffi})
end

-- One game start. options.build: 'known' (pinned hashes in the shared table),
-- 'unknown' (other hashes there), 'files' (the gate hashes options.exe_path and
-- options.game_path), 'no_game', 'no_name', 'no_ffi', 'bcrypt_fails';
-- options.coordinator 'bare' runs the source with options.gate as its gate.
local scenarios = 0
local function startup(options)
    scenarios = scenarios + 1
    local root = temp .. '/run' .. scenarios
    local localappdata, appdata = root .. '/local', root .. '/roaming'
    mkdirs(localappdata); mkdirs(appdata .. '/Arrowhead/Helldivers2/dumps')
    write(appdata .. '/Arrowhead/Helldivers2/dumps/old.dmp', 'not a dump')
    local run = {prints = {}, required = {}, jit = {}, native = {}, callbacks = 0,
                 logs = localappdata .. '/CowboyBingus/Helldivers2/Logs', bcrypt_fails = options.build == 'bcrypt_fails'}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.print = function(...)
        local parts = {}
        for index = 1, select('#', ...) do parts[index] = tostring((select(index, ...))) end
        run.prints[#run.prints + 1] = table.concat(parts, ' ')
    end
    env.os = setmetatable({getenv = function(name)
        if name == 'LOCALAPPDATA' then return localappdata end
        if name == 'APPDATA' then return appdata end
    end}, {__index = os})
    -- Every JIT call the coordinator makes is recorded and none reaches this process.
    local function record(text) run.jit[#run.jit + 1] = text end
    rawset(env, 'jit', {opt = {start = function(...) record('opt ' .. table.concat({...}, ' ')) end},
                        attach = function(_, event) record('attach ' .. tostring(event)) end,
                        flush = function() record('flush') end,
                        off = function() end, on = function() end, version = jit.version, status = jit.status})
    env.stingray = {Application = {build = function() return 'release' end,
        can_get = function(kind, name) return kind == 'lua' and (name == M.megapack or name == M.bounce) end}}
    env.loadstring = function(bytes, label)
        local chunk, reason = loadstring(bytes, label)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    env.require = function(name)
        if name == 'core/wwise/lua/wwise_flow_callbacks' then execute(build .. '/callbacks.ljbc', env); return true end
        if WWISE[name] then return {} end
        if name == 'jit.util' then return require(name) end  -- a builtin, for the churn guard
        run.required[#run.required + 1] = name
        assert(env.CowboyBingusModLoader.after_startup(function() run.callbacks = run.callbacks + 1 end))
        return true
    end
    local library = fixture.library(counting_ffi(run), {exe_path = options.exe_path, game_path = options.game_path,
        no_game = options.build == 'no_game', no_name = options.build == 'no_name'})
    if options.build == 'no_ffi' then
        rawset(env, 'package', {loaded = {bit = require('bit')}, preload = {}})
    else
        rawset(env, 'package', fixture.package_with(library))
    end
    local hashes = {}
    if options.build == 'known' or options.build == 'no_game' then
        hashes[fixture.key(fixture.EXE_PATH)] = fixture.EXE_SHA256
        hashes[fixture.key(fixture.GAME_PATH)] = fixture.GAME_SHA256
    elseif options.build == 'unknown' then
        hashes[fixture.key(fixture.EXE_PATH)] = SHA_ABC
        hashes[fixture.key(fixture.GAME_PATH)] = fixture.GAME_SHA256
    end
    rawset(env, 'BingusRuntime', {hashes = hashes})
    run.env, run.library = env, library
    local function update() end
    run.update = update
    if options.coordinator == 'bare' then
        env.build_gate = options.gate
        env.update = update
        execute(source .. '/shared_loader.lua', env)
    else
        execute(build .. '/vanilla-boot.ljbc', env)
        env.update = update
        env.init()
    end
    run.loader, run.bare = env.CowboyBingusModLoader, options.coordinator == 'bare'
    return run
end

local function log_lines(run)
    local text = read(run.logs .. '/BingusSharedLoader.log')
    if not text then return nil end
    local lines = {}
    for line in text:gmatch('([^\r\n]*)\r?\n') do lines[#lines + 1] = line end
    return lines
end

-- A mod that loads after the loader: its own vendored runtime copies, the same
-- module stand-ins, the same shared table.
local function later_mod_check(run)
    local env = run.env
    local mod_env = setmetatable({require = function(name)
        assert(name == 'ffi', 'mod require ' .. name)
        return run.library
    end}, {__index = env})
    mod_env._G = env
    local runtime = execute(source .. '/bingus_runtime.lua', mod_env)
    local memory = execute(source .. '/bingus_memory.lua', mod_env).new(runtime)
    return memory.verify_build({exe_sha256 = fixture.EXE_SHA256, game_sha256 = fixture.GAME_SHA256})
end

local function same_callbacks(env)
    local count = 0
    for name, callback in pairs(vanilla_callbacks) do
        if string.dump(callback, true) ~= string.dump(env.WwiseFlowCallbacks[name], true) then return false end
        count = count + 1
    end
    return count > 25
end

-- Nothing optional ran, and the one line says why, with both hashes.
local function check_refused(label, run, reason, exe, game, has_log)
    local loader, env = run.loader, run.env
    local line = NOT_SUPPORTED .. reason .. '; executable ' .. exe .. ', game.dll ' .. game .. ')'
    check(label .. ': build record', loader.build.supported == false and loader.build.reason == reason
        and loader.build.exe_sha256 == exe and loader.build.game_sha256 == game, loader.build.reason)
    check(label .. ': capability', loader.capabilities.build_gate == (run.bare_without_gate == nil))
    check(label .. ': no module required', #run.required == 0, run.required[1])
    check(label .. ': no module status', next(loader.modules) == nil)
    check(label .. ': no JIT limits or watcher', #run.jit == 0, run.jit[1])
    check(label .. ': no state.jit', loader.jit == nil)
    check(label .. ': no discovery', loader.discovery == nil)
    check(label .. ': no archive enumeration or dump scan', (run.native.bsl_FindFirstFileA or 0) == 0)
    check(label .. ': no executable path or build stamps',
        (run.native.bsl_GetModuleFileNameA or 0) + (run.native.bsl_GetModuleHandleA or 0) == 0)
    check(label .. ': update chain untouched', env.update == run.update)
    check(label .. ': printed once', #run.prints == 1 and run.prints[1] == '[BingusSharedLoader] ' .. line,
        run.prints[#run.prints])
    local lines = log_lines(run)
    if has_log then
        -- The bare source has no health report, so no Started line.
        local started = run.bare and 0 or 1
        check(label .. ': log', lines and #lines == 2 + started and lines[1] == 'Bingus Shared Loader loader-v20; API 1'
            and (started == 0 or lines[2]:find('^Started: ')) and lines[2 + started] == line,
            lines and table.concat(lines, ' | '))
    else
        check(label .. ': no log folder', lines == nil)
    end
    -- A registration after a refused startup is accepted but never runs.
    local ran = false
    check(label .. ': late registration accepted', loader.after_startup(function() ran = true end) == true)
    check(label .. ': no after_startup callback', not ran and run.callbacks == 0)
end

-- 1. The supported build, hashes in the shared table: everything starts as before.
do
    local run = startup({build = 'known'})
    local loader = run.loader
    check('known: build record', loader.build.supported == true and loader.build.exe_sha256 == fixture.EXE_SHA256
        and loader.build.game_sha256 == fixture.GAME_SHA256 and loader.build.reason == nil)
    check('known: capability', loader.capabilities.build_gate == true)
    check('known: modules', loader.modules[M.megapack] == 'loaded' and loader.modules[M.bounce] == 'loaded')
    check('known: JIT limits then watcher', run.jit[1] == 'opt maxmcode=65536 maxtrace=8000'
        and run.jit[2] == 'attach trace', table.concat(run.jit, ' | '))
    check('known: discovery and dump scan ran', loader.discovery ~= nil and (run.native.bsl_FindFirstFileA or 0) >= 1,
        run.native.bsl_FindFirstFileA)
    check('known: callbacks ran', run.callbacks == 2, run.callbacks .. ' ' .. table.concat(run.required, ','))
    check('known: no file read', run.env.BingusRuntime.hash_reads == 0)
    local text = read(run.logs .. '/BingusSharedLoader.log')
    check('known: log', text and not text:find('not supported', 1, true)
        and text:find('\nStartup finished: 2 loaded, 0 failed\r?\n'), text)
    check('known: stock callbacks', same_callbacks(run.env))
    check('known: no gate print', not table.concat(run.prints, '\n'):find('not supported', 1, true))
    local verified, why = later_mod_check(run)
    check('known: a later mod verifies', verified == true, why)
    check('known: a later mod reads no file', run.env.BingusRuntime.hash_reads == 0)
end

-- 2. Unknown builds: other hashes in the shared table, and two real files hashed.
do
    local run = startup({build = 'unknown'})
    check_refused('unknown', run, 'unsupported game build', SHA_ABC, fixture.GAME_SHA256, true)
    check('unknown: stock callbacks', same_callbacks(run.env))
end
do
    local files = temp .. '/files'
    mkdirs(files)
    write(files .. '/helldivers2.exe', 'abc'); write(files .. '/game.dll', '')
    local run = startup({build = 'files', exe_path = files .. '/helldivers2.exe', game_path = files .. '/game.dll'})
    check_refused('hashed', run, 'unsupported game build', SHA_ABC, SHA_EMPTY, true)
    check('hashed: stock callbacks', same_callbacks(run.env))
    check('hashed: one read per module', run.env.BingusRuntime.hash_reads == 2, run.env.BingusRuntime.hash_reads)
    local cached = run.env.BingusRuntime.hashes
    check('hashed: shared table', cached[fixture.key(files .. '/helldivers2.exe')] == SHA_ABC
        and cached[fixture.key(files .. '/game.dll')] == SHA_EMPTY)
    local verified, why = later_mod_check(run)
    check('hashed: a later mod refuses the build', verified == false and why == 'unsupported game build', why)
    check('hashed: a later mod reads no file', run.env.BingusRuntime.hash_reads == 2)
end

-- 3. The check fails: every way ends with no mod.
do
    local run = startup({build = 'no_game'})
    check_refused('no game.dll', run, 'game modules unavailable', fixture.EXE_SHA256,
        'unavailable (module not loaded)', true)
    run = startup({build = 'no_name'})
    check_refused('no module name', run, 'build check failed: module file name unavailable',
        'unavailable (module file name unavailable)', 'unavailable (module file name unavailable)', true)
    run = startup({build = 'bcrypt_fails'})
    check_refused('no bcrypt', run, 'build check failed: bcrypt unavailable', 'unavailable', 'unavailable', true)
    run = startup({build = 'no_ffi'})
    check_refused('no FFI', run, 'build check failed: ffi builtin unavailable', 'unavailable', 'unavailable', false)
    check('no FFI: stock callbacks', same_callbacks(run.env))
    run = startup({build = 'known', coordinator = 'bare', gate = {check = function() error('gate failure', 0) end}})
    check_refused('raising gate', run, 'build check failed: gate failure', 'unavailable', 'unavailable', true)
    run = startup({build = 'known', coordinator = 'bare', gate = {check = function() return 'supported' end}})
    check_refused('malformed gate', run, 'build check failed: supported', 'unavailable', 'unavailable', true)
    run = startup({build = 'known', coordinator = 'bare'})
    run.bare_without_gate = true
    check_refused('no gate', run, 'build check unavailable', 'unavailable', 'unavailable', true)
end

-- 4. The real game files, when the game is installed: the supported build, hashed
-- once, and a later mod reads them from the shared table.
local game_note = 'game files not installed'
do
    local base = (os.getenv('HD2_GAME_DIR') or ((os.getenv('PROGRAMFILES(X86)') or 'C:/Program Files (x86)')
        .. '/Steam/steamapps/common/Helldivers 2')):gsub('\\', '/')
    local exe_path, game_path = base .. '/bin/helldivers2.exe', base .. '/data/game/game.dll'
    local exe_file, game_file = io.open(exe_path, 'rb'), io.open(game_path, 'rb')
    if exe_file then exe_file:close() end
    if game_file then game_file:close() end
    if exe_file and game_file then
        local run = startup({build = 'files', exe_path = exe_path, game_path = game_path})
        if run.loader.build.supported then
            check('game files: modules', run.loader.modules[M.megapack] == 'loaded')
            check('game files: one read per module', run.env.BingusRuntime.hash_reads == 2)
            local verified, why = later_mod_check(run)
            check('game files: a later mod verifies without reading', verified == true
                and run.env.BingusRuntime.hash_reads == 2, why)
            game_note = 'installed game files supported, hashed once'
        else
            -- The installed game was updated past this release: the gate refused it.
            check_refused('game files', run, 'unsupported game build', run.loader.build.exe_sha256,
                run.loader.build.game_sha256, true)
            game_note = 'installed game is not the supported build: refused'
        end
    end
end

print('PASS: build gate (' .. passed .. ' checks; ' .. jit.version .. '): supported build starts everything and '
    .. 'leaves its hashes to later mods; unknown build and every failed check start nothing (no module, JIT limit, '
    .. 'watcher, discovery, dump scan or callback), keep the stock callbacks and log one line with both hashes; '
    .. game_note)
