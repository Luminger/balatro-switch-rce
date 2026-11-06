"""Offline construction gate for the full-ABI native-call bridge (bl.ffi_call).

What this proves, and what it does not:

  * the gadget bytes bl/ffi_call.lua preflights exist at the offsets
    bl/offsets.lua names, in BOTH exact SDK images (1.0.1f and 1.0.1o), and
    the two builds carry byte-identical gadgets;
  * main's lj_vm_ffi_call stub really is zero padding, so this bridge is
    answering a real gap and not duplicating a working path;
  * the ACTUAL Lua constructor's memory is replayed through every
    register/SP transition the chain performs - first pop_gp, the context
    restore (x0..x7, d0..d7, x8, x19, x21/x22, SP, LR), both capture
    variants, the pop window, second pop_gp, both fiber switches and the
    launder epilogue - including SP alignment at the indirect call and the
    destructive second save over consumed ROP words;
  * arguments marshal into the registers AAPCS64 requires, and raw returns
    decode per declared class.

It does NOT claim hardware success. Nothing here calls a native function.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import unittest

HERE = pathlib.Path(__file__).resolve().parents[1]

# Flat images of the title's own NSOs (file offset == virtual address). They
# are not redistributable, so these tests skip unless you point at your own
# dumps:  BL_FLAT_DIR=/path/to/dumps python3 -m unittest ...
# Expected names, 1.0.1f:  main.flat.bin  sdk.flat.bin
FLAT_DIR = pathlib.Path(os.environ.get("BL_FLAT_DIR", HERE / "dumps"))
SDK_F = FLAT_DIR / "sdk.flat.bin"
MAIN_F = FLAT_DIR / "main.flat.bin"

SDK_F_SHA = "fb425c806154ad79d244a9b6022e5c10263706a128a1876feaa1c63998e6f2e4"
MAIN_F_SHA = "8e3a5e6c1a37f7eee4f3ee9a85dbe4f5144689754c0707a0e592765716cb9674"

# Offsets per build, as bl/offsets.lua declares them.
GADGETS = {
    "1.0.1f-FULL": {"ctx_restore": 0x56EE64, "ctx_save": 0x56EEF0,
                    "fp_capture": 0x56AED8, "fiber_capture": 0x32D3C,
                    "fiber_switch": 0x135CD4, "fiber_pop_gp": 0x3ABA24,
                    "launder": 0x76410, "thunk_ptr": 0x8B1AC},
    "1.0.1o-FULL": {"ctx_restore": 0x5E17A4, "ctx_save": 0x5E1830,
                    "fp_capture": 0x5DDD08, "fiber_capture": 0x34DB0,
                    "fiber_switch": 0x13D3B4, "fiber_pop_gp": 0x3D9E54,
                    "launder": 0x78A14, "thunk_ptr": 0x8DFAC},
}
# Two gadgets were recompiled between builds; each has known variants.
VARIANTS = {
    "fiber_capture": [
        "c0023fd6600a00f9f44f42a9f65741a9fd7bc3a8c0035fd6",   # blr x22, 1.0.1f
        "a0023fd6600a00f9f44f42a9f65741a9fd7bc3a8c0035fd6",   # blr x21, 1.0.1o
    ],
    "launder": [
        "fd7bbea9f30b00f9fd030091a00100b4011c40f9f30300aa410100b4682640f9080100b4602a40f900013fd6e0031f2a7f1e00f9f30b40f9fd7bc2a8c0035fd6",
        "fd7bbea9f30b00f9fd030091011c40f9f30300aa810100b4682640f9480100b4602a40f900013fd6e0031f2a7f1e00f9f30b40f9fd7bc2a8c0035fd620008012",
    ],
}
# Every byte of the chain the launcher executes, in one place.
SIGNATURES = {
    "fiber_switch": "ffc303d1020080d2e24f00a9f45701a9f65f02a9f86703a9fa6f04a9fc7705a9fe0b06a9e8a703adeaaf04adecb705adeebf06ade2030091020000f9220040f95f000091e04f40a9f45741a9f65f42a9f86743a9fa6f44a9fc7745a9fe3340f9e8a743adeaaf44adecb745adeebf46adffc30391c0035fd6",
    "fiber_pop_gp": "e00740a9e20f41a9e41742a9e61f43a9fd7b44a9ff4301911f2003d5c0035fd6",
    "thunk_ptr": "000c40f90207805203018052080040f9040d40f980001fd6",
    "ctx_restore": "020c41a9041442a9061c43a9082444a90a2c45a90c3446a90e3c47a9124c49a914544aa9165c4ba918644ca91a6c4da91c744ea91e8040f90004516d020c526d0414536d061c546d0824556d0a2c566d0c34576d0e3c586d1044596d124c5a6d14545b6d165c5c6d18645d6d1a6c5e6d1c745f6d1e0041fd1f0441fd107c40f9000440a91f020091c0035fd6",
    "ctx_save": "000400a9020c01a9041402a9061c03a9082404a90a2c05a90c3406a90e3c07a9104408a9124c09a914540aa9165c0ba918640ca91a6c0da91c740ea91e7800f9e1030091017c00f91e8000f90004116d",
    "fp_capture": "081940f900013fd6e0031f2a600200fdf44f42a9f50b40f9fd7bc3a8c0035fd6",
}
# lj_vm_ffi_call's single call site and its bodiless target in main.
VM_FFI_CALL_STUB = 0x56EF8
VM_FFI_CALL_SITE = 0x46994

CTX = {"SP": 0xF8, "LR": 0x100}
CTX_X = lambda n: 8 * n          # noqa: E731
CTX_D = lambda n: 0x110 + 8 * n  # noqa: E731

# Drive the real module and dump the frames it built, for two return classes.
DRIVER = r'''
package.path = "src/?.lua;" .. package.path
local ffi = require("ffi")
local fc = require("bl.ffi_call")
local off = require("bl.offsets")["1.0.1f-FULL"].sdk

-- A fake SDK image big enough to hold the gadget offsets we reference, with
-- the capture gadget's first word set so the x22/x21 variant is detected.
local span = math.max(off.ctx_restore, off.fp_capture, off.fiber_capture,
                      off.fiber_pop_gp, off.fiber_switch, off.launder) + 0x40
local sdk_buf = ffi.new("uint8_t[?]", span)
local sdk = tonumber(ffi.cast("uintptr_t", sdk_buf))
ffi.cast("uint32_t*", ffi.cast("uintptr_t", sdk + off.fiber_capture))[0] = 0xd63f02c0
local info = { sdk_base = sdk, off = off }

-- The one-time context snapshot is a hardware step; offline we only need the
-- arena (and therefore the ctx template buffer) to exist.
fc.prime(ffi)

local out = {}
local function emit(k, v) out[#out+1] = k .. "=" .. v end

local cases = {
  int = { ret = "int", args = {"int","void*","double","float","uint64_t","double"},
          vals = {-7, 0x1234, 1.5, 0.5, "18446744073709551615", 2.25} },
  fp  = { ret = "double", args = {"double","int"}, vals = {3.5, 9} },
}

for name, c in pairs(cases) do
    local plan = fc.compile({ ret = c.ret, args = c.args })
    local vals = {}
    for i, v in ipairs(c.vals) do
        if type(v) == "string" then vals[i] = ffi.cast("uint64_t", -1)
        else vals[i] = v end
    end
    local gp, fp = fc.marshal(ffi, plan, unpack(vals, 1, #c.args))
    local setup = fc.construct(ffi, info, plan, sdk + 0x8e86c, gp, fp)
    local function rd(a) return tostring(ffi.cast("uint64_t*", ffi.cast("uintptr_t", a))[0]) end
    emit(name .. ".sdk", string.format("%.0f", sdk))
    emit(name .. ".ctrl", string.format("%.0f", setup.ctrl.addr))
    emit(name .. ".ctx", string.format("%.0f", setup.ctx))
    emit(name .. ".F", string.format("%.0f", setup.fake_frame))
    emit(name .. ".P", string.format("%.0f", setup.fake_sp))
    emit(name .. ".S0", string.format("%.0f", setup.target_sp))
    emit(name .. ".Q", string.format("%.0f", setup.unwind_sp))
    emit(name .. ".capture", string.format("%.0f", setup.capture))
    emit(name .. ".path", setup.path)
    for i = 0, 7 do
        emit(name .. ".x" .. i, rd(setup.ctx + 8 * i))
        emit(name .. ".d" .. i, rd(setup.ctx + 0x110 + 8 * i))
    end
    for _, n in ipairs({8, 19, 21, 22, 29}) do
        emit(name .. ".X" .. n, rd(setup.ctx + 8 * n))
    end
    emit(name .. ".ctxSP", rd(setup.ctx + 0xf8))
    emit(name .. ".ctxLR", rd(setup.ctx + 0x100))
    for _, o in ipairs({0x08, 0x58, 0x60}) do
        emit(name .. ".F" .. o, rd(setup.fake_frame + o))
    end
    for o = 0, 0x48, 8 do
        emit(name .. ".P" .. o, rd(setup.fake_sp + o))
    end
    -- capture pop window; 'W' so these cannot collide with the .S0 geometry key
    for o = 0, 0x28, 8 do
        emit(name .. ".W" .. o, rd(setup.target_sp + o))
    end
    for _, o in ipairs({0x00, 0x08, 0x40, 0x48}) do
        emit(name .. ".Q" .. o, rd(setup.unwind_sp + o))
    end
    for _, o in ipairs({0x00, 0x10, 0x38, 0x48, 0x50, 0x120, 0x128, 0x1b0}) do
        emit(name .. ".C" .. o, rd(setup.ctrl.addr + o))
    end
end

-- Decode checks, independent of any frame.
local function dec(ret, raw) return fc.decode(ffi, fc.compile({ret=ret}).ret, ffi.cast("uint64_t", raw)) end
emit("dec.int_neg", tostring(dec("int", ffi.cast("uint64_t", ffi.cast("int64_t", -5)))))
emit("dec.u32", tostring(dec("uint32_t", 0xfffffffe)))
emit("dec.bool0", tostring(dec("bool", 0)))
emit("dec.bool1", tostring(dec("bool", 7)))
emit("dec.u64", tostring(dec("uint64_t", ffi.cast("uint64_t", -1))))
local dbox = ffi.new("double[1]"); dbox[0] = -2.75
emit("dec.double", tostring(dec("double", ffi.cast("uint64_t*", dbox)[0])))
local fbox = ffi.new("float[1]"); fbox[0] = 1.25
emit("dec.float", tostring(dec("float", ffi.cast("uint32_t*", fbox)[0])))
emit("dec.ptr", tostring(dec("void*", 0x4030) ~= nil))

-- Refusals must be refusals, not silent mis-marshalling.
local function refused(f, ...)
    local ok, err = pcall(f, ...)
    return (not ok) and tostring(err) or "ACCEPTED"
end
emit("refuse.stack_gp", refused(fc.compile,
     {ret="void", args={"int","int","int","int","int","int","int","int","int"}}))
emit("refuse.stack_fp", refused(fc.compile,
     {ret="void", args={"double","double","double","double","double","double","double","double","double"}}))
emit("refuse.struct", refused(fc.compile, {ret="void", args={"struct foo"}}))
emit("refuse.ldouble", refused(fc.compile, {ret="long double", args={}}))
emit("refuse.varargs", refused(fc.compile, {ret="void", args={"..."}}))
emit("refuse.argcount", refused(fc.marshal, ffi,
     fc.compile({ret="void", args={"int"}})))

print(table.concat(out, "\n"))
'''


def _hexbytes(image: bytes, off: int, n: int) -> str:
    return image[off:off + n].hex()


class ExactImageTests(unittest.TestCase):
    def setUp(self):
        if not SDK_F.exists() or not MAIN_F.exists():
            self.skipTest("exact flat dumps unavailable")
        self.sdk = SDK_F.read_bytes()
        self.main = MAIN_F.read_bytes()
        self.assertEqual(hashlib.sha256(self.sdk).hexdigest(), SDK_F_SHA)
        self.assertEqual(hashlib.sha256(self.main).hexdigest(), MAIN_F_SHA)

    def test_missing_dispatch_stub_is_zero_padding(self):
        # The gap this bridge exists for: the bl target is 8 zero bytes, and
        # the instruction before it is a ret, the one after a prologue.
        self.assertEqual(self.main[VM_FFI_CALL_STUB:VM_FFI_CALL_STUB + 8], b"\0" * 8)
        self.assertEqual(_hexbytes(self.main, VM_FFI_CALL_STUB - 4, 4), "c0035fd6")  # ret
        self.assertEqual(_hexbytes(self.main, VM_FFI_CALL_STUB + 8, 4), "fd7bbea9")  # stp x29,x30
        # and the call site really targets it: bl with imm26 = (dst-src)/4
        word = struct.unpack_from("<I", self.main, VM_FFI_CALL_SITE)[0]
        self.assertEqual(word >> 26, 0b100101, "not a bl")
        imm = word & 0x3FFFFFF
        if imm & (1 << 25):
            imm -= 1 << 26
        self.assertEqual(VM_FFI_CALL_SITE + imm * 4, VM_FFI_CALL_STUB)

    def test_gadget_bytes_in_both_builds_and_offsets_table(self):
        offsets_lua = (HERE / "src/bl/offsets.lua").read_text()
        lua = (HERE / "src/bl/ffi_call.lua").read_text()
        for build, table in GADGETS.items():
            for name, off in table.items():
                if name in VARIANTS:          # checked one-of, below
                    self.assertRegex(offsets_lua,
                                     rf"(?m)^\s*{name}\s*=\s*0x{off:x},",
                                     f"{build}/{name} missing from offsets.lua")
                    continue
                expected = bytes.fromhex(SIGNATURES[name])
                if build == "1.0.1f-FULL":
                    self.assertEqual(self.sdk[off:off + len(expected)], expected,
                                     f"{build}/{name}")
                # offsets.lua must name the same number for this build
                self.assertRegex(offsets_lua, rf"(?m)^\s*{name}\s*=\s*0x{off:x},",
                                 f"{build}/{name} missing from offsets.lua")
        # the module preflights exactly these byte strings
        for name, sig in SIGNATURES.items():
            self.assertIn(sig, lua, name)
        # and the recompiled gadgets, as variant lists it checks one-of
        for name, options in VARIANTS.items():
            for sig in options:
                self.assertIn(sig, lua, name)
            off = GADGETS["1.0.1f-FULL"][name]
            got = self.sdk[off:off + len(bytes.fromhex(options[0]))].hex()
            self.assertIn(got, options, f"{name} matches no known variant")
        # exactly one native-call implementation: every module that performs a
        # native call must route through bl/ffi_call.lua, and nothing may
        # carry its own copy of the chain's gadget signatures.
        modules = sorted((HERE / "src/bl").glob("*.lua"))
        owners = [m.name for m in modules
                  if SIGNATURES["fiber_switch"] in m.read_text()]
        self.assertEqual(owners, ["ffi_call.lua"], "chain bytes must live in one module")
        for consumer in ("call.lua", "socket.lua", "app.lua"):
            text = (HERE / "src/bl" / consumer).read_text()
            self.assertNotIn("jffi", text, f"{consumer} must not drive the VM directly")
        # both capture variants share frame 0x30, which the pop-window layout
        # in construct() depends on
        cap = _hexbytes(self.sdk, GADGETS["1.0.1f-FULL"]["fiber_capture"], 0x18)
        self.assertEqual(cap, "c0023fd6600a00f9f44f42a9f65741a9fd7bc3a8c0035fd6")
        self.assertIn("fd7bc3a8", cap)          # ldp x29,x30,[sp],#0x30
        self.assertIn("fd7bc3a8", SIGNATURES["fp_capture"])

    def test_restore_gadget_loads_every_argument_register(self):
        # Decode the restore gadget's loads rather than trusting the comment:
        # every ldp/ldr must cover x0..x7 and d0..d7, plus SP and LR.
        off = GADGETS["1.0.1f-FULL"]["ctx_restore"]
        covered_gp, covered_fp, sp_src, lr_src = set(), set(), None, None
        for i in range(0, len(bytes.fromhex(SIGNATURES["ctx_restore"])), 4):
            w = struct.unpack_from("<I", self.sdk, off + i)[0]
            # ldp Xt1,Xt2,[Xn,#imm]  (opc=10, 1010 0101)
            if (w >> 22) & 0x3FF == 0b1010100101:
                imm7 = (w >> 15) & 0x7F
                t1, t2, n = w & 0x1F, (w >> 10) & 0x1F, (w >> 5) & 0x1F
                if n == 0:
                    covered_gp.update({(t1, imm7 * 8), (t2, imm7 * 8 + 8)})
            # ldp Dt1,Dt2,[Xn,#imm]
            elif (w >> 22) & 0x3FF == 0b0110110101:
                imm7 = (w >> 15) & 0x7F
                t1, t2, n = w & 0x1F, (w >> 10) & 0x1F, (w >> 5) & 0x1F
                if n == 0:
                    covered_fp.update({(t1, imm7 * 8), (t2, imm7 * 8 + 8)})
            # ldr Xt,[Xn,#imm]
            elif (w >> 22) & 0x3FF == 0b1111100101:
                imm12 = (w >> 10) & 0xFFF
                t, n = w & 0x1F, (w >> 5) & 0x1F
                if n == 0:
                    if t == 16:
                        sp_src = imm12 * 8
                    elif t == 30:
                        lr_src = imm12 * 8
        for r in range(8):
            self.assertIn((r, CTX_X(r)), covered_gp, f"x{r} not loaded from ctx+{CTX_X(r):#x}")
            self.assertIn((r, CTX_D(r)), covered_fp, f"d{r} not loaded from ctx+{CTX_D(r):#x}")
        self.assertIn((19, CTX_X(19)), covered_gp)
        self.assertIn((22, CTX_X(22)), covered_gp)
        self.assertIn((8, CTX_X(8)), covered_gp)
        self.assertIn((18, CTX_X(18)), covered_gp)   # platform register preserved
        self.assertEqual(sp_src, CTX["SP"])          # x16 <- ctx+0xf8, then mov sp,x16
        self.assertEqual(lr_src, CTX["LR"])
        self.assertEqual(_hexbytes(self.sdk, off + 0x80, 8), "000440a91f020091")  # ldp x0,x1,[x0]; mov sp,x16
        self.assertEqual(_hexbytes(self.sdk, off + 0x88, 4), "c0035fd6")          # ret


class ConstructionReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("luajit"):
            raise unittest.SkipTest("luajit unavailable")
        p = subprocess.run(["luajit", "-e", DRIVER], cwd=HERE, check=True,
                           capture_output=True, text=True)
        cls.v = {}
        for line in p.stdout.splitlines():
            k, _, val = line.partition("=")
            cls.v[k] = val
        cls.off = GADGETS["1.0.1f-FULL"]

    def num(self, key):
        # LuaJIT prints uint64_t cdata with a ULL suffix.
        return int(self.v[key].rstrip("UL"))

    def test_refusals(self):
        for key, needle in (("refuse.stack_gp", "more than 8 integer"),
                            ("refuse.stack_fp", "more than 8 floating-point"),
                            ("refuse.struct", "unsupported type"),
                            ("refuse.ldouble", "long double"),
                            ("refuse.varargs", "variadic"),
                            ("refuse.argcount", "expects 1 argument")):
            self.assertIn(needle, self.v[key], key)

    def test_decode(self):
        self.assertEqual(self.v["dec.int_neg"], "-5")
        self.assertEqual(self.v["dec.u32"], "4294967294")
        self.assertEqual(self.v["dec.bool0"], "false")
        self.assertEqual(self.v["dec.bool1"], "true")
        self.assertEqual(self.v["dec.u64"], "18446744073709551615ULL")
        self.assertEqual(self.v["dec.double"], "-2.75")
        self.assertEqual(self.v["dec.float"], "1.25")
        self.assertEqual(self.v["dec.ptr"], "true")

    def test_argument_registers_follow_aapcs64(self):
        # int case signature: (int, void*, double, float, uint64_t, double)
        # => GP x0=-7, x1=0x1234, x2=UINT64_MAX ; FP d0=1.5, d1=0.5f, d2=2.25
        self.assertEqual(self.num("int.x0") & 0xFFFFFFFFFFFFFFFF,
                         (-7) & 0xFFFFFFFFFFFFFFFF)
        self.assertEqual(self.num("int.x1"), 0x1234)
        self.assertEqual(self.num("int.x2"), 0xFFFFFFFFFFFFFFFF)
        for r in range(3, 8):
            self.assertEqual(self.num(f"int.x{r}"), 0, f"x{r} must be zeroed")
        self.assertEqual(self.num("int.d0"), struct.unpack("<Q", struct.pack("<d", 1.5))[0])
        # a float argument occupies s_n: low 32 bits of d_n, upper half zero
        self.assertEqual(self.num("int.d1"), struct.unpack("<I", struct.pack("<f", 0.5))[0])
        self.assertEqual(self.num("int.d2"), struct.unpack("<Q", struct.pack("<d", 2.25))[0])
        for r in range(3, 8):
            self.assertEqual(self.num(f"int.d{r}"), 0, f"d{r} must be zeroed")

    def test_int_path_frames(self):
        sdk, ctrl, ctx = self.num("int.sdk"), self.num("int.ctrl"), self.num("int.ctx")
        F, P, S0, Q = (self.num("int.F"), self.num("int.P"),
                       self.num("int.S0"), self.num("int.Q"))
        target = sdk + 0x8E86C
        self.assertEqual(self.v["int.path"], "int")
        self.assertEqual(self.num("int.capture"), sdk + self.off["fiber_capture"])
        # geometry
        self.assertEqual(P - F, 0xF0)
        self.assertEqual(S0, P + 0x50)
        self.assertEqual(Q, S0 + 0x30)
        self.assertEqual(P % 16, 0)
        self.assertEqual(S0 % 16, 0, "the target must be entered 16-byte aligned")
        self.assertEqual(Q % 16, 0)
        # int capture takes its callee from x22 on this build, x8 unused
        self.assertEqual(self.num("int.X22"), target)
        self.assertEqual(self.num("int.X8"), 0)
        self.assertEqual(self.num("int.X19"), ctrl, "x0 is stored at [x19+0x10] = ctrl+RESULT")
        self.assertEqual(self.num("int.ctxSP"), S0)
        self.assertEqual(self.num("int.ctxLR"), sdk + self.off["fiber_capture"])
        # chain wiring
        self.assertEqual(self.num("int.F8"), ctrl)
        self.assertEqual(self.num("int.F96"), sdk + 0x3ABA24)        # F+0x60 x30=pop_gp
        self.assertEqual(self.num("int.P0"), ctx)                    # x0 = &ctx
        self.assertEqual(self.num("int.P72"), sdk + self.off["ctx_restore"])
        self.assertEqual(self.num("int.W8"), sdk + 0x3ABA24)         # pop window x30
        self.assertEqual(self.num("int.Q0"), ctrl + 0x128)
        self.assertEqual(self.num("int.Q8"), ctrl + 0x120)
        self.assertEqual(self.num("int.Q72"), sdk + 0x135CD4)        # fiber_switch
        self.assertEqual(self.num("int.C16"), 0xBADC0FFEE0DDF00D)     # RESULT sentinel
        self.assertEqual(self.num("int.C288"), 0)                    # SAVED cleared
        self.assertEqual(self.num("int.C296"), F)                    # FAKE = F

    def test_fp_path_frames(self):
        sdk, ctrl = self.num("fp.sdk"), self.num("fp.ctrl")
        target = sdk + 0x8E86C
        self.assertEqual(self.v["fp.path"], "fp")
        self.assertEqual(self.num("fp.capture"), sdk + self.off["fp_capture"])
        self.assertEqual(self.num("fp.ctxLR"), sdk + self.off["fp_capture"])
        # fp_capture: x8 -> [x8+0x30] is the callee; d0 lands at [x19]
        self.assertEqual(self.num("fp.X8"), ctrl + 0x180)
        self.assertEqual(self.num("fp.C432"), target)                # ctrl+0x1b0
        self.assertEqual(self.num("fp.X19"), ctrl + 0x10)
        self.assertEqual(self.num("fp.X22"), 0, "the fp path must not set x22")
        # arguments: (double, int)
        self.assertEqual(self.num("fp.d0"), struct.unpack("<Q", struct.pack("<d", 3.5))[0])
        self.assertEqual(self.num("fp.x0"), 9)

    def test_full_chain_replay(self):
        """Replay every transition on the real constructed memory."""
        for case, cap_off, store in (("int", self.off["fiber_capture"], "x0"),
                                     ("fp", self.off["fp_capture"], "d0")):
            sdk, ctrl, ctx = (self.num(f"{case}.sdk"), self.num(f"{case}.ctrl"),
                              self.num(f"{case}.ctx"))
            F, P, S0, Q = (self.num(f"{case}.F"), self.num(f"{case}.P"),
                           self.num(f"{case}.S0"), self.num(f"{case}.Q"))
            pop_gp, switch = sdk + 0x3ABA24, sdk + 0x135CD4
            mem = {}
            for key, val in self.v.items():
                if not key.startswith(case + "."):
                    continue
                tag = key[len(case) + 1:]
                for prefix, base in (("F", F), ("P", P), ("W", S0),
                                     ("Q", Q), ("C", ctrl)):
                    if tag.startswith(prefix) and tag[len(prefix):].isdigit():
                        mem[base + int(tag[len(prefix):])] = self.num(key)
            for n in range(8):
                mem[ctx + CTX_X(n)] = self.num(f"{case}.x{n}")
                mem[ctx + CTX_D(n)] = self.num(f"{case}.d{n}")
            for n in (8, 19, 21, 22, 29):
                mem[ctx + CTX_X(n)] = self.num(f"{case}.X{n}")
            mem[ctx + CTX["SP"]] = self.num(f"{case}.ctxSP")
            mem[ctx + CTX["LR"]] = self.num(f"{case}.ctxLR")

            # --- live launder frame, as BC_FUNCC left it
            S = 0x7000000000
            vm_x19, vm_x20, vm_x29 = 0x1919, 0x2020, 0x2929
            bc_return = 0x7100055654
            mem[S], mem[S + 8], mem[S + 0x10] = vm_x29, bc_return, vm_x19

            # --- launder reads its control fields
            self.assertEqual(mem[ctrl + 0x50], ctrl + 0x120)
            self.assertEqual(mem[ctrl + 0x38], ctrl + 0x128)
            self.assertEqual(mem[ctrl + 0x48], switch)

            # --- first fiber switch: save live frame, pivot to F
            real_sp = S - 0xF0
            mem[real_sp + 8] = ctrl           # x19
            mem[real_sp + 0x10] = vm_x20
            mem[real_sp + 0x58] = S
            mem[real_sp + 0x60] = sdk + 0x7643C
            mem[ctrl + 0x120] = real_sp
            sp = mem[ctrl + 0x128] + 0xF0
            x19, x30 = mem[F + 8], mem[F + 0x60]
            self.assertEqual((sp, x19, x30), (P, ctrl, pop_gp))

            # --- first pop_gp: x0 = &ctx, ret to the context restore gadget
            regs = {i: mem[sp + i * 8] for i in range(8)}
            x30 = mem[sp + 0x48]
            sp += 0x50
            self.assertEqual(regs[0], ctx)
            # x1..x7 must be zero here: the restore gadget overwrites them from
            # ctx, but a stale value must never be able to reach a callee.
            self.assertEqual([regs[i] for i in range(1, 8)], [0] * 7)
            self.assertEqual(x30, sdk + self.off["ctx_restore"])
            self.assertEqual(sp, S0)

            # --- context restore: install the whole argument state
            gp = {n: mem[ctx + CTX_X(n)] for n in list(range(8)) + [8, 19, 21, 22, 29]}
            fpr = {n: mem[ctx + CTX_D(n)] for n in range(8)}
            sp = mem[ctx + CTX["SP"]]
            x30 = mem[ctx + CTX["LR"]]
            self.assertEqual(sp, S0)
            self.assertEqual(sp % 16, 0)
            self.assertEqual(x30, sdk + cap_off)
            # the target is reachable from the registers this gadget installed
            target = sdk + 0x8E86C
            if store == "x0":
                self.assertEqual(gp[22], target)
            else:
                self.assertEqual(mem[gp[8] + 0x30], target)

            # --- capture gadget: call the target, store the raw return
            native_cases = [0, 1, 16, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF]
            for native in native_cases:
                m2 = dict(mem)
                if store == "x0":
                    m2[gp[19] + 0x10] = native       # str x0,[x19,#0x10]
                else:
                    m2[gp[19]] = native              # str d0,[x19]
                    # mov w0,wzr happens before the store; x0 is not captured
                # pop window, both variants: x29/x30 from [sp]/[sp+8], SP+=0x30
                x29, x30 = m2[sp], m2[sp + 8]
                sp2 = sp + 0x30
                self.assertEqual((x29, x30), (F, pop_gp))
                self.assertEqual(sp2, Q)
                self.assertEqual(sp2 % 16, 0)

                # --- second pop_gp: the two fiber slots, then the switch
                x0, x1 = m2[sp2], m2[sp2 + 8]
                x30 = m2[sp2 + 0x48]
                sp3 = sp2 + 0x50
                self.assertEqual((x0, x1, x30),
                                 (ctrl + 0x128, ctrl + 0x120, switch))

                # --- second switch: destructive save over consumed ROP words,
                #     then restore the live SAME-INVOCATION launder frame
                fake_sp = sp3 - 0xF0
                for o in range(0, 0xF0, 8):
                    m2[fake_sp + o] = 0xF00D0000 + o
                self.assertNotEqual(m2[Q + 0x48], switch,
                                    "the switch must have overwritten its own saved return")
                m2[x0] = fake_sp
                self.assertEqual(m2[x1], real_sp)
                restored = {
                    "x19": m2[real_sp + 8], "x20": m2[real_sp + 0x10],
                    "x29": m2[real_sp + 0x58], "x30": m2[real_sp + 0x60],
                }
                sp4 = real_sp + 0xF0
                self.assertEqual(sp4, S)
                self.assertEqual(restored, {"x19": ctrl, "x20": vm_x20,
                                            "x29": S, "x30": sdk + 0x7643C})

                # --- launder epilogue: zero result count, restore VM frame
                m2[ctrl + 0x38] = 0
                vm = (m2[S + 0x10], m2[S], m2[S + 8])
                self.assertEqual(vm, (vm_x19, vm_x29, bc_return))
                captured = m2[gp[19] + (0x10 if store == "x0" else 0)]
                self.assertEqual(captured, native)
                self.assertEqual(m2[ctrl + 0x38], 0)


class MarshallingOracleTests(unittest.TestCase):
    """Compare the marshaller against real ffi on a desktop LuaJIT.

    Desktop LuaJIT has a working lj_vm_ffi_call, so the same calls can be run
    through real ffi and through our register assignment, rebuilding every
    argument from the register bits alone. This tests the half of the bridge
    that is pure logic; it cannot test the gadget chain.
    """

    def test_oracle_matches_real_ffi(self):
        if not shutil.which("luajit"):
            self.skipTest("luajit unavailable")
        p = subprocess.run(["luajit", "test/ffi_call_oracle.lua"], cwd=HERE,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertRegex(p.stdout, r"oracle: \d+ checks, 0 failures")
        checks = int(p.stdout.split("oracle: ")[1].split(" ")[0])
        self.assertGreaterEqual(checks, 15)

    def test_callable_surface_is_a_plain_closure(self):
        if not shutil.which("luajit"):
            self.skipTest("luajit unavailable")
        # declare() must return a Lua closure. It originally returned callable
        # cdata via ffi.metatype, which the shipping build cannot survive: a
        # metatype whose __tostring is a Lua function kills the process on the
        # first tostring(), and a Lua __call on the first invocation; both were
        # isolated on hardware. So assert both the surface and the absence of
        # the fatal construct.
        module = (HERE / "src/bl/ffi_call.lua").read_text()
        code = "\n".join(l for l in module.splitlines()
                         if not l.lstrip().startswith("--"))
        # The callable surface must install no metamethods. One ffi.metatype
        # call is allowed: M.metatype, the wrapper that refuses every shape
        # that would reach lj_meta_tailcall (and thus ->cont_dispatch's
        # unguarded `br x0`).
        self.assertEqual(code.count("ffi.metatype("), 1)
        self.assertNotIn("ffi.cdef", code)
        declare = code[code.index("function M.declare"):]
        self.assertNotIn("metatype", declare[:declare.index("\nend")])
        driver = r'''
package.path = "src/?.lua;" .. package.path
local ffi = require("ffi")
local fc = require("bl.ffi_call")
local off = require("bl.offsets")["1.0.1f-FULL"].sdk
local buf = ffi.new("uint8_t[?]", 0x600000)
local info = { sdk_base = tonumber(ffi.cast("uintptr_t", buf)), off = off }
local fn, plan = fc.declare(ffi, nil, info, "double", {"double","double"}, 0x1234)
print("type\t" .. type(fn))
print("path\t" .. plan.ret.path)
print("describe\t" .. tostring(fc.describe(fn)))
local ok, err = pcall(fn, 2, 10)
print("raised\t" .. tostring(not ok))
print("err\t" .. tostring(err))
'''
        p = subprocess.run(["luajit", "-e", driver], cwd=HERE, check=True,
                           capture_output=True, text=True)
        out = dict(line.split("\t", 1) for line in p.stdout.splitlines())
        self.assertEqual(out["type"], "function")
        self.assertEqual(out["path"], "fp")
        self.assertEqual(out["describe"], "native<0x1234>(double,double)->double")
        # A bad image must surface as a Lua error from the preflight, never as
        # a transfer of control.
        self.assertEqual(out["raised"], "true")
        self.assertIn("wrong SDK bytes", out["err"])


if __name__ == "__main__":
    unittest.main()
