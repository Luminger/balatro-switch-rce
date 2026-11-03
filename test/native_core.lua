return function(T,H)
    local check=T.check
    local ffi=require("ffi")
    H.files["version.jkr"]="1.0.1f-FULL\n1.0.1f"
    local resolve=require("bl.resolve")
    check("reads unshadowed title version",resolve.version()=="1.0.1f-FULL")
    local off=resolve.table_for("1.0.1f-FULL")
    check("exact binary profile and alias",off and
          resolve.table_for("0.9.2i-FULL")==off)
    check("unknown native build is refused",resolve.table_for("9.9.9")==nil)
    H.files["version.jkr"]="different Switch 2 compatibility metadata"
    local candidate=ffi.new("uint8_t[32]")
    local previous=package.loaded["jit.util"]
    package.loaded["jit.util"]={funcinfo=function()return {
        addr=tonumber(ffi.cast("uintptr_t",candidate))}end}
    local ok,result,reason=pcall(resolve.resolve,ffi)
    package.loaded["jit.util"]=previous
    check("unknown metadata still rejects foreign code before base reads",
          ok and result==nil and tostring(reason):find("unsupported present code image"))

    local jffi=require("bl.jffi")
    local ctrl=jffi.ctrl(ffi,0x200)
    check("VM control block is aligned and retained",ctrl.addr%16==0 and ctrl.buf~=nil)
    check("known-good coroutine tail thunk matches original image",
          jffi.L_SLOT==0x18 and jffi.VT_CALLEE==0x18
          and off.sdk.thunk_ptr==0x8b1ac)
    local f=setmetatable({},{__tostring=function()return "function: 0x1234abcd" end})
    check("C-function object address parsed",jffi.obj_addr(f)==0x1234abcd)

    -- REGRESSION: lua_State+0x18 is gclist, and propagatemark rewrites it for
    -- threads (th->gclist = grayagain). Restoring a snapshot taken before an
    -- allocating step truncated the gray chain and stranded gray objects,
    -- which later faulted in propagatemark. The collector must therefore be
    -- stopped before anything allocates, and must stay stopped across the
    -- whole borrow. This drives call_ptr with a fake victim and watches the
    -- GC mode transitions plus the borrow window itself.
    do
        local slot=ffi.new("uint64_t[4]")
        local slot_addr=tonumber(ffi.cast("uintptr_t",slot))
        local victim_obj=ffi.new("uint64_t[16]")
        local victim_addr=tonumber(ffi.cast("uintptr_t",victim_obj))
        local events,running={},true
        local real_collect=collectgarbage
        local fake_L=slot_addr-jffi.L_SLOT
        local saved_obj_addr=jffi.obj_addr
        local observed_during_borrow=nil
        slot[0]=0xcafef00dULL
        collectgarbage=function(what)
            if what=="stop" then running=false events[#events+1]="stop"
            elseif what=="restart" then running=true events[#events+1]="restart"
            else return real_collect(what) end
        end
        jffi.obj_addr=function(v)
            -- Mimics tostring()'s allocation: a GC step here must be
            -- impossible, i.e. the collector is already stopped.
            events[#events+1]=running and "ALLOC-WITH-GC-RUNNING" or "alloc"
            if type(v)=="thread" then return fake_L end
            return victim_addr
        end
        local probe=setmetatable({},{__call=function()
            observed_during_borrow=tonumber(slot[0])
            events[#events+1]=running and "BORROW-WITH-GC-RUNNING" or "borrow"
        end})
        local fake_ctrl={addr=0x4000}
        local out,why=jffi.call_ptr(ffi,probe,0x99,fake_ctrl)
        collectgarbage=real_collect
        jffi.obj_addr=saved_obj_addr
        check("gclist borrow completed through the thunk",out~=nil,why)
        check("collector is stopped before the first allocation",
              events[1]=="stop")
        local leaked=false
        for _,e in ipairs(events) do
            if e:find("GC%-RUNNING") then leaked=true end
        end
        check("no allocation or borrow runs with the collector live",not leaked,
              table.concat(events,","))
        check("borrow window published the control block",
              observed_during_borrow==0x4000)
        check("borrowed gclist is restored exactly",
              tonumber(slot[0])==0xcafef00d)
        check("collector is restarted exactly once",
              events[#events]=="restart")
    end

    -- The construct function reads the capture gadget's first instruction at
    -- sdk_base + off.fiber_capture to detect x21 vs x22. Allocate a buffer
    -- large enough to hold that offset and place the correct instruction.
    local fiber=require("bl.fiber_call")
    local sdk_buf=ffi.new("uint8_t[?]",off.sdk.fiber_capture+8)
    local sdk=tonumber(ffi.cast("uintptr_t",sdk_buf))
    -- Place the blr x22 instruction (0xd63f02c0) at the capture offset
    ffi.cast("uint32_t*",ffi.cast("uintptr_t",sdk+off.sdk.fiber_capture))[0]=0xd63f02c0
    local info={sdk_base=sdk,off=off.sdk}
    local stack=fiber.construct(ffi,info,0x12345678,{2,1,6,0,0})
    local function word(addr)
        return tonumber(ffi.cast("uint64_t*",ffi.cast("uintptr_t",addr))[0])
    end
    check("same-invocation fake fiber is aligned",stack.fake_sp%16==0
          and stack.fake_sp-stack.fake_frame==0xf0)
    check("target and GP arguments are in fake frame",word(stack.fake_frame+0x20)==0x12345678
          and word(stack.fake_sp)==2 and word(stack.fake_sp+8)==1
          and word(stack.fake_sp+16)==6)
    check("known-good thunk vtable slot points to launderer",
          word(stack.ctrl.addr+0x80+0x18)==sdk+off.sdk.launder)
    check("return chain switches BACK to saved live frame",
          word(stack.fake_sp+0x80)==stack.ctrl.addr+fiber.layout.FAKE
          and word(stack.fake_sp+0x88)==stack.ctrl.addr+fiber.layout.SAVED
          and word(stack.fake_sp+0xc8)==sdk+off.sdk.fiber_switch)
    local ptr=ffi.new("float[1]",{1.25})
    local pointer_frame=fiber.construct(ffi,info,0x12345678,{ptr})
    check("pointer to float uses GP register",word(pointer_frame.fake_sp)==
          tonumber(ffi.cast("uintptr_t",ptr)))
    check("scalar floating-point args are refused",not pcall(fiber.construct,ffi,info,
          0x12345678,{ffi.new("float",1.25)}))

    local seen
    local facade=require("bl.call").install(love,ffi,function()end,info,
        function(_,_,_,target,args)
            seen={target=target,args=args}
            return {raw=ffi.cast("uint64_t",16),int32=ffi.cast("int32_t",16)}
        end)
    local value=facade.invoke(0x12345678,2,1,6)
    check("love.ffi invokes native bridge without altering regular ffi",
          value and tonumber(value.int32)==16 and seen.target==0x12345678
          and seen.args[1]==2 and seen.args[3]==6
          and require("ffi")==ffi and facade.new("uint8_t[1]")~=nil)

    local types=require("bl.socket_types")
    local sa=types.sockaddr_in(9026)
    check("sockaddr layout and port",ffi.sizeof(sa)==16 and sa.family==2
          and sa.port_hi==35 and sa.port_lo==66)
    check("IPv4 conversion is byte-order correct",types.ipv4(0x0100a8c0)=="192.168.0.1")
end
