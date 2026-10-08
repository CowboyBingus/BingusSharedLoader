-- Optional Lua service: release an authored throwable spawned by a launcher.
-- Pack as mods/cowboybingus/throwable_launch and require it explicitly.
-- Uses code/research from HD2Runtime by SkyeShade:
-- https://github.com/SkyeShade/HD2Runtime (unit registry and entity descriptor layout).
-- No executable allocations, instruction patches, or firing-thread callbacks.
local M = { version = 1 }
local ffi = require('ffi')
local bit = require('bit')
local function unhex(s) return (s:gsub('..', function(h) return string.char(tonumber(h, 16)) end)) end
local function u32(s, o)
    if not s or o < 0 or o + 4 > #s then return nil end
    local a,b,c,d = s:byte(o+1,o+4)
    return a + b*256 + c*65536 + d*16777216
end
local function ptr(s, o)
    local lo,hi = u32(s,o),u32(s,o+4)
    if not hi or hi > 32767 then return nil end
    local n = lo + hi*4294967296
    return n >= 65536 and n or nil
end
local float = ffi.new('float[1]')
local function f32(s,o)
    if not s or o+4>#s then return nil end
    ffi.copy(float,s:sub(o+1,o+4),4)
    local n = tonumber(float[0])
    return n==n and math.abs(n)<=100000 and n or nil
end
local function hex64(s,o)
    local lo,hi=u32(s,o),u32(s,o+4)
    return hi and string.format('%08X%08X',hi,lo) or nil
end
local pins = {
    {0x615940,'4c8bdc55535657415541564157498daba8f5ffff4881ec200b0000410f2973b8'},
    {0x6c65f0,'48895c24105556574154415541564157488d6c24804881ec80010000440f29b4'},
    {0x8cdb40,'405355574883ec403b15d260bb02410fb6e88bda488bf90f8448010000448b49'},
    {0x8ce620,'405356574883ec203b15f255bb02418bf88bda488bf10f84aa010000448b4140'},
    {0x1787500,'40534883ec208bdae853ffffff84c00f84ac0000004c8b1dc4f7b9014533c03b'},
}

