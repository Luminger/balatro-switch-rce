# Gravity Circuit launcher

Launcher sources for Gravity Circuit (`01008D9019128000`). The exploit
vector is the same LÖVE savedata-shadow trick that boots Balatro into the
RPC/FTP launcher from `../../src`: `love.filesystem.setIdentity(..., false)`
mounts the save directory ahead of romfs, so a `main.lua` placed there
replaces the cart's own. Only `main.lua` is shadowed because `conf.lua` is
loaded before the save is mounted. The JankFFI gadget chain, BC_FUNCC
hijack, module-base resolver and FTP/RPC servers are direct adaptations
of the Balatro launcher; the SDK version (14.3.1.0) matches but the main
module's `present` and `got_memcpy` offsets differ, so `src/gc/offsets.lua`
carries one profile per supported game build and `resolve.lua` picks the
right one at boot by matching the code signature of
`love.graphics.present`.

## Source

Ported from
[figurophobia/GravCirc-Switch-rce](https://github.com/figurophobia/GravCirc-Switch-rce).
The Lua tree under `src/gc/` is vendored verbatim from that repository so
`build.py --game gravcirc` can produce a ready-to-install JKSV archive
from this repo alone.

## Verified builds

| Game version | Title version | `present`  | `got_memcpy` | SDK module             |
| ------------ | ------------- | ---------- | ------------ | ---------------------- |
| 1.0.0        | v0            | `0x239360` | `0x51a6e8`   | 14.3.1.0               |
| 1.2.1        | v655360       | `0x289c40` | `0x54d9e0`   | 14.3.1.0 (byte-equal)  |

Both builds boot from the same archive; the launcher picks the matching
offset profile at runtime. Adding a new update only needs a new profile in
`src/gc/offsets.lua`.

## Build

```sh
python3 build.py --game gravcirc -o GC-new.zip
```

The output is a JKSV archive carrying `.Gravity Circuit/main.lua` plus the
launcher modules under `.Gravity Circuit/gc/`, with a generated
`.nx_save_meta.bin` for `01008D9019128000` and a zero account UID. Copy it
to `JKSV/Gravity Circuit/` on the SD card and restore. The restore wipes
the current Gravity Circuit save.
