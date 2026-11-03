"""Offline construction gate for the SDK fiber-switch native-call path.

Replays Lua's actual frame bytes through the verified register/SP
transitions. It does NOT claim hardware success: only an opt-in benign
scalar test can graduate the candidate.
"""
from __future__ import annotations

import pathlib
import shutil
import subprocess
import unittest

HERE = pathlib.Path(__file__).resolve().parents[1]
OFFSETS = {
    "fiber_switch": 0x135CD4,
    "fiber_pop_gp": 0x3ABA24,
    "fiber_capture": 0x32D3C,
    "launder": 0x76410,
    "thunk_ptr": 0x8B1AC,
}

# Dump the ACTUAL Lua constructor's memory before its buffers are freed.
DRIVER = r'''
package.path = "src/?.lua;" .. package.path
local ffi = require("ffi")
local call = require("bl.fiber_call")
local off = require("bl.offsets")["1.0.1f-FULL"].sdk
local sdk_buf = ffi.new("uint8_t[?]", off.fiber_capture + 8)
local sdk = tonumber(ffi.cast("uintptr_t", sdk_buf))
ffi.cast("uint32_t*", ffi.cast("uintptr_t", sdk + off.fiber_capture))[0] = 0xd63f02c0
local state = call.construct(ffi, {sdk_base=sdk,off=off}, sdk+0x8e86c,
                             {2,1,6,7,8,9,10,11})
local C,F,P,L = state.ctrl.addr,state.fake_frame,state.fake_sp,call.layout
local function rd(addr)
  return tonumber(ffi.cast("uint64_t*", ffi.cast("uintptr_t", addr))[0])
end
local function dump(tag, ...)
  local words = {...}
  for i=1,#words do words[i] = string.format("%.0f",words[i]) end
  print(tag, unpack(words))
end
dump("bases", C, F, P)
dump("sdk", sdk)
for _,o in ipairs({0,8,0x10,0x20,0x58,0x60}) do dump("F",o,rd(F+o)) end
for o=0,0xc8,8 do dump("P",o,rd(P+o)) end
for _,o in ipairs({0,0x10,0x38,0x48,0x50,0x98,0x120,0x128}) do
 dump("C",o,rd(C+o))
end
'''


