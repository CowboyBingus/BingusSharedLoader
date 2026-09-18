local base = assert(arg[1]):gsub('\\', '/')
local ffi, bit = require('ffi'), require('bit')
local name = 'mods/example_author/example_mod'
for _, logging in ipairs({true, false}) do
    local calls, scans, greetings = 0, 0, 0
    local builtin = setmetatable({}, {__index = ffi})
    builtin.load = function(library)
        assert(library == 'kernel32')
        local kernel = ffi.load(library)
        return setmetatable({GetModuleFileNameA = function(_, buffer)
            local path = base .. '/bin/helldivers2.exe'
            ffi.copy(buffer, path); return #path
        end, FindFirstFileA = function(pattern, buffer)
            assert(pattern == base .. '/data/9ba626afa44a3aa3.patch_*')
            scans = scans + 1
            return kernel.FindFirstFileA(pattern, buffer)
        end}, {__index = function(_, key) return kernel[key] end})
    end
    local env = setmetatable({print = function(message)
            if message == 'Hello from Example Mod!' then greetings = greetings + 1 end
        end,
        package = {loaded = {ffi = builtin, bit = bit}, preload = {}},
        os = {date = function(format) assert(format == '!%Y-%m-%dT%H:%M:%SZ'); return 'TEST-LAUNCH-UTC' end,
            getenv = function(key) assert(key == 'LOCALAPPDATA'); return logging and base or nil end},
        stingray = {Application = {build = function() return 'release' end,
            can_get = function(kind, resource) assert(kind == 'lua'); return resource == name end}}}, {__index = _G})
    env._G = env
    env.io = {open = function(path, mode)
        assert(path:sub(1, #base + 1) == base .. '/', 'File access escaped the isolated fixture')
        return io.open(path, mode)
    end}
    env.loadstring = function(bytes, label)
        local chunk, reason = loadstring(bytes, label)
        if chunk then setfenv(chunk, env) end
        return chunk, reason
    end
    env.require = function(resource)
        if resource == 'ffi' then return builtin end
        if resource == 'core/wwise/lua/wwise_visualization' or resource == 'core/wwise/lua/wwise_bank_reference' then return {} end
        assert(resource == name, 'Unexpected module required')
        assert(env.CowboyBingusModLoader.modules[name] == 'loading')
        calls = calls + 1
        return setfenv(assert(loadfile(base .. '/entry.lua')), env)(resource)
    end
    setfenv(assert(loadfile(base .. '/startup.ljbc')), env)()
    assert(scans == 1 and calls == 1 and greetings == 1)
    assert(env.CowboyBingusModLoader.modules[name] == 'loaded')
    assert(env.CowboyBingusModLoader.discovery == '1 declared entries')
    assert(not rawget(env, 'update') and not rawget(env, 'shutdown'), 'Example installed gameplay callbacks')
    if logging then
        local function read(filename)
            local file = assert(io.open(base .. '/CowboyBingus/Helldivers2/Logs/' .. filename, 'rb'))
            local text = file:read('*a'); file:close(); return text
        end
        assert(read('BingusSharedLoader.log'):find(name .. ': loaded', 1, true))
    end
end
print('PASS: minimal example discovered by packaged loader, one greeting, shared loader status, no gameplay callbacks and no dependency on logging')
