local base, source = assert(arg[1]):gsub('\\', '/'), assert(arg[2]):gsub('\\', '/')
local ffi, bit = require('ffi'), require('bit')
local resources = dofile(base .. '/resources.lua')
-- The archive holding the hidden copy of Example_2, and the positions of that
-- copy's envelope and body: the unreadable_* runs make a read starting there fail.
local failures = dofile(base .. '/failures.lua')
local legacy = 'mods/cowboybingus/vanilla_plus_megapack'
local bounce = 'mods/cowboybingus/better_stratagem_bounce'
local good = 'mods/new_author/group/Example_2'
local owned, pending = 'mods/new_author/owned', 'mods/new_author/in_progress'
local broken, unavailable = 'mods/new_author/broken', 'mods/new_author/unavailable'
-- Declared in the same archive as the hidden copy, in rows after it.
local neighbours = {'mods/new_author/after_a', 'mods/new_author/after_b'}

-- io whose reads of that archive raise when they start at position; every other
-- file, and every other read, is the real one.
local function failing_io(position)
    return setmetatable({open = function(path, mode)
        local file, reason = io.open(path, mode)
        if not file or mode ~= 'rb' or path:match('[^/\\]+$') ~= failures.archive then return file, reason end
        return {seek = function(_, whence, offset)
            if offset == nil then return file:seek(whence) end
            return file:seek(whence, offset)
        end, read = function(_, count)
            if file:seek('cur') == position then error('injected read failure', 0) end
            return file:read(count)
        end, close = function() return file:close() end}
    end}, {__index = io})
end