class FiberChainTests(unittest.TestCase):
    def test_same_invocation_sp_and_scalar_capture_from_lua_frame(self):
        if not shutil.which("luajit"):
            self.skipTest("luajit unavailable")
        p = subprocess.run(["luajit", "-e", DRIVER], cwd=HERE, check=True,
                           capture_output=True, text=True)
        mem = {}
        C = F = P = sdk = None
        for line in p.stdout.splitlines():
            tag, *rest = line.split()
            if tag == "bases":
                C, F, P = map(int, rest)
            elif tag == "sdk":
                sdk = int(rest[0])
            else:
                offset, value = map(int, rest)
                mem[{"F": F, "P": P, "C": C}[tag] + offset] = value
        self.assertIsNotNone(C)
        self.assertIsNotNone(sdk)
        self.assertEqual(F + 0xF0, P)
        self.assertEqual(P % 16, 0)
        target = sdk + 0x8E86C  # mov w0,#16; ret; only an offline target
        self.assertEqual(mem[F + 8], C)        # fake x19
        # With blr x22 capture, target is in fiber frame x22 slot
        self.assertEqual(mem[F + 0x20], target) # fake x22
        self.assertEqual(mem[F + 0x60], sdk + OFFSETS["fiber_pop_gp"])
        self.assertEqual([mem[P + i * 8] for i in range(8)],
                         [2, 1, 6, 7, 8, 9, 10, 11])

        # The model uses the actual Lua-produced frame words above. Replay
        # EVERY switch save/pivot/restore, including the destructive second
        # save over the already-consumed fake ROP words.
        initial = dict(mem)
        S = 0x7000000000  # CURRENT launder SP; not a previous call's SP
        vm_x19, vm_x20, vm_x29 = 0x1919, 0x2020, 0x2929
        bc_return = 0x7100055654
        for native_result in (0, 16, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF):
            mem = dict(initial)
            mem[S], mem[S + 8], mem[S + 0x10] = vm_x29, bc_return, vm_x19
            self.assertEqual(mem[C + 0x50], C + 0x120)
            self.assertEqual(mem[C + 0x38], C + 0x128)
            self.assertEqual(mem[C + 0x48], sdk + OFFSETS["fiber_switch"])
            self.assertEqual(mem[C + 0x120], 0)
            self.assertEqual(mem[C + 0x128], F)

            # First switch: sub SP,0xf0; save x19..x30 and q8..q15 into
            # the LIVE launder stack, write its SP to [x0].
            real_sp = S - 0xF0
            saved_gp = [C, vm_x20, 0x2121, target, 0x2323,
                        0x2424, 0x2525, 0x2626, 0x2727,
                        0x2828, S, sdk + 0x7643C]
            mem[real_sp], mem[real_sp + 8] = 0, saved_gp[0]
            for i in range(1, 11):
                mem[real_sp + 8 * (i + 1)] = saved_gp[i]
            mem[real_sp + 0x60] = saved_gp[11]
            for off in range(0x70, 0xF0, 8):
                mem[real_sp + off] = 0x51000000 + off  # q8..q15 halves
            mem[C + 0x120] = real_sp
            # Pivot to F, restore x19/x22/x30, add SP,0xf0, ret to pop.
            sp, x19, x22, x30 = mem[C + 0x128] + 0xF0, mem[F + 8], mem[F + 0x20], mem[F + 0x60]
            self.assertEqual((sp, x19, x22, x30),
                             (P, C, target, sdk + OFFSETS["fiber_pop_gp"]))

            # First pop_gp loads x0..x7; capture BLRs x22 at aligned SP.
            self.assertEqual([mem[sp + i * 8] for i in range(8)],
                             [2, 1, 6, 7, 8, 9, 10, 11])
            self.assertEqual(mem[sp + 0x48], sdk + OFFSETS["fiber_capture"])
            sp += 0x50
            self.assertEqual(sp % 16, 0)
            mem[x19 + 0x10] = native_result  # full-width str x0,[x19,#0x10]
            x22, x21 = mem[sp + 0x10], mem[sp + 0x18]
            x20, x19 = mem[sp + 0x20], mem[sp + 0x28]
            x29, x30 = mem[sp], mem[sp + 8]
            sp += 0x30
            self.assertEqual((sp, x30), (P + 0x80, sdk + OFFSETS["fiber_pop_gp"]))

            # Second pop_gp loads &fake_slot,&saved_slot BEFORE returning
            # to the switch. This timing matters: its saved return at P+0xc8
            # is about to be overwritten by the switch's q15 store.
            x0, x1 = mem[sp], mem[sp + 8]
            x29, x30 = mem[sp + 0x40], mem[sp + 0x48]
            sp += 0x50
            self.assertEqual((x0, x1, x30, sp),
                             (C + 0x128, C + 0x120,
                              sdk + OFFSETS["fiber_switch"], P + 0xD0))
            # Second switch: sub SP,0xf0, save fake frame over the consumed
            # ROP data, then read saved_slot and pivot to the LIVE frame.
            fake_sp = sp - 0xF0
            for off in range(0, 0xF0, 8):
                mem[fake_sp + off] = 0xF00D0000 + off
            self.assertNotEqual(mem[P + 0xC8], sdk + OFFSETS["fiber_switch"])
            mem[x0] = fake_sp
            real_restore = mem[x1]
            self.assertEqual(real_restore, real_sp)
            restored_x19 = mem[real_restore + 8]
            restored_x20 = mem[real_restore + 0x10]
            restored_x29 = mem[real_restore + 0x58]
            restored_x30 = mem[real_restore + 0x60]
            restored_q = [mem[real_restore + off] for off in range(0x70,0xF0,8)]
            sp = real_restore + 0xF0
            self.assertEqual((sp, restored_x19, restored_x20, restored_x29, restored_x30),
                             (S, C, vm_x20, S, sdk + 0x7643C))
            self.assertEqual(restored_q, [0x51000000 + off for off in range(0x70,0xF0,8)])
            # Launder success epilogue clears x1 slot, zeros x0, restores
            # original VM x19/x29/x30 from its CURRENT stack and returns.
            mem[C + 0x38] = 0
            x19, x29, x30 = mem[S + 0x10], mem[S], mem[S + 8]
            sp += 0x20
            self.assertEqual((sp, x19, x29, x30, mem[C + 0x10], mem[C + 0x38]),
                             (S + 0x20, vm_x19, vm_x29, bc_return, native_result, 0))


if __name__ == "__main__":
    unittest.main()
