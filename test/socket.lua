return function(T,H)
    local check=T.check
    local ffi=require("ffi")
    local off=require("bl.offsets")["1.0.1f-FULL"].sdk
    -- ffi_call's construct reads capture bytes at sdk_base+off.fiber_capture;
    -- allocate a real buffer so the read doesn't segfault in tests.
    local sdk_buf=ffi.new("uint8_t[?]",off.fiber_capture+8)
    local sdk_addr=tonumber(ffi.cast("uintptr_t",sdk_buf))
    ffi.cast("uint32_t*",ffi.cast("uintptr_t",sdk_addr+off.fiber_capture))[0]=0xd63f02c0
    local info={sdk_base=sdk_addr,off=off}
    local calls,sent,received,sockaddr_ptrs,ipraw={},"",0,0,0x9783a8c0
    local function fake_sdk(_,_,_,target,args)
        local name
        for key,value in pairs(off) do
            if target==info.sdk_base+value then name=key;break end
        end
        calls[#calls+1]={name=name,args=args}
        if name=="bind" or name=="accept" then
            -- The real frame must receive a sockaddr POINTER, not a cdata
            -- struct by value (the first hardware startup blocker). The
            -- pointer now lands in the context's x1 slot, not on the pop
            -- stack, because ffi_call installs arguments via ctx_restore.
            local fc=require("bl.ffi_call")
            local frame=fc.construct(ffi,info,fc.gp_plan(#args),target,
                                     select(1,fc.marshal(ffi,fc.gp_plan(#args),
                                            unpack(args,1,#args))))
            local stored=tonumber(ffi.cast("uint64_t*",
                ffi.cast("uintptr_t",frame.ctx+fc.CTX.X(1)))[0])
            assert(stored==tonumber(ffi.cast("uintptr_t",args[2])),
                   "sockaddr must be passed by pointer in x1")
            sockaddr_ptrs=sockaddr_ptrs+1
        end
        local n=0
        if name=="nifm_ip" then ffi.cast("uint32_t*",args[1])[0]=ipraw
        elseif name=="socket" then n=3
        elseif name=="accept" then
            local peer=ffi.cast("bl_sockaddr*",args[2])
            peer[0].len,peer[0].family=16,2
            peer[0].addr=0x1483a8c0
            peer[0].port_hi,peer[0].port_lo=0x30,0x39
            ffi.cast("uint32_t*",args[3])[0]=16
            n=4
        elseif name=="poll" then
            local fds=ffi.cast("bl_pollfd*",args[1])
            fds[0].revents=fds[0].events;n=1
        elseif name=="recv" then
            received=received+1
            if received==1 then ffi.copy(args[2],"hi",2);n=2 end
        elseif name=="send" then
            n=math.min(2,args[3])
            sent=sent..ffi.string(args[2],n)
        end
        local raw=ffi.cast("uint64_t",n)
        return {raw=raw,int32=ffi.cast("int32_t",raw),
                int64=ffi.cast("int64_t",raw)}
    end
    local socket=require("bl.socket").new(ffi,function()end,info,fake_sdk)
    check("no SDK operation at module load",#calls==0)
    check("nifm and socket initialize with retained pool/IP",socket:initialize()==true
          and socket.pool~=nil and socket.ip=="192.168.131.151")
    local fd,why=socket:listener(9026)
    check("socket listener binds and enters nonblocking mode",fd==3,why)
    local io=socket:transport()
    local client,peer=io.accept(fd)
    check("accept returns descriptor and peer identity",client==4
          and peer=="192.168.131.20:12345",peer)
    check("nonblocking recv returns bytes and EOF",io.recv(client,8)=="hi"
          and io.recv(client,8)=="")
    check("nonblocking send preserves partial count",io.send(client,"abcd")==2
          and sent=="ab")
    check("client closes through SDK",io.close(client)==0)
    check("bind/accept use real GP pointer construction",sockaddr_ptrs==2)
    check("all operations passed through injected native dispatcher",#calls>=15
          and calls[#calls].name=="close")
    ipraw=0
    local ready,reason=socket:refresh_ip()
    check("wake loses IP without destroying initialized socket pool",ready==nil
          and tostring(reason):find("pending:") and socket.ip==nil
          and socket.pool~=nil)
    ipraw=0x1983a8c0 -- 192.168.131.25
    check("wake refreshes changed IP without pool recreation",
          socket:refresh_ip()==true and socket.ip=="192.168.131.25")

    local not_ready_calls=0
    local waiting=require("bl.socket").new(ffi,function()end,info,
        function(_,_,_,target,args)
            local name
            for key,value in pairs(off) do
                if target==info.sdk_base+value then name=key;break end
            end
            if name=="nifm_submit_now" then not_ready_calls=not_ready_calls+1 end
            local raw=ffi.cast("uint64_t",0)
            return {raw=raw,int32=ffi.cast("int32_t",raw),int64=ffi.cast("int64_t",raw)}
        end)
    local started,reason=waiting:initialize()
    check("network-not-ready is nonblocking",started==nil
          and tostring(reason):find("pending:") and not_ready_calls==1)
    waiting:initialize()
    check("nifm request submits once while waiting for IP",not_ready_calls==1)
end