-- reader.read(address, size) returns bytes or nil. `native` is injectable for
-- offline tests; production uses direct calls to the existing game functions.
function M.new(reader, game, exe, native)
    assert(type(reader)=='table' and type(reader.read)=='function')
    local service = { released=0, refused=0, seen={}, frame=0 }
    local function read(at,n)
        if type(at)~='number' or at<65536 or n<1 or n>1048576 then return nil end
        local s=reader.read(at,n)
        return s and #s==n and s or nil
    end
    local function pointer(at) return ptr(read(at,8),0) end
    local function integer(at) return u32(read(at,4),0) end
    local function hash_index(at,id)
        local h=read(at,20)
        local slots,cap,empty,mult=ptr(h,0),u32(h,8),u32(h,12),u32(h,16)
        if not slots or not cap or cap<1 or cap>65536 or bit.band(cap,cap-1)~=0 then return nil end
        local rows=read(slots,cap*8)
        if not rows then return nil end
        -- Keep the multiplication exact for all u32 entity IDs.
        local low,high=mult%65536,math.floor(mult/65536)
        local start=(id*low+(id*high%65536)*65536)%4294967296
        for i=0,cap-1 do
            local atrow=(start+i)%cap*8
            local key=u32(rows,atrow)
            if key==id then
                local index=u32(rows,atrow+4)
                return index~=4294967295 and index or nil
            end
            if key==empty then return nil end
        end
    end
    local function descriptor(id)
        if not id or id==0 or id==4294967295 then return nil end
        local manager=pointer(game+0x346bf98)
        local index=manager and hash_index(manager+0xf1aeb0,id)
        if not index or index>=1048576 then return nil end
        local address=manager+0xf32f18+index*24
        local raw=read(address,24)
        if u32(raw,8)~=id then return nil end
        return raw,address
    end
    local function pose(unit)
        if not unit or unit==0 then return nil end
        local registry=pointer(exe+0x1a100f0)
        local index,generation=unit%4194304,math.floor(unit/4194304)%256
        local count=registry and integer(registry+152)
        local generations=registry and pointer(registry+160)
        local objects=registry and pointer(registry+136)
        if not count or not generations or not objects or index>=count then return nil end
        local current=read(generations+index,1)
        if not current or current:byte()~=generation then return nil end
        local object=pointer(objects+index*8)
        if not object or integer(object+8)~=unit then return nil end
        local vtable=pointer(object)
        if not vtable or pointer(vtable+0xe8)~=exe+0x2bd870 then return nil end
        local poses=pointer(object+0x88)
        local raw=poses and read(poses,64)
        if not raw then return nil end
        local position,direction={},{}
        for i=0,2 do
            position[i+1]=f32(raw,48+i*4)
            direction[i+1]=f32(raw,16+i*4)
            if not position[i+1] or not direction[i+1] then return nil end
        end
        local norm=direction[1]^2+direction[2]^2+direction[3]^2
        if math.abs(norm-1)>.02 then return nil end
        norm=math.sqrt(norm)
        for i=1,3 do direction[i]=direction[i]/norm end
        return position,direction
    end
    local function fire_data(source,source_raw)
        local manager=pointer(game+0x33266d8)
        local index=manager and hash_index(manager+0x50,source)
        if not index or index>=4096 then return nil end
        local override=hash_index(manager+0x90,source)
        local data
        if override and override<4096 then
            local rows=pointer(manager+0xd0)
            data=rows and rows+override*616
        else
            local root=pointer(game+0x346bf98)
            local table_at=root and pointer(root+0xf12e80)
            local buckets=table_at and read(table_at,542*16)
            if buckets then
                local key=source_raw:sub(1,8)
                for i=0,541 do
                    if buckets:sub(i*16+1,i*16+8)==key then
                        local row=u32(buckets,i*16+8)
                        if row<4096 then data=table_at+0x21e0+row*616 end
                        break
                    end
                end
            end
        end
        local raw=data and read(data,616)
        local records=pointer(manager+0x78)
        local runtime=records and read(records+index*0xa8,0xa8)
        return raw,runtime
    end
    if not native then
        local release=ffi.cast('void (*)(void *, uint32_t, const float *, const float *, uint32_t)',game+0x6c65f0)
        local start=ffi.cast('void (*)(void *, uint32_t, uint8_t)',game+0x8cdb40)
        local arm=ffi.cast('void (*)(void *, uint32_t, uint32_t)',game+0x8ce620)
        local query=ffi.cast('int (*)(uint32_t, uint32_t)',game+0x1787500)
        native={
            query=function(id,kind) return query(id,kind) end,
            release=function(manager,id,p,v,owner)
                release(ffi.cast('void *',manager),id,ffi.new('float[4]',p[1],p[2],p[3],0),
                    ffi.new('float[4]',v[1],v[2],v[3],0),owner)
            end,
            start=function(manager,id) start(ffi.cast('void *',manager),id,1) end,
            arm=function(manager,id,owner) arm(ffi.cast('void *',manager),id,owner) end,
        }
    end
    function service.prove()
        if service.proven then return true end
        for _,pin in ipairs(pins) do
            if read(game+pin[1],#pin[2]/2)~=unhex(pin[2]) then return false,'unsupported native throwable layout' end
        end
        if read(exe+0x2bd870,5)~=unhex('488d4160c3') then return false,'unsupported unit pose layout' end
        service.proven=true
        return true
    end
    function service.step(hosts,donors)
        if not service.proven then return false,'throwable service not proven' end
        service.frame=service.frame+1
        local manager=pointer(game+0x3326728)
        local h=manager and read(manager+0x38,20)
        local slots,cap,empty=ptr(h,0),u32(h,8),u32(h,12)
        if not slots or not cap or cap<1 or cap>65536 or bit.band(cap,cap-1)~=0 then return true end
        local identities,states=pointer(manager+0x50),pointer(manager+0x60)
        local rows=read(slots,cap*8)
        if not rows or not identities or not states then return true end
        local baseline=service.manager~=manager
        if baseline then service.manager=manager;service.seen={} end
        local present={}
        local players=pointer(game+0x3326468)
        local user=pointer(game+0x347cef0)
        local local_peer=user and read(user+0xb398,8)
        local solo=players and integer(players+132)==1
        local processed=0
        for i=0,cap-1 do
            local id,index=u32(rows,i*8),u32(rows,i*8+4)
            if id~=empty and id~=4294967295 and index<4096 then
                present[id]=true
                local age=service.seen[id]
                if baseline then service.seen[id]=true
                elseif age~=true and processed<32 then
                    service.seen[id]=(age or 0)+1
                    local identity_at=pointer(identities+index*8)
                    local identity=identity_at and read(identity_at,24)
                    local hash=hex64(identity,0)
                    if not donors[hash] or u32(identity,8)~=id then service.seen[id]=true
                    else
                        local state=read(states+index*64,64)
                        local source,owner=u32(state,40),u32(state,44)
                        local source_raw=descriptor(source)
                        local owner_raw=descriptor(owner)
                        local active=state and (state:byte(2)~=0 or state:byte(3)~=0)
                        if active then service.seen[id]=true
                        elseif solo and local_peer and state and state:sub(49,56)==local_peer
                            and source_raw and owner_raw and hosts[hex64(source_raw,0)]
                            and bit.band(u32(source_raw,20),1)==1 then
                            local data,runtime=fire_data(source,source_raw)
                            local selected=data and hex64(data,40)
                            local kind=data and u32(data,0)
                            if data and native.query(source,8)==1 then
                                local alternate=u32(data,0x240)
                                if alternate~=0 then kind=alternate end
                                if data:sub(0x248+1,0x248+8)~=string.rep('\0',8) then selected=hex64(data,0x248) end
                            end
                            local projectile=kind and kind<4096 and (kind==0 and game+0x37c7560 or pointer(game+0x37c7670+kind*8))
                            local speed=projectile and f32(read(projectile+32,4),0)
                            if data and native.query(source,7)==1 then
                                local alternate=f32(data,0x23c)
                                if alternate and alternate>0 then speed=alternate end
                            end
                            local multiplier=f32(runtime,0x50)
                            speed=speed and multiplier and speed*multiplier
                            local position,direction=pose(u32(identity,12))
                            local throwable=pointer(game+0x33264c0)
                            local member=throwable and hash_index(throwable+0x30,id)
                            if selected==hash and speed and speed>0 and speed<=100000 and position and member and member<4096 then
                                -- Re-read the identity and lifecycle before native calls; never
                                -- initialize a replaced object or an already thrown grenade.
                                local current=read(states+index*64,64)
                                if read(identity_at,24)==identity and current==state then
                                    local velocity={direction[1]*speed,direction[2]*speed,direction[3]*speed}
                                    service.seen[id]=true -- exactly once, including callback failure
                                    native.release(throwable,id,position,velocity,owner)
                                    native.start(manager,id)
                                    native.arm(manager,id,owner)
                                    service.released=service.released+1
                                    service.last={id=id,source=source,owner=owner,hash=hash,speed=speed}
                                    processed=processed+1
                                end
                            end
                        end
                        if service.seen[id]~=true and service.seen[id]>=8 then
                            service.seen[id]=true;service.refused=service.refused+1
                        end
                    end
                end
            end
        end
        for id in pairs(service.seen) do if not present[id] then service.seen[id]=nil end end
        return true
    end
    return service
end
local loader=rawget(_G,'CowboyBingusModLoader')
if loader then loader.throwables=M end
return M
