-- The build gate: is this the game build the loader release supports? Runs once,
-- at startup, before anything optional (src/shared_loader.lua). On any other
-- build, or when the check cannot run, the loader starts no addon at all.
--
-- scripts/build.py embeds this file in the coordinator's lexical scope together
-- with byte-identical copies of Bingus Shared Runtime's bingus_runtime.lua and
-- bingus_memory.lua (src/) and the supported pairs from scripts/archive.py. The
-- module hashes land in the runtime's shared table (BingusRuntime.hashes), so
-- each mod's own verify_build afterwards reads them from there and no file.
--
-- gate.check(runtime, memory, builds) -> the record for CowboyBingusModLoader.build:
--   {supported = true, exe_sha256, game_sha256} on a listed build;
--   {supported = false, reason, exe_sha256, game_sha256} otherwise, with each hash
--   'unavailable' when it could not be read. Never raises.
-- runtime, memory: the tables the two runtime files return; builds: a list of
-- {exe_sha256, game_sha256}.
--
-- Cost: startup only, nothing per frame. On a supported build, the two module
-- hashes the first gated mod paid before (GetModuleFileNameW, CreateFileW,
-- ReadFile, BCrypt; unmeasured in game). On any other build, at most the same
-- two hashes and no mod.
local gate = {}

local pcall, tostring, type, ipairs = pcall, tostring, type, ipairs

local function text(value)
    local ok, result = pcall(tostring, value)
    return ok and type(result) == 'string' and result or 'an error value without text'
end

-- A module's hash for the log, from the shared table when verify_build read it.
local function hash(api, name)
    local ok, result = pcall(function()
        local module = api.module(name)
        if not module then return 'unavailable (module not loaded)' end
        return api.module_hash(module)
    end)
    if ok and type(result) == 'string' then return result end
    return 'unavailable (' .. text(result) .. ')'
end

local function refused(api, reason)
    return {supported = false, reason = reason, exe_sha256 = api and hash(api, nil) or 'unavailable',
            game_sha256 = api and hash(api, 'game.dll') or 'unavailable'}
end

function gate.check(runtime, memory, builds)
    if type(builds) ~= 'table' or #builds == 0 then return refused(nil, 'no supported build listed') end
    local made, api = pcall(memory.new, runtime)
    if not made then return refused(nil, 'build check failed: ' .. text(api)) end
    local reason
    for _, build in ipairs(builds) do
        local ok, supported, why = pcall(api.verify_build, build)
        if not ok then return refused(api, 'build check failed: ' .. text(supported)) end
        if supported == true then
            return {supported = true, exe_sha256 = build.exe_sha256, game_sha256 = build.game_sha256}
        end
        reason = text(why)
    end
    return refused(api, reason)
end

return gate
