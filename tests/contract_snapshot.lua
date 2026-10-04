-- The loader's contract with other mods, observed from outside. Runs one
-- scenario in a fresh process (C declarations are process-wide) and prints one
-- JSON object; tests/test_contract.py compares a build against the contract
-- recorded from the previous release.
-- arg[1] Wwise callbacks resource (.lua.main) to run, arg[2] build folder
-- (vanilla-boot.ljbc), arg[3] scenario, arg[4] an empty temporary folder.
local resource, build, scenario, temp = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
local ffi, bit = require('ffi'), require('bit')
temp = temp:gsub('\\', '/')

local NAMES = {
    megapack = 'mods/cowboybingus/vanilla_plus_megapack',
    bounce = 'mods/cowboybingus/better_stratagem_bounce',
    steering = 'mods/cowboybingus/hellpod_steering_unlocked',
    vaulting = 'mods/cowboybingus/consistent_vaulting',
}
-- Windows names that the loader may declare for every mod.
local PROBED = {'CreateDirectoryA', 'GetLastError', 'GetModuleFileNameA', 'FindFirstFileA', 'FindNextFileA',
                'FindClose', 'GetModuleHandleA', 'GetModuleFileNameW', 'VirtualQuery', 'ReadProcessMemory'}
local SCENARIOS = {
    none = {},
    mixed = {installed = {[NAMES.megapack] = 'module', [NAMES.bounce] = 'module', [NAMES.vaulting] = 'fail'}},
    other_loader = {installed = {[NAMES.bounce] = 'module', [NAMES.steering] = 'module'},
                    other = {[NAMES.bounce] = 'loaded', [NAMES.steering] = 'loading'}},
    uses_loader_declarations = {installed = {[NAMES.bounce] = 'uses_declarations'}},
    declares_after = {installed = {[NAMES.bounce] = 'declares_conflicting'}},
    no_ffi = {installed = {[NAMES.bounce] = 'module'}, no_ffi = true},
    no_lookup = {no_lookup = true},
    no_localappdata = {installed = {[NAMES.bounce] = 'module'}, no_localappdata = true},
    -- The first module loads before v18 declared its log pair, so its own prototype won.
    first_module_declares = {installed = {[NAMES.megapack] = 'declares_log_pair', [NAMES.bounce] = 'module'}},
    -- Discovery works, over archives test_contract.py deploys: the registry module and
    -- a declared addon have two copies each; mods/contract_author/hidden is declared
    -- only below a higher undeclared copy and must not start.
    discovery_copies = {installed = {[NAMES.bounce] = 'module', ['mods/contract_author/addon'] = 'module'},
                        discovery = true},
    -- Discovery works, but reads of two hidden copies in one archive fail (one
    -- envelope, one body). mods/contract_author/later, after them in that archive,
    -- must start; v18 never read hidden copies.
    discovery_unreadable_copies = {installed = {[NAMES.bounce] = 'module', ['mods/contract_author/addon'] = 'module',
                                                ['mods/contract_author/later'] = 'module'},
                                   discovery = true, unreadable = true},
}
local spec = assert(SCENARIOS[scenario], 'unknown scenario ' .. scenario)
local installed = spec.installed or {}

local escaped_temp = temp:gsub('%p', '%%%0')
local function normalize(text)
    if type(text) ~= 'string' then return text end
    text = text:gsub(escaped_temp, '<temp>')
    -- Source positions differ between builds; the messages must not.
    return (text:gsub('[^%s:]*:%d+: ', ''))
end

