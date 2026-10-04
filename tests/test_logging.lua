local source=assert(arg[1])
local expected='C:/TestData/CowboyBingus/Helldivers2/Logs'
local function run(kind)
    local directories,opened,declared={},{},{}
    local kernel={}
    function kernel.bsl_CreateDirectoryA(path,security)
        assert(security==nil);directories[#directories+1]=path
        return 1
    end
    if kind=='existing' or kind=='denied' then
        kernel.bsl_CreateDirectoryA=function(path,security)
            assert(security==nil);directories[#directories+1]=path;return 0
        end
    end
    kernel.bsl_GetLastError=function()return kind=='denied' and 5 or 183 end
    local env=setmetatable({print=function()end,os={getenv=function(name)
        assert(name=='LOCALAPPDATA');return kind~='missing' and 'C:/TestData' or nil
    end},io={open=function(path,mode)
        assert(path:sub(1,#expected+1)==expected..'/' and mode=='w','Log escaped designated folder')
        opened[#opened+1]=path
        if kind=='file_denied'then return nil end
        if kind=='file_error'then error('Filesystem unavailable')end
        return {write=function()end,close=function()end}
    end},stingray={Application={can_get=function()return false end}},require=function(name)
        assert(name=='ffi')
        if kind=='ffi_error'then error('FFI unavailable')end
        return {cdef=function(text)declared[#declared+1]=text end,
            load=function(name)assert(name=='kernel32');return kernel end}
    end},{__index=_G});env._G=env
    setfenv(assert(loadfile(source..'/shared_loader.lua')),env)()
    local state=env.CowboyBingusModLoader;assert(state.version==17 and state.api==1 and state.revision=='loader-v19')
    -- The loader's own Windows functions are declared once, under private names
    -- only: a plain name would bind to whichever prototype another mod declared
    -- first. Then, as in v18, the plain log pair once for other mods, only with
    -- LOCALAPPDATA set.
    assert(#declared==((kind=='missing' or kind=='ffi_error') and 0 or 2),#declared)
    if declared[1] then
        for name in declared[1]:gsub('__asm__%b()',''):gmatch('([%w_]+)%s*%(')do
            assert(name:match('^bsl_'),'Plain Windows name declared: '..name)
        end
        assert(declared[1]:find('__asm__("CreateDirectoryA")',1,true))
        local plain={}
        for name in declared[2]:gsub('/%*.-%*/',''):gmatch('([%w_]+)%s*%(')do plain[#plain+1]=name end
        assert(table.concat(plain,',')=='CreateDirectoryA,GetLastError',table.concat(plain,','))
    end
    local modules=0;for _,status in pairs(state.modules)do assert(status=='not installed');modules=modules+1 end
    assert(modules==14,'Logging failure interrupted mod discovery')
    local before=#directories
    for _,name in ipairs({'../outside.log','subdir/file.log','C:/outside.log','bad.txt','bad\n.log'})do
        assert(not state.open_log(name),'Unsafe log filename accepted')
    end
    local file=state.open_log('ControllableHoverPack.log')
    assert(#directories==before,'Filesystem setup repeated per log')
    if kind=='denied' or kind=='missing' or kind=='ffi_error'then
        assert(not state.log_directory and not file and #opened==0)
    else
        -- One loader log write (startup finished; nothing was installed) and the mod log.
        assert(state.log_directory==expected and #directories==3 and #opened==2)
        assert((file~=nil)==(kind~='file_denied' and kind~='file_error'))
    end
end
for _,kind in ipairs({'normal','existing','denied','missing','ffi_error','file_denied','file_error'})do run(kind)end
print('PASS: shared log folder, existing directories, bounded filenames, one-time setup and nonfatal filesystem/FFI failures')