-- The loader log names the copy the game loads and the hidden ones under a
-- module's status, and lists the declared entries a compiled or undeclared copy
-- hides. None of these lines reads as a module status. kind: what the log says
-- about the hidden copy of Example_2.
local function check_copies_log(state, kind)
    local file = assert(io.open(base .. '/local/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log', 'rb'))
    local text = file:read('*a'); file:close()
    local lines = {}
    for line in text:gmatch('([^\r\n]*)\r?\n') do lines[#lines + 1] = line end
    local function after(first)
        for index, line in ipairs(lines) do
            if line == first then return lines[index + 1], lines[index + 2] end
        end
        error('missing log line: ' .. first)
    end
    local shadowed, hidden = after('Discovery: 9 declared entries')
    assert(shadowed == '  not started: mods/new_author/shadowed, declared in 9ba626afa44a3aa3.patch_7, is hidden by'
        .. ' 9ba626afa44a3aa3.patch_91 (undeclared)', shadowed)
    assert(hidden == '  not started: mods/new_author/hidden, declared in 9ba626afa44a3aa3.patch_6, is hidden by'
        .. ' 9ba626afa44a3aa3.patch_90 (compiled)', hidden)
    local line = after(legacy .. ': loaded')
    assert(line == '  copies: 9ba626afa44a3aa3.patch_92 (compiled) used; hidden: 9ba626afa44a3aa3.patch_0 (undeclared)',
        line)
    line = after(good .. ': loaded')
    assert(line == '  copies: 9ba626afa44a3aa3.patch_12 (declared) used; hidden: 9ba626afa44a3aa3.patch_5 ' .. kind,
        line)
    -- The performance tools read "<module>: <status>" lines; nothing else matches.
    local parsed = {}
    for _, entry in ipairs(lines) do
        local name, status = entry:match('^%s*([%w_./-]+/[%w_./-]+): (.+)$')
        if name then parsed[name] = status end
    end
    for name, status in pairs(state.modules) do assert(parsed[name] == status, 'status line for ' .. name) end
    for name in pairs(parsed) do assert(state.modules[name] ~= nil, 'stray status line ' .. name) end
end

-- after_startup: the registry module's callback, then the discovered addons' in
-- their start order (Example_2's raises), each once, after every module started.
-- The log ends with the summary and the failure, named after the addon.
local function check_after_startup(env, discovers)
    local calls = env.after_startup_calls
    assert(calls == (discovers and 'legacy;example:0;' or 'legacy;'), 'after_startup calls: ' .. tostring(calls))
    if not discovers then return end
    local file = assert(io.open(base .. '/local/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log', 'rb'))
    local text = file:read('*a'); file:close()
    assert(text:find('\nStartup finished: [^\r\n]*\r?\nAfter startup: 3 callbacks run, 1 failed\r?\nAfter startup: callback of '
        .. good:gsub('%p', '%%%0') .. ' failed: after startup failure\r?\n$'), text)
end

-- A failed read made only for the copies report changes nothing else: the same
-- modules start in the same order, with the same statuses and discovery result.
local function same_outcome(expected, actual, mode)
    assert(actual.order == expected.order, mode .. ' changed the start order: ' .. actual.order)
    assert(actual.discovery == expected.discovery, mode .. ' changed discovery: ' .. actual.discovery)
    for name, status in pairs(expected.modules) do assert(actual.modules[name] == status, mode .. ': ' .. name) end
    for name in pairs(actual.modules) do assert(expected.modules[name] ~= nil, mode .. ': ' .. name) end
end

local baseline
for _, mode in ipairs({'normal', 'unreadable_envelope', 'unreadable_body', 'noffi', 'enumeration_error', 'bad_path',
                       'stock_error'}) do
    local fail_at = failures[mode]
    local discovers = mode == 'normal' or fail_at ~= nil
    local calls, order, scans = {}, {}, 0
    local native_ffi = setmetatable({}, {__index = ffi})
    native_ffi.load = function(name)
        assert(name == 'kernel32')
        local kernel = ffi.load(name)
        -- The loader declares its Windows functions under private bsl_ names.
        return setmetatable({bsl_GetModuleFileNameA = function(module, buffer, capacity)
            assert(module == nil)
            local path = mode == 'bad_path' and 'relative/bin/helldivers2.exe' or base .. '/bin/helldivers2.exe'
            assert(capacity > #path); ffi.copy(buffer, path); return #path
        end, bsl_FindFirstFileA = function(pattern, buffer)
            scans = scans + 1
            if mode == 'enumeration_error' then error('enumeration unavailable') end
            return kernel.bsl_FindFirstFileA(pattern, buffer)
        end}, {__index = function(_, key) return kernel[key] end})
    end
    -- The discovering runs also write the loader log, to check what it says about copies.
    local localappdata = discovers and base .. '/local' or nil
    local env = setmetatable({print = function() end, os = {getenv = function(name)
            if name == 'LOCALAPPDATA' then return localappdata end
        end}, io = fail_at and failing_io(fail_at) or io,
        package = {loaded = mode == 'noffi' and {} or {ffi = native_ffi, bit = bit}, preload = {}},
        stock_error = mode == 'stock_error',
        HD2ModLoader = {modules = {[owned] = 'loaded', [pending] = 'loading'}},
        stingray = {Application = {can_get = function(kind, name)
            assert(kind == 'lua'); return resources[name] ~= nil and name ~= unavailable
        end}}}, {__index = _G})
    env._G = env
    env.loadstring = function(bytes, name)
        local chunk, reason = loadstring(bytes, name)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    env.require = function(name)
        assert(resources[name], 'Unknown module or builtin reached engine require: ' .. name)
        assert((env.stock_calls or 0) == 1, 'Addon ran before stock startup')
        assert(env.CowboyBingusModLoader.modules[name] == 'loading', 'Missing reentrant guard')
        calls[name] = (calls[name] or 0) + 1; order[#order + 1] = name
        -- Reentering the coordinator must not initialize this or subsequent mods twice.
        setfenv(assert(loadfile(source .. '/shared_loader.lua')), env)()
        return setfenv(assert(loadfile(resources[name])), env)(name)
    end
    local startup = setfenv(assert(loadfile(base .. '/startup.ljbc')), env)
    if mode == 'stock_error' then
        local ok, reason = pcall(startup, 'argument', nil, 'last')
        assert(not ok and tostring(reason):find('native startup failed', 1, true))
        assert(env.stock_calls == 1 and #order == 0 and scans == 0 and env.after_startup_calls == nil)
    else
        local function results(...)
            assert(select('#', ...) == 4)
            local a, b, c, d = ...; assert(a == 'first' and b == nil and c == 3 and d == nil)
        end
        results(startup('argument', nil, 'last'))
        assert(env.stock_calls == 1 and env.CowboyBingusModLoader.api == 1)
        check_after_startup(env, discovers)
        assert(order[1] == legacy and order[2] == bounce, 'Legacy order changed')
        assert(calls[legacy] == 1 and calls[bounce] == 1)
        if discovers then
            assert(scans == 1 and calls[good] == 1 and calls['mods/patpatpatrick/example_addon'] == 1)
            assert(calls[neighbours[1]] == 1 and calls[neighbours[2]] == 1, 'entries after the hidden copy lost')
            assert(calls[broken] == 1 and not calls[owned] and not calls[pending] and not calls[unavailable])
            local state = env.CowboyBingusModLoader
            assert(state.modules[broken]:find('intentional addon failure', 1, true))
            assert(state.modules[owned] == 'loaded' and state.modules[pending] == 'loading')
            assert(state.modules[unavailable] == 'not installed' and #order == 7)
            assert(state.discovery == '9 declared entries', state.discovery)
            -- Declared entries hidden by a compiled or undeclared copy never start.
            assert(state.modules['mods/new_author/hidden'] == nil and state.modules['mods/new_author/shadowed'] == nil)
            check_copies_log(state, fail_at and '(unreadable)' or '(declared)')
            local outcome = {order = table.concat(order, ' '), discovery = state.discovery, modules = state.modules}
            if mode == 'normal' then baseline = outcome else same_outcome(baseline, outcome, mode) end
            -- A module initialized by an earlier addon must also be respected.
        else
            assert(#order == 2 and env.CowboyBingusModLoader.discovery:find('failed:', 1, true))
        end
        setfenv(assert(loadfile(source .. '/shared_loader.lua')), env)()
        assert(calls[legacy] == 1 and calls[bounce] == 1)
    end
end
print('PASS: compiled bootstrap, real Windows enumeration, independent addon packages, legacy order, API 1, failure/reentry isolation, dispatcher coexistence, stock arguments/results, used, hidden and not started copies in the log, unreadable hidden copies change nothing else, and after_startup callbacks from registry and discovered entries (' .. jit.version .. ')')
