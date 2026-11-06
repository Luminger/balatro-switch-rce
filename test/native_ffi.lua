-- bl.ffi_call: the full-ABI bridge that replaces this title's missing
-- lj_vm_ffi_call. These are the in-VM checks (classification, marshalling,
-- refusals, frame geometry, the metatype surface). The exact-image gadget
-- bytes and the full chain replay live in test/test_ffi_call.py, and the
-- marshaller is cross-checked against real ffi in test/ffi_call_oracle.lua.
return function(T, H)
    local check = T.check
    local ffi = require("ffi")
    local fc = require("bl.ffi_call")
    local off = require("bl.offsets")["1.0.1f-FULL"].sdk

    -- A stand-in image: construct() only writes memory and reads the capture
    -- gadget's first word, so no real SDK is needed to test the layout.
    local span = 0x600000
    local image = ffi.new("uint8_t[?]", span)
    local sdk = tonumber(ffi.cast("uintptr_t", image))
    ffi.cast("uint32_t*", ffi.cast("uintptr_t", sdk + off.fiber_capture))[0] = 0xd63f02c0
    local info = { sdk_base = sdk, off = off }
    fc.reset()
    fc.prime(ffi)

    -- ---------------------------------------------------------- classification
    local plan = fc.compile({ ret = "int",
                              args = { "int", "double", "void *", "float" } })
    check("integer and pointer arguments take the GP bank in order",
          plan.args[1].class == "gp" and plan.args[1].reg == 0 and
          plan.args[3].class == "gp" and plan.args[3].reg == 1)
    check("floating-point arguments take their own bank in order",
          plan.args[2].class == "fp" and plan.args[2].reg == 0 and
          plan.args[4].class == "fp" and plan.args[4].reg == 1)
    check("bank counts are resolved once at declare time",
          plan.ngp == 2 and plan.nfp == 2 and plan.n == 4)
    check("an integer return selects the x0 capture path",
          plan.ret.path == "int")
    check("a floating-point return selects the d0 capture path",
          fc.compile({ ret = "double", args = {} }).ret.path == "fp")
    check("void returns use the x0 path and decode to nil",
          fc.compile({ ret = "void", args = {} }).ret.path == "int" and
          fc.decode(ffi, fc.compile({ ret = "void" }).ret,
                    ffi.cast("uint64_t", 7)) == nil)
    check("any pointer spelling is one GP register",
          fc.compile({ ret = "void", args = { "struct foo *" } }).ngp == 1)

    -- ------------------------------------------------------------- refusals
    -- Each of these would otherwise be silently mis-marshalled, which on
    -- hardware means a wrong value or a wild branch rather than an error.
    local function refused(what, ...)
        local ok, err = pcall(...)
        check(what, not ok, ok and "ACCEPTED" or nil)
        return tostring(err)
    end
    local nine_gp = {}
    for i = 1, 9 do nine_gp[i] = "int" end
    local nine_fp = {}
    for i = 1, 9 do nine_fp[i] = "double" end
    local e1 = refused("a 9th GP argument is refused, not spilled to the stack",
                       fc.compile, { ret = "void", args = nine_gp })
    check("the GP refusal names the capture-gadget collision",
          e1:find("capture gadget") ~= nil, e1)
    refused("a 9th FP argument is refused", fc.compile, { ret = "void", args = nine_fp })
    refused("struct by value is refused", fc.compile, { ret = "void", args = { "struct foo" } })
    refused("a struct return is refused", fc.compile, { ret = "struct foo", args = {} })
    refused("long double is refused", fc.compile, { ret = "long double", args = {} })
    refused("varargs are refused", fc.compile, { ret = "void", args = { "..." } })
    refused("an unknown type name is refused", fc.compile, { ret = "void", args = { "wat_t" } })
    refused("void as an argument is refused", fc.compile, { ret = "void", args = { "void" } })
    refused("a wrong argument count is refused", fc.marshal, ffi,
            fc.compile({ ret = "void", args = { "int" } }))
    refused("a null callee is refused", fc.declare, ffi, nil, info, "void", {}, 0)

    -- ---------------------------------------------------------- marshalling
    local p = fc.compile({ ret = "void",
                           args = { "int", "double", "uint64_t", "float" } })
    local gp, fp = fc.marshal(ffi, p, -1, 2.5, ffi.cast("uint64_t", -1), 1.5)
    check("a narrow signed integer is sign-extended to 64 bits",
          fc.u64_eq(ffi, gp[0], ffi.cast("uint64_t", -1)))
    check("a 64-bit unsigned argument passes verbatim",
          fc.u64_eq(ffi, gp[1], ffi.cast("uint64_t", -1)))
    check("a double argument is its IEEE-754 bit pattern",
          fc.u64_eq(ffi, fp[0], ffi.cast("uint64_t", 0x40040000) * 4294967296))
    check("a float argument occupies the low half of its FP register",
          fc.u64_eq(ffi, fp[1], ffi.cast("uint64_t", 0x3fc00000)))

    local pb = fc.compile({ ret = "void", args = { "bool", "bool" } })
    local gb = fc.marshal(ffi, pb, true, false)
    check("booleans marshal to 1 and 0",
          tonumber(gb[0]) == 1 and tonumber(gb[1]) == 0)

    local pp = fc.compile({ ret = "void", args = { "void *", "void *" } })
    local probe = ffi.new("uint8_t[4]")
    local gpp = fc.marshal(ffi, pp, nil, probe)
    check("a nil pointer argument is zero, cdata takes its address",
          fc.u64_is_zero(ffi, gpp[0]) and
          tonumber(gpp[1]) == tonumber(ffi.cast("uintptr_t", probe)))

    -- -------------------------------------------------------------- decoding
    local function dec(ret, raw)
        return fc.decode(ffi, fc.compile({ ret = ret }).ret, ffi.cast("uint64_t", raw))
    end
    check("a narrow signed return is truncated and sign-extended",
          dec("int", ffi.cast("uint64_t", ffi.cast("int64_t", -5))) == -5)
    check("an unsigned 32-bit return keeps its full range",
          dec("uint32_t", 0xfffffffe) == 4294967294)
    check("a 64-bit return stays cdata so it cannot lose precision",
          fc.u64_eq(ffi, dec("uint64_t", ffi.cast("uint64_t", -1)),
                    ffi.cast("uint64_t", -1)))
    local dbox = ffi.new("double[1]"); dbox[0] = -2.75
    check("a double return decodes from the raw d0 bits",
          dec("double", ffi.cast("uint64_t*", dbox)[0]) == -2.75)
    local fbox = ffi.new("float[1]"); fbox[0] = 1.25
    check("a float return decodes from the low 32 bits of d0",
          dec("float", ffi.cast("uint32_t*", fbox)[0]) == 1.25)
    check("a bool return is true for any nonzero word", dec("bool", 256) == true)

    -- ------------------------------------------------------- frame geometry
    local target = sdk + 0x8e86c
    local ip = fc.compile({ ret = "int", args = { "int", "double" } })
    local igp, ifp = fc.marshal(ffi, ip, 7, 0.5)
    local s = fc.construct(ffi, info, ip, target, igp, ifp)
    local function rd(a) return ffi.cast("uint64_t*", ffi.cast("uintptr_t", a))[0] end
    local function is(a, v) return fc.u64_eq(ffi, rd(a), v) end
    check("the target is entered 16-byte aligned", s.target_sp % 16 == 0)
    check("the fake fiber frame sits one frame below the pop stack",
          s.fake_sp - s.fake_frame == fc.layout.FAKE_FRAME_SIZE)
    check("the unwind stack follows the capture gadget's frame",
          s.unwind_sp == s.target_sp + fc.layout.CAPTURE_FRAME and
          s.target_sp == s.fake_sp + 0x50)
    check("the first pop_gp passes the context block in x0",
          is(s.fake_sp, s.ctx))
    check("the first pop_gp returns into the context restore gadget",
          is(s.fake_sp + 0x48, sdk + off.ctx_restore))
    check("arguments are installed in the context, not the pop stack",
          is(s.ctx + fc.CTX.X(0), 7) and
          is(s.ctx + fc.CTX.D(0), ffi.cast("uint64_t", 0x3fe00000) * 4294967296))
    check("unused argument registers are zeroed in the context",
          is(s.ctx + fc.CTX.X(1), 0) and is(s.ctx + fc.CTX.D(1), 0))
    check("the context carries the target SP and the capture gadget as LR",
          is(s.ctx + fc.CTX.SP, s.target_sp) and
          is(s.ctx + fc.CTX.LR, sdk + off.fiber_capture))
    check("the integer path puts the callee in x22 for this build",
          is(s.ctx + fc.CTX.X(22), target) and is(s.ctx + fc.CTX.X(8), 0))
    check("the integer path aims the x0 store at ctrl+RESULT",
          is(s.ctx + fc.CTX.X(19), s.ctrl.addr))
    check("the capture pop window returns into the second pop_gp",
          is(s.target_sp + 8, sdk + off.fiber_pop_gp))
    check("the second pop_gp hands the fiber slots to the switch",
          is(s.unwind_sp, s.ctrl.addr + fc.layout.FAKE) and
          is(s.unwind_sp + 8, s.ctrl.addr + fc.layout.SAVED) and
          is(s.unwind_sp + 0x48, sdk + off.fiber_switch))
    check("the launder contract matches the proven GP bridge",
          is(s.ctrl.addr + off.launder_arg1, s.ctrl.addr + fc.layout.FAKE) and
          is(s.ctrl.addr + off.launder_callee, sdk + off.fiber_switch) and
          is(s.ctrl.addr + off.launder_arg0, s.ctrl.addr + fc.layout.SAVED))
    check("the result slot starts as a sentinel so a missed call is visible",
          is(s.ctrl.addr + fc.layout.RESULT, fc.sentinel(ffi)))
    check("the sentinel is wider than any plausible 32-bit return",
          fc.SENTINEL_HI ~= 0)
    -- This build's 64-bit cdata equality is broken and its ULL literals are
    -- not literals at all, so the module must never rely on either.
    check("the module compares 64-bit values without cdata equality",
          fc.u64_eq(ffi, ffi.cast("uint64_t", 5), ffi.cast("uint64_t", 5)) and
          not fc.u64_eq(ffi, ffi.cast("uint64_t", 5), ffi.cast("uint64_t", 6)) and
          fc.u64_is_zero(ffi, ffi.cast("uint64_t", 0)) and
          not fc.u64_is_zero(ffi, ffi.cast("uint64_t", -1)))

    local fpp = fc.compile({ ret = "double", args = { "double" } })
    local fgp, ffp = fc.marshal(ffi, fpp, 3.5)
    local sf = fc.construct(ffi, info, fpp, target, fgp, ffp)
    check("the fp path enters the d0-spilling capture gadget",
          sf.path == "fp" and is(sf.ctx + fc.CTX.LR, sdk + off.fp_capture))
    check("the fp path reaches its callee through [x8+0x30]",
          is(sf.ctx + fc.CTX.X(8), sf.ctrl.addr + fc.layout.FP_SLOT) and
          is(sf.ctrl.addr + fc.layout.FP_SLOT + 0x30, target))
    check("the fp path aims the d0 store at ctrl+RESULT",
          is(sf.ctx + fc.CTX.X(19), sf.ctrl.addr + fc.layout.RESULT))
    check("the fp path leaves the integer callee register clear",
          is(sf.ctx + fc.CTX.X(22), 0))
    check("both capture variants share one pop-window layout",
          is(sf.target_sp + 8, sdk + off.fiber_pop_gp) and
          sf.unwind_sp == sf.target_sp + fc.layout.CAPTURE_FRAME)

    -- ---------------------------------------------------- the callable surface
    -- A PLAIN CLOSURE. ffi.metatype metamethods are fatal on the shipping
    -- build (a Lua __tostring kills the process on the first tostring(), a
    -- Lua __call on the first invocation), so the surface must not use them.
    local code = {}
    for line in io.lines("src/bl/ffi_call.lua") do
        if not line:find("^%s*%-%-") then code[#code + 1] = line end
    end
    code = table.concat(code, "\n")
    local n_mt = 0
    for _ in code:gmatch("ffi%.metatype%(") do n_mt = n_mt + 1 end
    check("the only ffi.metatype call is the validating wrapper", n_mt == 1)
    check("declare installs no metamethods at all",
          not code:match("function M%.declare.-metatype"))
    check("the module never calls ffi.cdef", not code:find("ffi%.cdef"))
    local fn, fplan = fc.declare(ffi, nil, info, "double", { "double", "double" }, 0x1234)
    check("declare returns a callable Lua function, not cdata",
          type(fn) == "function")
    check("declare also returns the compiled plan",
          fplan and fplan.ret.path == "fp" and fplan.nfp == 2)
    local desc, d = fc.describe(fn)
    check("a declared callable can be described for logs",
          desc == "native<0x1234>(double,double)->double" and d.addr == 0x1234)
    check("an undeclared function has no description",
          fc.describe(function() end) == nil)
    local ok, err = pcall(fn, 2, 10)
    check("a failed preflight raises instead of transferring control",
          not ok and tostring(err):find("native call failed"), tostring(err))
    check("preflight is what rejects the stand-in image",
          tostring(err):find("wrong SDK bytes"), tostring(err))
    check("a wrong argument count raises at the callable",
          not pcall(fn, 2))

    -- ------------------------------------------------- safe metatype guard
    -- The build's ->cont_dispatch has no FFI guard, so a Lua metamethod on a
    -- cdata branches to address 0. M.metatype refuses exactly those shapes.
    local okmt, cterr = pcall(fc.metatype, ffi, "bl_probe_mt_t", { __call = function() end })
    check("metatype refuses a Lua __call", not okmt and
          tostring(cterr):find("fatal on this LuaJIT build"), tostring(cterr))
    for _, mm in ipairs({"__tostring", "__add", "__eq", "__len", "__pairs", "__concat"}) do
        local ok2, e2 = pcall(fc.metatype, ffi, "bl_probe_mt_t", { [mm] = function() end })
        check("metatype refuses a Lua " .. mm, not ok2 and
              tostring(e2):find("fatal on this LuaJIT build"), tostring(e2))
    end
    local ok3, e3 = pcall(fc.metatype, ffi, "bl_probe_mt_t", { __index = function() end })
    check("metatype refuses a function __index", not ok3 and
          tostring(e3):find("must be a TABLE"), tostring(e3))
    check("every fatal metamethod carries a reason",
          (function()
              for k, v in pairs(fc.FATAL_METAMETHODS) do
                  if type(v) ~= "string" or #v < 10 then return false end
              end
              return true
          end)())
    -- a table __index is the shape that survives, and it is passed through
    pcall(ffi.cdef, "typedef struct { int v; } bl_probe_mt_t;")
    local okt, ct2 = pcall(fc.metatype, ffi, "bl_probe_mt_t",
                           { __index = { konst = 42, m = function(self) return "M" end } })
    check("metatype allows a table __index", okt, tostring(ct2))
    if okt then
        local obj = ct2(7)
        check("table __index resolves fields, constants and methods",
              obj.v == 7 and obj.konst == 42 and obj:m() == "M")
    end

    -- bl/socket.lua must default to this module: it is the only bridge left.
    do
        local sock = require("bl.socket").new(ffi, "function: 0x1", info)
        check("bl/socket.lua defaults to ffi_call.gp_invoke",
              sock.dispatch == fc.gp_invoke)
    end

    -- ---------------------------------------------- the love.ffi surface
    -- bl/call.lua is the project's native base: the full-ABI interface must
    -- be the primary surface, with the proven GP bridge kept for the socket
    -- stack, and ffi itself still reachable for cdefs/casts/reads.
    do
        local call = require("bl.call")
        local love_table = {}
        local victim = setmetatable({}, { __tostring = function() return "function: 0x1234abcd" end })
        local backend_args = nil
        local api = call.install(love_table, ffi, victim, info,
                                 function(_, _, _, target, a) backend_args = {target, a}; return {raw = 0} end)
        check("love.ffi is installed", love_table.ffi == api)
        check("declare is the primary surface", type(api.declare) == "function")
        check("the legacy GP bridge is still exposed", type(api.invoke) == "function")
        check("the guarded metatype is exposed", type(api.metatype) == "function")
        check("the u64 comparison workarounds are exposed",
              api.u64_eq(ffi.cast("uint64_t", 5), ffi.cast("uint64_t", 5)) and
              api.u64_is_zero(ffi.cast("uint64_t", 0)))
        check("preflight is callable without making a call",
              select(1, api.native_ready()) == nil)   -- stand-in image is refused
        api.invoke(0x1234, 7)
        check("invoke still routes to the injected backend",
              backend_args and backend_args[1] == 0x1234 and backend_args[2][1] == 7)
        check("ordinary ffi still falls through", api.cast ~= nil and api.raw == ffi)
        local fn = api.declare("double", { "double" }, 0x2000)
        check("declare returns a Lua function through love.ffi", type(fn) == "function")
        check("declared callables are describable",
              tostring(api.describe(fn)):find("native<0x2000>"))
        check("the guarded metatype refuses a fatal shape through love.ffi",
              not pcall(api.metatype, "bl_probe_mt_t", { __call = function() end }))
    end

    -- ------------------------------- drop-in dispatch for bl/socket.lua
    -- socket.lua calls dispatch(ffi, victim, info, target, args) and reads
    -- .raw/.int32/.int64; gp_invoke must keep that contract exactly, or the
    -- whole network stack silently changes behaviour.
    do
        local seen = nil
        local saved = fc.invoke
        fc.invoke = function(_, _, _, plan, tgt, ...)
            seen = { plan = plan, target = tgt, args = { ... } }
            return { raw = ffi.cast("uint64_t", 4294967295) }
        end
        local r, why = fc.gp_invoke(ffi, nil, info, 0x3000, { 7, 0x41, 4096 })
        local p1 = seen and seen.plan
        fc.gp_invoke(ffi, nil, info, 0x3000, { 1, 2, 3 })
        local cached = seen and seen.plan == p1
        fc.invoke = saved
        check("gp_invoke returns the documented result shape",
              r ~= nil and r.raw ~= nil and r.int32 ~= nil and r.int64 ~= nil, tostring(why))
        check("gp_invoke sign-extends int32 for the socket stack",
              r and tonumber(r.int32) == -1)
        check("gp_invoke keeps the unsigned raw value",
              r and fc.u64_eq(ffi, r.raw, ffi.cast("uint64_t", 4294967295)))
        check("gp_invoke forwards the target and arguments in order",
              seen and p1 and r ~= nil)
        check("gp_invoke declares one pointer slot per argument",
              p1 and p1.n == 3 and p1.ngp == 3 and p1.nfp == 0)
        check("gp_invoke caches the plan per arity", cached)
        -- REGRESSION: gp_invoke first passed args[1]..args[8] unconditionally,
        -- so marshal saw eight arguments for a three-argument plan and every
        -- call failed. The stub above cannot catch that because it replaces
        -- the function that checks arity, so drive the REAL marshaller with
        -- the plan gp_invoke builds, for every arity it can produce.
        for n = 0, 8 do
            local plan = fc.gp_plan(n)
            local vals = {}
            for i = 1, n do vals[i] = i * 16 end
            local okm, gp = pcall(fc.marshal, ffi, plan, unpack(vals, 1, n))
            local placed = okm and (function()
                for i = 1, n do
                    if tonumber(gp[i - 1]) ~= i * 16 then return false end
                end
                return true
            end)()
            check(("gp_plan(%d) marshals %d argument(s) into x0..x%d"):format(n, n, n - 1),
                  okm and placed, okm and "wrong placement" or tostring(gp))
        end
        check("gp_plan(9) is refused like any 9th GP argument", fc.gp_plan(9) == nil)
    end

    -- ------------------------------------------------- bootstrap without a call
    -- The old mandatory snapshot is gone: x18 is scratch on this SDK, so the
    -- ctx template stays zero and no native call is needed to get started.
    -- What must NOT be lost is the image validation that used to ride along
    -- with it, so ensure_ready keeps the byte checks.
    fc.reset()
    check("not ready before the first use", fc.ready == nil)
    local rok, rwhy = fc.ensure_ready(ffi, info)
    check("ensure_ready refuses a stand-in image",
          rok == nil and tostring(rwhy):find("wrong SDK bytes"), tostring(rwhy))
    check("a refused image does not latch ready", fc.ready == nil)
    local code2 = {}
    for line in io.lines("src/bl/ffi_call.lua") do
        if not line:find("^%s*%-%-") then code2[#code2 + 1] = line end
    end
    code2 = table.concat(code2, "\n")
    check("invoke no longer requires a snapshot",
          code2:find("M%.ready") and not code2:find("if not M%.snapshot_ok then"))
    check("the ctx is zero-filled, with no template to copy",
          code2:find("ffi%.fill") and not code2:find("tmpl"))
    check("no per-process register snapshot remains",
          fc.snapshot == nil and fc.snapshot_ok == nil)
    check("preflight is self-contained: it checks the whole chain",
          (function()
              local need = { "ctx_restore", "ctx_save", "fp_capture",
                             "fiber_switch", "fiber_pop_gp", "thunk_ptr" }
              for _, k in ipairs(need) do
                  if not fc.SIGNATURE[k] then return false end
              end
              return fc.VARIANTS.fiber_capture and #fc.VARIANTS.fiber_capture == 2
                     and fc.VARIANTS.launder and #fc.VARIANTS.launder == 2
          end)())
    -- a missing offset for any inherited chain piece must fail closed too
    for _, k in ipairs({ "fiber_switch", "fiber_pop_gp", "thunk_ptr", "launder" }) do
        local stripped = setmetatable({ [k] = false }, { __index = info.off })
        local sok = fc.preflight(ffi, { sdk_base = info.sdk_base, off = stripped })
        check("preflight refuses a missing " .. k .. " offset", sok == nil)
    end
    fc.reset()
end
