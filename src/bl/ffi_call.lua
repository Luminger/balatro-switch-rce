-- Full-ABI native calls: the lj_vm_ffi_call this title does not have.
--
-- WHY THIS EXISTS
--
-- Balatro's LuaJIT 2.1.0-beta3 build has a COMPLETE ffi call path except its
-- final dispatch. In the exact 1.0.1f main NSO (sha ea4822c0693642be...):
--
--   lj_cf_ffi_meta___call = main+0x460f0, with lj_ccall_func and
--   ccall_set_args inlined. It marshals every argument class correctly into
--   a CCallState at sp+0x60 (func+0x00, spadj+0x08, nsp+0x0c, retref+0x0d,
--   fpr[]+0x18, gpr[]+0x98), sets cts->cb.slot = ~0u at +0x46984, and then:
--
--       +0x46994   bl 0x7100056ef8        <- lj_vm_ffi_call
--
--   main+0x56ef8 contains 00000000 00000000: eight bytes of alignment
--   padding between a `ret` at +0x56ef4 and the next function at +0x56f00.
--   The symbol was linked bodiless onto padding. It has exactly ONE xref,
--   that bl. So a cdata function-pointer call executes UDF #0 and kills the
--   process - it does not raise a Lua error. ffi.load and ffi callbacks are
--   likewise hard stubs ("no support for loading dynamic libraries for this
--   OS" / "no support for callbacks on this OS"), and .text is R-X with no
--   CreateCodeMemory/ControlCodeMemory/SetProcessMemoryPermission in the
--   NPDM, so neither patching that bl nor loading our own code is possible.
--
-- WHAT THIS MODULE DOES INSTEAD
--
-- It reimplements the missing dispatch out of instructions the SDK already
-- contains, and exposes it as ordinary Lua functions (see declare() at the
-- bottom). An earlier design returned callable cdata via ffi.metatype; that
-- is NOT usable on this build, because any Lua metamethod registered through
-- ffi.metatype kills the process here. Hardware-measured, see declare().
--
-- THE CHAIN (all gadget bytes are preflighted before any transfer)
--
--   launder(ctrl) -> fiber_switch: saves the CURRENT live launder frame to
--     ctrl+SAVED, pivots to the heap fake frame F, ret to pop_gp with SP=P
--   pop_gp@P:     x0 = &ctx, ret to ctx_restore
--   ctx_restore:  x0..x7 and d0..d7 = the marshalled arguments, x8/x19/x21/x22
--                 = capture-gadget inputs, SP = S0, LR = the capture gadget;
--                 ret enters it. THIS is the argument half of vm_ffi_call:
--                 one gadget sets every AAPCS64 argument register and SP.
--   capture:      calls the target, stores the raw return (x0 or d0) into
--                 ctrl+RESULT, pops [S0..S0+0x30], SP=Q, ret to pop_gp
--   pop_gp@Q:     x0/x1 = the two fiber slots, ret to fiber_switch
--   fiber_switch: restores the live SAME-INVOCATION launder frame; launder
--                 zeroes BC_FUNCC's result count and returns.
--
-- Two capture variants, selected by the declared return class, both frame
-- 0x30 so they share one pop-window layout:
--   integer/pointer/void: fiber_capture  `blr x22|x21; str x0,[x19,#0x10]`
--   float/double:         fp_capture     `ldr x8,[x8,#0x30]; blr x8;
--                                         mov w0,wzr; str d0,[x19]`
--
-- SUPPORTED / NOT SUPPORTED
--
--   yes: up to 8 integer/pointer arguments (x0..x7)
--        up to 8 float/double arguments (d0..d7)
--        return void, integer (any width), pointer, float, double
--   no:  stack-passed arguments. Both capture gadgets pop their saved
--        registers from [SP..SP+0x2f], which is exactly where AAPCS64 puts
--        the first stack arguments, so the two uses collide. A census of
--        every straight-line call-and-capture gadget in this SDK and in main
--        found no variant whose pop window starts above [SP+0x10], so this
--        is a property of the image, not an omission. Nothing in the SDK
--        surface this launcher drives (nn::socket, nn::nifm) exceeds 8+8.
--   no:  struct/union by value, hidden-x8 struct returns, varargs,
--        long double, SIMD/HFA aggregates. All are rejected at declare time.
--
-- THE CONTEXT TEMPLATE IS ZERO, and that is measured, not assumed.
--
-- This module used to call the SDK's context SAVE gadget once per process
-- through the <=8-GP bridge, on the theory that the callee needs the live
-- x18 ("platform register") and a plausible x29. That theory was wrong for
-- this SDK: a census of its code shows x18 is allocated by the compiler as
-- an ordinary scratch register (`sxtw x18,w8`, `ror x18,x18,#0xe` inside
-- crypto routines, 2854 real register references), so no callee can expect
-- an incoming value -- Horizon reaches TLS through tpidrro_el0, not x18.
-- Confirmed on console by zeroing the whole template and asking the callee
-- itself: ctx_save reported x18 == 0, and strlen, pow, strdup (which
-- allocates) and snprintf all returned correct results anyway.
--
-- Every other register the template could supply is either callee-saved
-- (the target preserves it) or scratch, and the launder frame is restored
-- from the live stack by the second fiber switch regardless. So the ctx is
-- zero-filled and only the argument and control fields are written.
--
-- There is therefore no register snapshot at all: the context is zero-filled
-- and only the argument and control fields are written.

local jffi = require("bl.jffi")

local M = {}

-- SDK context block, as the save/restore pair itself lays it out.
M.CTX = { X = function(n) return 8 * n end, SP = 0xf8, LR = 0x100,
          D = function(n) return 0x110 + 8 * n end, SIZE = 0x210 }

-- Control-block and fake-frame geometry. These were the GP bridge's layout
-- constants; that module is gone and this is now the only native-call
-- implementation, so they live here.
M.layout = {
    RESULT = 0x10,                          -- capture gadgets store here
    SAVED  = 0x120,                         -- first fiber switch writes the live SP
    FAKE   = 0x128,                         -- fake fiber context slot
    FAKE_FRAME_SIZE = 0xf0,                 -- DispatchFiberContext's frame
    FP_SLOT = 0x180,                        -- x8 for fp_capture; target at +0x30
    STACK_SIZE = 0x20100,
    CAPTURE_FRAME = 0x30,                   -- both capture gadgets
}

-- TWO DEFECTS OF THIS EXACT LUAJIT BUILD, both measured on console and both
-- fatal to the obvious spellings, so everything below avoids them:
--
--   1. 64-BIT LITERALS DO NOT WORK. `0ULL` evaluates to a plain Lua *number*
--      whose value is the ordinal of that literal in the chunk (the first
--      `<n>ULL` in a chunk yields 0, the second 1, ...), with type "number".
--      Verified: `return tostring(7ULL)` -> "1"; two literals -> "0,1".
--      So no ULL/LL literal may appear anywhere in launcher code; build
--      64-bit constants with ffi.cast and arithmetic instead.
--   2. 64-BIT CDATA EQUALITY IS BROKEN. `ffi.cast("uint64_t",5) ==
--      ffi.cast("uint64_t",5)` is FALSE, while `<`, arithmetic and tonumber
--      all behave. Reference equality (`a == a`) still holds, so a stale
--      comparison silently reads as "different". Compare 64-bit values
--      through u64_eq/u64_is_zero below, or via tonumber when the value is
--      an address below 2^53.
--
-- (A ULL literal used as a never-compared sentinel is harmless, which is how
-- one survived in this tree for a while. There are none left.)

local U32 = 4294967296

local function u64_hi(ffi, v)
    return tonumber(ffi.cast("uint32_t", ffi.cast("uint64_t", v) / U32))
end

local function u64_lo(ffi, v)
    return tonumber(ffi.cast("uint32_t", ffi.cast("uint64_t", v)))
end

local function u64_eq(ffi, a, b)
    return u64_hi(ffi, a) == u64_hi(ffi, b) and u64_lo(ffi, a) == u64_lo(ffi, b)
end

local function u64_is_zero(ffi, v)
    return u64_hi(ffi, v) == 0 and u64_lo(ffi, v) == 0
end

M.u64_eq, M.u64_is_zero = u64_eq, u64_is_zero

-- Pre-seeded into the result slot so a chain that never reached the target is
-- distinguishable from one that did. Both capture gadgets store
-- unconditionally, so only a missed call leaves this intact. It must be a
-- value a real callee is vanishingly unlikely to return, which 0xdeadbeef is
-- not: that is a plausible 32-bit integer result. Built arithmetically
-- because of defect 1 above.
M.SENTINEL_HI, M.SENTINEL_LO = 0xbadc0ffe, 0xe0ddf00d

local function sentinel(ffi)
    return ffi.cast("uint64_t", M.SENTINEL_HI) * U32 + M.SENTINEL_LO
end
M.sentinel = sentinel

-- Complete consumed instruction ranges. Byte-identical in 1.0.1f and 1.0.1o.
M.SIGNATURE = {
    -- +0x56ee64 (1.0.1f) / +0x5e17a4 (1.0.1o): ldp x2..x15, x18..x29, x30 from
    -- ctx+0x100, d0..d31 from ctx+0x110, x16=ctx+0xf8, x0/x1=ctx+0, mov sp,x16, ret
    ctx_restore = "020c41a9041442a9061c43a9082444a90a2c45a90c3446a90e3c47a9124c49a914544aa9165c4ba918644ca91a6c4da91c744ea91e8040f90004516d020c526d0414536d061c546d0824556d0a2c566d0c34576d0e3c586d1044596d124c5a6d14545b6d165c5c6d18645d6d1a6c5e6d1c745f6d1e0041fd1f0441fd107c40f9000440a91f020091c0035fd6",
    -- +0x56eef0 (1.0.1f) / +0x5e1830 (1.0.1o): the save counterpart. First 0x50
    -- bytes: stp x0..x29 pairs, str x30 at +0xf0, mov x1,sp; str x1,[x0,#0xf8];
    -- str x30,[x0,#0x100]; stp d0,d1,[x0,#0x110].
    ctx_save = "000400a9020c01a9041402a9061c03a9082404a90a2c05a90c3406a90e3c07a9104408a9124c09a914540aa9165c0ba918640ca91a6c0da91c740ea91e7800f9e1030091017c00f91e8000f90004116d",
    -- +0x56aed8 (1.0.1f) / +0x5ddd08 (1.0.1o): ldr x8,[x8,#0x30]; blr x8;
    -- mov w0,wzr; str d0,[x19]; ldp x20,x19,[sp,#0x20]; ldr x21,[sp,#0x10];
    -- ldp x29,x30,[sp],#0x30; ret
    fp_capture = "081940f900013fd6e0031f2a600200fdf44f42a9f50b40f9fd7bc3a8c0035fd6",

    -- The rest of the chain. Complete
    -- consumed instruction ranges, not first-instruction prefixes: in
    -- particular the final SP restore and RET of the switch and of pop_gp
    -- must match, or a positive preflight would still enter a chain that
    -- cannot return.
    fiber_switch  = "ffc303d1020080d2e24f00a9f45701a9f65f02a9f86703a9fa6f04a9fc7705a9fe0b06a9e8a703adeaaf04adecb705adeebf06ade2030091020000f9220040f95f000091e04f40a9f45741a9f65f42a9f86743a9fa6f44a9fc7745a9fe3340f9e8a743adeaaf44adecb745adeebf46adffc30391c0035fd6",
    fiber_pop_gp  = "e00740a9e20f41a9e41742a9e61f43a9fd7b44a9ff4301911f2003d5c0035fd6",
    thunk_ptr     = "000c40f90207805203018052080040f9040d40f980001fd6",
}

-- Two gadgets were recompiled between builds, so each has known variants and
-- exactly one must match the image.
M.VARIANTS = {
    -- integer-return capture: blr x22 (1.0.1f) or blr x21 (1.0.1o)
    fiber_capture = {
        "c0023fd6600a00f9f44f42a9f65741a9fd7bc3a8c0035fd6",
        "a0023fd6600a00f9f44f42a9f65741a9fd7bc3a8c0035fd6",
    },
    -- the zero-result launderer: two compilations, identical contract
    -- (x1 from ctrl+0x38, callee from ctrl+0x48, x0 from ctrl+0x50)
    launder = {
        "fd7bbea9f30b00f9fd030091a00100b4011c40f9f30300aa410100b4682640f9080100b4602a40f900013fd6e0031f2a7f1e00f9f30b40f9fd7bc2a8c0035fd6",
        "fd7bbea9f30b00f9fd030091011c40f9f30300aa810100b4682640f9480100b4602a40f900013fd6e0031f2a7f1e00f9f30b40f9fd7bc2a8c0035fd620008012",
    },
}

-- ---------------------------------------------------------------- type model
-- Explicit, not inferred: an argument whose class we cannot name is refused
-- rather than guessed into the wrong register bank.
local GP = function(size, signed) return { class = "gp", size = size, signed = signed } end
local FP = function(size) return { class = "fp", size = size } end

local KIND = {
    ["void"]           = { class = "void" },
    ["bool"]           = { class = "gp", size = 1, signed = false, bool = true },
    ["char"]           = GP(1, true),
    ["signed char"]    = GP(1, true),
    ["unsigned char"]  = GP(1, false),
    ["short"]          = GP(2, true),
    ["unsigned short"] = GP(2, false),
    ["int"]            = GP(4, true),
    ["unsigned"]       = GP(4, false),
    ["unsigned int"]   = GP(4, false),
    ["long"]           = GP(8, true),
    ["unsigned long"]  = GP(8, false),
    ["long long"]      = GP(8, true),
    ["unsigned long long"] = GP(8, false),
    ["int8_t"]   = GP(1, true),  ["uint8_t"]  = GP(1, false),
    ["int16_t"]  = GP(2, true),  ["uint16_t"] = GP(2, false),
    ["int32_t"]  = GP(4, true),  ["uint32_t"] = GP(4, false),
    ["int64_t"]  = GP(8, true),  ["uint64_t"] = GP(8, false),
    ["intptr_t"] = GP(8, true),  ["uintptr_t"]= GP(8, false),
    ["size_t"]   = GP(8, false), ["ssize_t"]  = GP(8, true),
    ["ptrdiff_t"]= GP(8, true),
    ["float"]  = FP(4),
    ["double"] = FP(8),
}

local REFUSED = {
    ["long double"] = "long double is not supported by this bridge",
    ["..."] = "variadic calls are not supported by this bridge",
}

-- A declared type is either a name in KIND, or a pointer spelling (trailing
-- '*'), which is always one GP register regardless of referent.
local function classify(spec, what)
    if type(spec) ~= "string" then
        error(("%s: type must be a string, got %s"):format(what, type(spec)), 0)
    end
    local t = spec:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if REFUSED[t] then error(("%s: %s"):format(what, REFUSED[t]), 0) end
    if t:find("%*$") then
        return { class = "gp", size = 8, signed = false, ptr = true, ctype = t }
    end
    local k = KIND[t]
    if not k then
        error(("%s: unsupported type %q (struct/union by value, vectors and "
               .. "aggregates are refused; pass a pointer instead)"):format(what, t), 0)
    end
    local out = { class = k.class, size = k.size, signed = k.signed,
                  bool = k.bool, ctype = t }
    return out
end

-- compile{ret=..., args={...}} -> a frozen plan, with register assignment
-- resolved once at declare time rather than per call.
function M.compile(sig)
    assert(type(sig) == "table", "signature must be a table")
    local ret = classify(sig.ret or "void", "return type")
    local args, ngp, nfp = {}, 0, 0
    local raw = sig.args or {}
    assert(type(raw) == "table", "signature.args must be a table")
    for i = 1, #raw do
        local a = classify(raw[i], ("argument #%d"):format(i))
        if a.class == "void" then
            error(("argument #%d: void is not an argument type"):format(i), 0)
        end
        if a.class == "gp" then
            if ngp >= 8 then
                error(("argument #%d: more than 8 integer/pointer arguments "
                       .. "would need stack slots, which collide with the "
                       .. "capture gadget's register pops"):format(i), 0)
            end
            a.reg = ngp; ngp = ngp + 1
        else
            if nfp >= 8 then
                error(("argument #%d: more than 8 floating-point arguments "
                       .. "would need stack slots, which collide with the "
                       .. "capture gadget's register pops"):format(i), 0)
            end
            a.reg = nfp; nfp = nfp + 1
        end
        args[i] = a
    end
    if ret.class == "fp" then
        -- fp_capture derives the callee from [x8+0x30] and zeroes w0, so the
        -- integer return is unavailable on that path (and vice versa).
        ret.path = "fp"
    else
        ret.path = "int"
    end
    return { ret = ret, args = args, ngp = ngp, nfp = nfp, n = #args }
end

-- ------------------------------------------------------------- marshalling
-- Conversion goes through a real ctype box so LuaJIT performs the documented
-- Lua->C conversion (including cdata/number/boolean handling), and we only
-- read back the raw bits.
local boxes = {}

local function box_for(ffi, ctype)
    local b = boxes[ctype]
    if not b then
        local ok, made = pcall(ffi.new, ctype .. "[1]")
        if not ok then error(("cannot box type %q: %s"):format(ctype, tostring(made)), 0) end
        b = { arr = made, u8 = ffi.cast("uint8_t*", made) }
        boxes[ctype] = b
    end
    return b
end

local function gp_word(ffi, a, v, what)
    if a.ptr then
        if v == nil then return ffi.cast("uint64_t", 0) end
        local tv = type(v)
        if tv == "number" then
            if v % 1 ~= 0 then error(("%s: pointer from non-integer number"):format(what), 0) end
            return ffi.cast("uint64_t", ffi.cast("uintptr_t", v))
        elseif tv == "cdata" or tv == "string" then
            local ok, p = pcall(ffi.cast, "uintptr_t", v)
            if not ok then error(("%s: cannot take an address of this value"):format(what), 0) end
            return ffi.cast("uint64_t", p)
        else
            error(("%s: pointer argument must be nil, number, cdata or string"):format(what), 0)
        end
    end
    if a.bool then
        if type(v) == "cdata" then v = not u64_is_zero(ffi, v) end
        return ffi.cast("uint64_t", (v and v ~= 0) and 1 or 0)
    end
    local b = box_for(ffi, a.ctype)
    local ok, err = pcall(function() b.arr[0] = v end)
    if not ok then error(("%s: %s"):format(what, tostring(err)), 0) end
    -- AAPCS64: narrow integers are passed extended; extend to 64 bits so the
    -- callee sees a correct value whichever width it reads.
    local u = ffi.cast(a.signed and "int64_t" or "uint64_t",
                       ffi.cast(("%s*"):format(a.ctype), b.arr)[0])
    return ffi.cast("uint64_t", u)
end

local function fp_word(ffi, a, v, what)
    local b = box_for(ffi, a.ctype)
    local ok, err = pcall(function() b.arr[0] = v end)
    if not ok then error(("%s: %s"):format(what, tostring(err)), 0) end
    if a.size == 4 then
        -- A float argument occupies s_n, i.e. the low 32 bits of d_n.
        return ffi.cast("uint64_t", ffi.cast("uint32_t*", b.arr)[0])
    end
    return ffi.cast("uint64_t*", b.arr)[0]
end

function M.marshal(ffi, plan, ...)
    local n = select("#", ...)
    if n ~= plan.n then
        error(("native call expects %d argument(s), got %d"):format(plan.n, n), 0)
    end
    local gp, fp = {}, {}
    for i = 1, plan.n do
        local a = plan.args[i]
        local v = select(i, ...)
        local what = ("argument #%d (%s)"):format(i, a.ctype)
        if a.class == "gp" then gp[a.reg] = gp_word(ffi, a, v, what)
        else fp[a.reg] = fp_word(ffi, a, v, what) end
    end
    return gp, fp
end

function M.decode(ffi, ret, raw)
    local r = ret
    if r.class == "void" then return nil end
    if r.class == "fp" then
        if r.size == 4 then
            local b = box_for(ffi, "float")
            ffi.cast("uint32_t*", b.arr)[0] = ffi.cast("uint32_t", raw)
            return tonumber(b.arr[0])
        end
        local b = box_for(ffi, "double")
        ffi.cast("uint64_t*", b.arr)[0] = raw
        return tonumber(b.arr[0])
    end
    if r.bool then return not u64_is_zero(ffi, raw) end
    if r.ptr then return ffi.cast(r.ctype, ffi.cast("uintptr_t", raw)) end
    if r.size == 8 then
        return ffi.cast(r.signed and "int64_t" or "uint64_t", raw)
    end
    local cast = ("%s"):format(r.ctype)
    local v = ffi.cast(cast, ffi.cast(r.signed and "int64_t" or "uint64_t", raw))
    return tonumber(v)
end

-- ------------------------------------------------------------------- arena
local arena = nil

local function reserve(ffi)
    if not arena then
        arena = {
            ctrl  = jffi.ctrl(ffi, 0x200),
            stack = ffi.new("uint8_t[?]", M.layout.STACK_SIZE),
            ctx   = ffi.new("uint8_t[?]", M.CTX.SIZE + 0x20),
        }
        local function align(buf)
            local raw = tonumber(ffi.cast("uintptr_t", buf))
            return raw + (0x10 - raw % 0x10) % 0x10
        end
        arena.ctx_addr = align(arena.ctx)
    end
    return arena
end

function M.reset() arena = nil; M.ready = nil end

-- Allocate the arena without calling anything. Offline tests use this so the
-- ctx template buffer exists before construct() copies from it.
function M.prime(ffi) return reserve(ffi) end

local function p64(ffi, addr) return ffi.cast("uint64_t*", ffi.cast("uintptr_t", addr)) end

-- ---------------------------------------------------------------- preflight
local function check_bytes(ffi, base, rva, expected)
    local p = ffi.cast("const uint8_t*", ffi.cast("uintptr_t", base + rva))
    local got = {}
    for i = 0, #expected / 2 - 1 do got[#got + 1] = ("%02x"):format(tonumber(p[i])) end
    return table.concat(got) == expected
end

-- Every byte the chain will execute is checked before any transfer of
-- control, including the pieces this module inherited from the removed GP
-- bridge. An unfamiliar image fails closed here rather than mid-chain.
function M.preflight(ffi, info)
    if not (info and info.sdk_base and info.off) then return nil, "unresolved SDK" end
    for key, expected in pairs(M.SIGNATURE) do
        local rva = info.off[key]
        if not rva then return nil, "missing SDK offset " .. key end
        if not check_bytes(ffi, info.sdk_base, rva, expected) then
            return nil, "wrong SDK bytes at " .. key
        end
    end
    for key, options in pairs(M.VARIANTS) do
        local rva = info.off[key]
        if not rva then return nil, "missing SDK offset " .. key end
        local matched = false
        for _, expected in ipairs(options) do
            if check_bytes(ffi, info.sdk_base, rva, expected) then matched = true; break end
        end
        if not matched then return nil, "wrong SDK bytes at " .. key end
    end
    return true
end

-- ------------------------------------------------------------------- ready
-- Validate the image once and allocate the arena. This replaces the old
-- mandatory snapshot: it keeps the byte checks that must happen before any
-- transfer of control, without needing a native call to get there.
function M.ensure_ready(ffi, info)
    if M.ready then return true end
    local ok, why = M.preflight(ffi, info)
    if not ok then return nil, why end
    reserve(ffi)                      -- ffi.new zero-fills, so ctx starts zero
    M.ready = true
    return true
end

-- ---------------------------------------------------------------- construct
-- Builds every frame the chain consumes. Pure memory writes: no transfer of
-- control happens here, which is what makes the whole layout offline-testable.
function M.construct(ffi, info, plan, target, gp, fp)
    gp, fp = gp or {}, fp or {}
    local sdk, off, L = info.sdk_base, info.off, M.layout
    local target_word = ffi.cast("uint64_t", ffi.cast("uintptr_t", target))
    assert(not u64_is_zero(ffi, target_word), "null native callee")
    local held = reserve(ffi)
    local ctrl, ctx = held.ctrl, held.ctx_addr
    local raw = tonumber(ffi.cast("uintptr_t", held.stack))
    local P  = raw + 0x10000 + (16 - raw % 16) % 16   -- 64 KiB callee headroom
    local F  = P - L.FAKE_FRAME_SIZE                  -- fiber frame, SP=F on entry
    local S0 = P + 0x50                               -- target's SP (16-aligned)
    local Q  = S0 + L.CAPTURE_FRAME                   -- second pop_gp staging
    local function put(addr, v) p64(ffi, addr)[0] = ffi.cast("uint64_t", v) end

    -- Zero the context, then write only the argument and control fields. See
    -- the note at the top: no register the callee can observe needs a live
    -- value, x18 included, and that was measured rather than assumed.
    ffi.fill(ffi.cast("uint8_t*", ffi.cast("uintptr_t", ctx)), M.CTX.SIZE, 0)

    -- Arguments. Unused banks are zeroed so a stale value can never be read
    -- as an argument by a callee we mis-declared.
    for i = 0, 7 do
        put(ctx + M.CTX.X(i), gp[i] or 0)
        put(ctx + M.CTX.D(i), fp[i] or 0)
    end

    local cap_rva, x19
    if plan.ret.path == "fp" then
        cap_rva = off.fp_capture
        -- fp_capture: x8 -> [x8+0x30] = callee; d0 stored at [x19].
        put(ctrl.addr + L.FP_SLOT + 0x30, target_word)
        put(ctx + M.CTX.X(8), ctrl.addr + L.FP_SLOT)
        x19 = ctrl.addr + L.RESULT
    else
        cap_rva = off.fiber_capture
        -- fiber_capture: blr x22 (1.0.1f) or blr x21 (1.0.1o); x0 -> [x19+0x10].
        local cap_word = tonumber(ffi.cast("const uint32_t*",
            ffi.cast("uintptr_t", sdk + cap_rva))[0])
        if cap_word == 0xd63f02c0 then        -- blr x22
            put(ctx + M.CTX.X(22), target_word)
        elseif cap_word == 0xd63f02a0 then    -- blr x21
            put(ctx + M.CTX.X(21), target_word)
        else
            error(("unrecognised capture gadget: %08x"):format(cap_word))
        end
        put(ctx + M.CTX.X(8), 0)
        x19 = ctrl.addr
    end
    put(ctx + M.CTX.X(19), x19)
    put(ctx + M.CTX.X(29), F)
    put(ctx + M.CTX.SP, S0)
    put(ctx + M.CTX.LR, sdk + cap_rva)

    -- Fake fiber frame: the first switch restores x19/x30 and SP=F+0xf0=P.
    put(F + 0x08, ctrl.addr)                  -- x19, survives into pop_gp
    put(F + 0x58, F)                          -- x29, diagnostics only
    put(F + 0x60, sdk + off.fiber_pop_gp)     -- x30

    -- First pop_gp: x0 = &ctx, then ret into the context restore gadget.
    put(P + 0x00, ctx)
    for i = 1, 7 do put(P + i * 8, 0) end
    put(P + 0x40, F)                          -- x29
    put(P + 0x48, sdk + off.ctx_restore)      -- x30

    -- The capture gadget's pop window, read AFTER the target returns. Both
    -- variants use frame 0x30 and take x29/x30 from [S0]/[S0+8].
    put(S0 + 0x00, F)                         -- x29
    put(S0 + 0x08, sdk + off.fiber_pop_gp)    -- x30 -> second pop_gp
    put(S0 + 0x10, 0)                         -- x22 (int) / x21 (fp)
    put(S0 + 0x18, 0)                         -- x21 (int)
    put(S0 + 0x20, 0)                         -- x20
    put(S0 + 0x28, ctrl.addr)                 -- x19

    -- Second pop_gp: the two fiber slot pointers, in reverse order, then the
    -- switch that restores this same invocation's launder frame.
    put(Q + 0x00, ctrl.addr + L.FAKE)
    put(Q + 0x08, ctrl.addr + L.SAVED)
    for i = 2, 7 do put(Q + i * 8, 0) end
    put(Q + 0x40, F)
    put(Q + 0x48, sdk + off.fiber_switch)

    -- Launder inputs: x1 from ctrl+0x38 (must be nonzero), callee from
    -- ctrl+0x48, x0 from ctrl+0x50, and a forced zero result count on return.
    ctrl.u64(0)[0] = ctrl.addr + 0x80
    ctrl.u64(0x80 + jffi.VT_CALLEE)[0] = sdk + off.launder
    ctrl.u64(off.launder_arg1)[0] = ctrl.addr + L.FAKE   -- must be nonzero
    ctrl.u64(off.launder_callee)[0] = sdk + off.fiber_switch
    ctrl.u64(off.launder_arg0)[0] = ctrl.addr + L.SAVED
    ctrl.u64(L.SAVED)[0] = 0                             -- first switch fills
    ctrl.u64(L.FAKE)[0] = F                              -- first switch input
    ctrl.u64(L.RESULT)[0] = sentinel(ffi)                -- capture overwrites
    return { ctrl = ctrl, ctx = ctx, stack = held.stack, fake_frame = F,
             fake_sp = P, target_sp = S0, unwind_sp = Q,
             capture = sdk + cap_rva, path = plan.ret.path }
end

-- ------------------------------------------------------------------- invoke
function M.invoke(ffi, victim, info, plan, target, ...)
    if not M.ready then
        local ok, why = M.ensure_ready(ffi, info)
        if not ok then return nil, why end
    end
    local gp, fp = M.marshal(ffi, plan, ...)
    local setup = M.construct(ffi, info, plan, target, gp, fp)
    local result, err = jffi.call_ptr(ffi, victim,
                                      info.sdk_base + info.off.thunk_ptr,
                                      setup.ctrl)
    if not result then return nil, err end
    if result.ret ~= 0 then return nil, "BC_FUNCC returned a nonzero result count" end
    local L = M.layout
    -- Addresses are below 2^53, so tonumber() compares them exactly; the
    -- cdata == cdata that would read more naturally is defect 2 above.
    if u64_is_zero(ffi, setup.ctrl.u64(L.SAVED)[0]) or
       tonumber(setup.ctrl.u64(L.FAKE)[0]) == setup.fake_frame then
        return nil, "fiber switches did not complete"
    end
    local raw = setup.ctrl.u64(L.RESULT)[0]
    if u64_eq(ffi, raw, sentinel(ffi)) and plan.ret.class ~= "void" then
        -- The capture store is unconditional, so an untouched sentinel means
        -- the target was never entered.
        return nil, "capture gadget did not store a result"
    end
    return { value = M.decode(ffi, plan.ret, raw), raw = raw }
end

-- -------------------------------------------------------- callable surface
-- A PLAIN LUA CLOSURE, deliberately not an ffi.metatype __call.
--
-- The original design made declare() return a struct cdata with a metatype
-- __call, because lj_cf_ffi_meta___call tailcalls the ctype metamethod
-- (main+0x46238..0x46278) instead of reaching the dead dispatch stub. That
-- code path is present, but on this build ANY Lua metamethod installed
-- through ffi.metatype is fatal: measured on console, a metatype whose
-- __tostring is a Lua function kills the process on the first tostring(),
-- and likewise a Lua __call on the first invocation - with a trivial
-- `return 42` body that makes no native call at all, so the chain in this
-- module was not involved, and likewise for tostring() on a metatype whose
-- __tostring is a Lua function. Both were isolated on hardware by logging a
-- breadcrumb before each step and reading it back after the crash. Same
-- family as the broken 64-bit cdata equality above: this port's cdata
-- metamethod dispatch cannot be relied on.
--
-- A closure needs none of it. It is the ordinary VM call path the launcher
-- already uses everywhere, it takes varargs, and it cannot be reached by any
-- ffi metamethod machinery.

local described = setmetatable({}, { __mode = "k" })

-- ------------------------------------------------- safe metatype wrapper
-- ROOT CAUSE (read out of the shipped VM): it was generated by
-- buildvm with the DynASM `FFI` conditional OFF while the C library has
-- LJ_HASFFI=1, so every `.if FFI` block is missing from the interpreter while
-- the C code calling it is present. ->cont_dispatch (main+0x55a64) lost both
-- of its guards, so it reaches `br x0` with the continuation value that
-- lj_meta_tailcall installs (LJ_CONT_TAILCALL == 0) and branches to address
-- 0. Every C-function-to-Lua metamethod tailcall is therefore instant death:
-- cdata __call, a function __index/__newindex, __tostring, __pairs, and all
-- cdata arithmetic/comparison metamethods.
--
-- What survives, verified on console: a metatype whose __index is a TABLE,
-- because ffi_index_meta only tailcalls when the metamethod is a function and
-- resolves a table through lj_meta_tget in C. Methods work that way too
-- (the lookup returns the function, and calling it is an ordinary Lua call).
--
-- So this wrapper allows exactly that shape and turns every fatal one into a
-- Lua error, which is the difference between a stack trace and a reboot.
M.FATAL_METAMETHODS = {
    __call = "cdata __call tailcalls into Lua (ffi_meta___call)",
    __tostring = "cdata __tostring tailcalls into Lua (ffi_meta___tostring)",
    __pairs = "cdata __pairs tailcalls into Lua (ffi_pairs)",
    __ipairs = "cdata __ipairs tailcalls into Lua (ffi_pairs)",
    __eq = "cdata comparison metamethods tailcall into Lua (lj_carith_meta)",
    __lt = "cdata comparison metamethods tailcall into Lua (lj_carith_meta)",
    __le = "cdata comparison metamethods tailcall into Lua (lj_carith_meta)",
    __len = "cdata __len tailcalls into Lua (lj_carith_meta)",
    __concat = "cdata __concat tailcalls into Lua (lj_carith_meta)",
    __add = "cdata arithmetic metamethods tailcall into Lua (lj_carith_meta)",
    __sub = "cdata arithmetic metamethods tailcall into Lua (lj_carith_meta)",
    __mul = "cdata arithmetic metamethods tailcall into Lua (lj_carith_meta)",
    __div = "cdata arithmetic metamethods tailcall into Lua (lj_carith_meta)",
    __mod = "cdata arithmetic metamethods tailcall into Lua (lj_carith_meta)",
    __pow = "cdata arithmetic metamethods tailcall into Lua (lj_carith_meta)",
    __unm = "cdata arithmetic metamethods tailcall into Lua (lj_carith_meta)",
}

-- metatype(ffi, "ctype", { __index = <table>, __gc = <C-free only> })
function M.metatype(ffi, ctype, mt)
    assert(type(mt) == "table", "metatype table expected")
    for k, v in pairs(mt) do
        local why = M.FATAL_METAMETHODS[k]
        if why then
            error(("%s is fatal on this LuaJIT build: %s, and ->cont_dispatch "
                   .. "has no FFI guard, so it branches to address 0. Use a "
                   .. "table __index (methods work) or a plain closure.")
                  :format(k, why), 2)
        end
        if k == "__index" or k == "__newindex" then
            if type(v) ~= "table" then
                error(("%s must be a TABLE on this LuaJIT build: a function "
                       .. "metamethod reaches lj_meta_tailcall and kills the "
                       .. "process. Put methods in a table instead."):format(k), 2)
            end
        end
    end
    return ffi.metatype(ctype, mt)
end

-- declare(ffi, victim, info, "double", {"double","double"}, addr) -> function
function M.declare(ffi, victim, info, ret, args, address)
    local plan = M.compile({ ret = ret, args = args })
    local addr = ffi.cast("uint64_t", ffi.cast("uintptr_t", address))
    assert(not u64_is_zero(ffi, addr), "null native callee")
    local target = tonumber(ffi.cast("uintptr_t", address))
    local fn = function(...)
        local res, err = M.invoke(ffi, victim, info, plan, target, ...)
        if not res then error("native call failed: " .. tostring(err), 2) end
        return res.value
    end
    described[fn] = { addr = target, plan = plan, ret = ret, args = args }
    return fn, plan
end

-- What a declared callable points at, for logs and diagnostics.
function M.describe(fn)
    local d = described[fn]
    if not d then return nil end
    return ("native<0x%x>(%s)->%s"):format(d.addr,
           table.concat(d.args, ","), d.ret), d
end

M._described = described

-- ----------------------------------------------- the socket dispatch form
-- bl/socket.lua takes its native dispatch as an argument and defaults to
-- this. It is the contract the removed GP bridge used to provide:
--
--     dispatch(ffi, victim, info, target, args) -> { raw, int32, int64 }
--                                               -> nil, why
--
-- Arguments are declared as pointers, which accept integers, pointer cdata,
-- strings and nil alike, so an fd, a size and a buffer address all pass
-- through unchanged. The result table is { raw, int32, int64 }, the shape
-- bl/socket.lua reads.
--
-- This is also why consolidating was worth it: the old GP bridge re-ran its
-- full byte preflight on EVERY call, costing 0.300 ms and 0.060 KB of
-- garbage per call on console against 0.178 ms and 0.028 KB here (3000-call
-- interleaved runs, same target). The socket stack polls every frame.
local gp_plans = {}

-- Exposed so tests can exercise the real marshaller against the plan this
-- builds. The first version of gp_invoke passed args[1]..args[8]
-- unconditionally, which makes select("#") see eight arguments and fails
-- every call with "expects 3 argument(s), got 8" -- and the unit test missed
-- it because it stubbed M.invoke, the very function that checks arity. Real
-- nn::socket calls on hardware caught it immediately.
function M.gp_plan(n)
    local plan = gp_plans[n]
    if not plan then
        local spec = {}
        for i = 1, n do spec[i] = "void *" end
        local ok, built = pcall(M.compile, { ret = "uint64_t", args = spec })
        if not ok then return nil, tostring(built) end
        plan = built
        gp_plans[n] = plan
    end
    return plan
end

function M.gp_invoke(ffi, victim, info, target, args)
    args = args or {}
    local n = #args
    local plan, why = M.gp_plan(n)
    if not plan then return nil, why end
    -- exactly n arguments, never a padded eight
    local res, err = M.invoke(ffi, victim, info, plan, target, unpack(args, 1, n))
    if not res then return nil, err end
    local raw = res.raw
    return { raw = raw,
             int32 = ffi.cast("int32_t", raw),
             int64 = ffi.cast("int64_t", raw) }
end

return M
