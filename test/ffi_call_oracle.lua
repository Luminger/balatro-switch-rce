-- Marshalling oracle: on a DESKTOP LuaJIT (where lj_vm_ffi_call exists) run
-- the same calls twice - once through real ffi, once through bl.ffi_call's
-- marshaller feeding a hand-written AAPCS64 interpreter - and compare.
--
-- This cannot and does not test the gadget chain (desktop has no NX SDK). It
-- tests the half that is pure logic: which register each argument lands in,
-- the bit pattern written there, and how a raw return decodes. A mistake
-- there would otherwise only show up as a wrong value on console.
package.path = "src/?.lua;" .. package.path
local ffi = require("ffi")
local fc = require("bl.ffi_call")

ffi.cdef[[
double pow(double, double);
double ldexp(double, int);
int abs(int);
size_t strlen(const char *);
char *strchr(const char *, int);
float fabsf(float);
double fmod(double, double);
int memcmp(const void *, const void *, size_t);
]]

local fails, checks = 0, 0
local function eq(what, got, want)
    checks = checks + 1
    -- A 64-bit return decodes to cdata, exactly as real ffi does for size_t,
    -- so compare numerically when the expectation is a plain number.
    if type(got) == "cdata" and type(want) == "number" then
        got = tonumber(got)
    end
    if tostring(got) ~= tostring(want) then
        fails = fails + 1
        print(("FAIL %s: got %s want %s"):format(what, tostring(got), tostring(want)))
    end
end

-- Interpret a marshalled call the way the gadget chain would: place gp[i] in
-- x_i and fp[i] in d_i, then call through a real ffi function pointer whose
-- declared type matches the plan. Returns the RAW 64-bit result the capture
-- gadget would have stored.
local function raw_call(plan, cfunc, gp, fp)
    local gpv, fpv = {}, {}
    for i = 0, 7 do
        gpv[i] = gp[i] or ffi.cast("uint64_t", 0)
        fpv[i] = fp[i] or ffi.cast("uint64_t", 0)
    end
    -- Rebuild each declared argument from the register bits alone, so a
    -- marshalling bug cannot be masked by reusing the original Lua value.
    local call_args = {}
    for i = 1, plan.n do
        local a = plan.args[i]
        if a.class == "gp" then
            local word = gpv[a.reg]
            if a.ptr then
                call_args[i] = ffi.cast(a.ctype, ffi.cast("uintptr_t", word))
            else
                call_args[i] = ffi.cast(a.ctype, word)
            end
        else
            local box = ffi.new(a.ctype .. "[1]")
            if a.size == 4 then
                ffi.cast("uint32_t*", box)[0] = ffi.cast("uint32_t", fpv[a.reg])
            else
                ffi.cast("uint64_t*", box)[0] = fpv[a.reg]
            end
            call_args[i] = box[0]
        end
    end
    local ret = cfunc(unpack(call_args, 1, plan.n))
    -- Mirror the capture gadgets: x0 verbatim, or the low 64 bits of d0.
    if plan.ret.class == "void" then return ffi.cast("uint64_t", 0) end
    if plan.ret.class == "fp" then
        local box = ffi.new(plan.ret.ctype .. "[1]")
        box[0] = ret
        if plan.ret.size == 4 then
            return ffi.cast("uint64_t", ffi.cast("uint32_t*", box)[0])
        end
        return ffi.cast("uint64_t*", box)[0]
    end
    if plan.ret.ptr then return ffi.cast("uint64_t", ffi.cast("uintptr_t", ret)) end
    if plan.ret.bool then return ffi.cast("uint64_t", ret and 1 or 0) end
    return ffi.cast("uint64_t", ffi.cast(plan.ret.signed and "int64_t" or "uint64_t", ret))
end

local function roundtrip(what, ret, args, cfunc, vals, expect)
    local plan = fc.compile({ ret = ret, args = args })
    local gp, fp = fc.marshal(ffi, plan, unpack(vals, 1, #args))
    local raw = raw_call(plan, cfunc, gp, fp)
    local got = fc.decode(ffi, plan.ret, raw)
    eq(what, got, expect)
    return got
end

-- doubles in d0/d1, double return
roundtrip("pow(2,10)", "double", {"double","double"}, ffi.C.pow, {2, 10}, 2 ^ 10)
roundtrip("pow(1.5,3)", "double", {"double","double"}, ffi.C.pow, {1.5, 3}, 1.5 ^ 3)
roundtrip("fmod(7.5,2)", "double", {"double","double"}, ffi.C.fmod, {7.5, 2}, 1.5)
-- mixed banks: double in d0, int in x0
roundtrip("ldexp(3,4)", "double", {"double","int"}, ffi.C.ldexp, {3, 4}, 48)
roundtrip("ldexp(1,-2)", "double", {"double","int"}, ffi.C.ldexp, {1, -2}, 0.25)
-- float argument and float return (s0 = low half of d0)
roundtrip("fabsf(-2.5)", "float", {"float"}, ffi.C.fabsf, {-2.5}, 2.5)
-- negative int argument, int return
roundtrip("abs(-42)", "int", {"int"}, ffi.C.abs, {-42}, 42)
-- pointer argument, size_t return
local s = "hello world"
local buf = ffi.new("char[?]", #s + 1)
ffi.copy(buf, s)
roundtrip("strlen", "size_t", {"const char *"}, ffi.C.strlen, {buf}, #s)
-- pointer in, pointer out
local plan = fc.compile({ ret = "char *", args = {"const char *", "int"} })
local gp, fp = fc.marshal(ffi, plan, buf, string.byte("w"))
local got = fc.decode(ffi, plan.ret, raw_call(plan, ffi.C.strchr, gp, fp))
eq("strchr offset", tonumber(ffi.cast("uintptr_t", got) - ffi.cast("uintptr_t", buf)), 6)
eq("strchr string", ffi.string(got), "world")
-- three GP arguments including a size_t
local b2 = ffi.new("char[?]", #s + 1); ffi.copy(b2, s)
roundtrip("memcmp equal", "int", {"const void *","const void *","size_t"},
          ffi.C.memcmp, {buf, b2, #s}, 0)

-- uint64 edge values survive the GP bank verbatim
local plan64 = fc.compile({ ret = "uint64_t", args = {"uint64_t"} })
for _, v in ipairs({ffi.cast("uint64_t", 0), ffi.cast("uint64_t", 1),
                    ffi.cast("uint64_t", -1), 0x7fffffff}) do
    local g = fc.marshal(ffi, plan64, v)
    eq("u64 passthrough " .. tostring(v), fc.decode(ffi, plan64.ret, g[0]),
       ffi.cast("uint64_t", v))
end

-- a declared bool return reads the low bit of x0 only
local planb = fc.compile({ ret = "bool", args = {} })
eq("bool false", fc.decode(ffi, planb.ret, ffi.cast("uint64_t", 0)), false)
eq("bool true", fc.decode(ffi, planb.ret, ffi.cast("uint64_t", 256)), true)

print(("oracle: %d checks, %d failures"):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