local prints, addon = {}, {}
local env = setmetatable({}, {__index = _G})
env._G = env
env.print = function(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring((select(index, ...))) end
    prints[#prints + 1] = normalize(table.concat(parts, ' '))
end
env.os = {getenv = function(name)
    if name == 'LOCALAPPDATA' and not spec.no_localappdata then return temp end
end, time = os.time, date = os.date, clock = os.clock}
env.jit = jit
env.stingray = {Application = {build = function() return 'release' end,
    can_get = function(kind, name)
        if spec.no_lookup then error('lookup failure') end
        return kind == 'lua' and installed[name] ~= nil
    end}}
if spec.other then env.HD2ModLoader = {modules = spec.other} end
if spec.no_ffi then env.package = {loaded = {bit = bit}, preload = {}} end
if spec.discovery then
    -- The game executable's path points into the temporary folder. v18 reads it
    -- through its plain declaration, v19 through its private bsl_ name; every other
    -- Windows function is the real one.
    local kernel32 = ffi.load('kernel32')
    local function game_path(_, buffer)
        local path = temp .. '/game/bin/helldivers2.exe'
        ffi.copy(buffer, path)
        return #path
    end
    local kernel = setmetatable({GetModuleFileNameA = game_path, bsl_GetModuleFileNameA = game_path},
        {__index = function(_, name) return kernel32[name] end})
    local library = setmetatable({load = function(name)
        assert(name == 'kernel32', 'unexpected library ' .. tostring(name))
        return kernel
    end}, {__index = ffi})
    env.package = {loaded = {ffi = library, bit = bit}, preload = {}}
end
if spec.unreadable then
    -- A read raises when it starts at a position test_contract.py listed in
    -- failures.txt ('<archive> <position>'); every other read is the real one.
    local failing = {}
    for line in io.lines(temp .. '/game/failures.txt') do failing[line] = true end
    env.io = setmetatable({open = function(path, mode)
        local file, reason = io.open(path, mode)
        if not file or mode ~= 'rb' then return file, reason end
        local archive = path:match('[^/\\]+$')
        return {seek = function(_, whence, offset)
            if offset == nil then return file:seek(whence) end
            return file:seek(whence, offset)
        end, read = function(_, count)
            if failing[archive .. ' ' .. file:seek('cur')] then error('injected read failure', 0) end
            return file:read(count)
        end, close = function() return file:close() end}
    end}, {__index = io})
end
env.loadstring = function(bytes, label)
    local chunk, reason = loadstring(bytes, label)
    if chunk then setfenv(chunk, env) end
    return chunk, reason
end
local function execute_file(path, label)
    local file = assert(io.open(path, 'rb'))
    local bytes = file:read('*a'); file:close()
    if label then bytes = bytes:sub(9) end  -- a .lua.main resource: 8-byte header
    return setfenv(assert(loadstring(bytes, label or '=vanilla')), env)()
end

local function probe_declarations()
    local found = {}
    for _, name in ipairs(PROBED) do
        local ok, symbol = pcall(function() return ffi.C[name] end)
        found[name] = ok and tostring(ffi.typeof(symbol)) or false
    end
    return found
end

env.require = function(name)
    if name == 'core/wwise/lua/wwise_flow_callbacks' then execute_file(resource, '=callbacks'); return true end
    if name == 'core/wwise/lua/wwise_visualization' or name == 'core/wwise/lua/wwise_bank_reference' then return {} end
    if name == 'ffi' then
        if spec.no_ffi then error('ffi unavailable') end
        return ffi
    end
    if name == 'bit' then return bit end
    local kind = assert(installed[name], 'unexpected require ' .. name)
    if kind == 'fail' then error('module failure') end
    if kind == 'uses_declarations' then
        -- A v18-era addon that calls Windows functions the loader declared, without declaring them.
        addon.declared_when_loading = probe_declarations()
        addon.get_last_error = (pcall(function() return ffi.C.GetLastError() end))
        addon.module_file_name = (pcall(function()
            local buffer = ffi.new('char[260]')
            return ffi.C.GetModuleFileNameA(nil, buffer, 260)
        end))
        addon.find_files = (pcall(function()
            local data = ffi.new('uint8_t[320]')
            local handle = ffi.C.FindFirstFileA(temp .. '/*', data)
            if handle ~= ffi.cast('void *', -1) then
                ffi.C.FindNextFileA(handle, data)
                ffi.C.FindClose(handle)
            end
        end))
        addon.create_directory = (pcall(function() return ffi.C.CreateDirectoryA(temp .. '/addon', nil) end))
    elseif kind == 'declares_log_pair' then
        addon.declared = (pcall(ffi.cdef, 'int CreateDirectoryA(const char *path, int security);'))
    elseif kind == 'declares_conflicting' then
        -- A v18-era addon that declares FindFirstFileA itself, with a typed buffer, after the loader.
        addon.declared = (pcall(ffi.cdef, [[
            struct contract_find { uint32_t attributes; };
            void *FindFirstFileA(const char *pattern, struct contract_find *data);
        ]]))
        local ok, symbol = pcall(function() return ffi.C.FindFirstFileA end)
        addon.find_first_file_type = ok and tostring(ffi.typeof(symbol)) or false
        -- Under v18 the loader's earlier `void *data` prototype wins, so an untyped
        -- buffer still converts; the addon's own typed prototype would refuse it.
        addon.untyped_buffer_accepted = (pcall(function()
            local data = ffi.new('uint8_t[320]')
            local handle = ffi.C.FindFirstFileA(temp .. '/*', data)
            if handle ~= ffi.cast('void *', -1) then ffi.C.FindClose(handle) end
        end))
    end
    local previous = env.update
    env.update = function(...) return previous(...) end
    rawset(env, 'Contract_' .. name:match('[^/]+$'), true)
    return true
end

-- The game's boot, then its init, which loads the Wwise callbacks resource.
execute_file(build .. '/vanilla-boot.ljbc')
local function original_update() end
env.update = original_update
local original_init, original_shutdown = env.init, env.shutdown
local before = {}
for key in pairs(env) do before[key] = true end
env.init()

local state = rawget(env, 'CowboyBingusModLoader')
local snapshot = {scenario = scenario, prints = prints, addon = addon, declarations = probe_declarations()}
snapshot.update_wrapped_by_loader = next(installed) == nil and env.update ~= original_update
snapshot.init_and_shutdown_kept = env.init == original_init and env.shutdown == original_shutdown
local added = {}
for key in pairs(env) do if not before[key] then added[#added + 1] = key end end
table.sort(added)
snapshot.globals_added = added
if type(state) == 'table' then
    local keys = {}
    for key, value in pairs(state) do keys[#keys + 1] = key .. ':' .. type(value) end
    table.sort(keys)
    local modules = {}
    for name, status in pairs(state.modules or {}) do modules[name] = normalize(status) end
    local jit_state
    if type(state.jit) == 'table' then
        jit_state = {}
        for key, value in pairs(state.jit) do
            if type(value) == 'number' or type(value) == 'boolean' then jit_state[key] = value
            else jit_state[key] = type(value) end
        end
    end
    local opened = state.open_log('ContractProbe.log')
    if opened then opened:close() end
    local rejected = true
    for _, bad in ipairs({'../outside.log', 'a/b.log', 'bad.txt'}) do rejected = rejected and not state.open_log(bad) end
    snapshot.state = {keys = keys, api = state.api, version = state.version, modules = modules, jit = jit_state,
        discovery = normalize(state.discovery), log_directory = normalize(state.log_directory),
        open_log_valid = opened ~= nil, open_log_rejects_paths = rejected}
end
-- Whose CreateDirectoryA prototype won: v18's takes nil for its security argument.
snapshot.create_directory_takes_nil = (pcall(function() return ffi.C.CreateDirectoryA(temp .. '/probe', nil) end))
local log = io.open(temp .. '/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log', 'rb')
if log then
    local text = log:read('*a'); log:close()
    local first = text:match('^[^\r\n]*')
    local statuses = {}
    for line in text:gmatch('[^\r\n]+') do
        local name, status = line:match('^%s*([%w_./-]+/[%w_./-]+): (.+)$')
        if name then statuses[name] = normalize(status) end
    end
    snapshot.log = {header = first:match('^Bingus Shared Loader loader%-v%d+; API 1$') ~= nil, statuses = statuses}
end

-- Minimal JSON with sorted keys.
local function encode(value)
    local kind = type(value)
    if kind == 'table' then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        if count == #value then
            local items = {}
            for index = 1, #value do items[index] = encode(value[index]) end
            return '[' .. table.concat(items, ',') .. ']'
        end
        local keys, items = {}, {}
        for key in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        for _, key in ipairs(keys) do items[#items + 1] = encode(key) .. ':' .. encode(value[key]) end
        return '{' .. table.concat(items, ',') .. '}'
    elseif kind == 'string' then
        return '"' .. value:gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"'
    elseif kind == 'number' or kind == 'boolean' then
        return tostring(value)
    end
    return 'null'
end
print(encode(snapshot))
