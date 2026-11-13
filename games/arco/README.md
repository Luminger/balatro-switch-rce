# Arco launcher

Launcher sources for Arco (`0100E6601ACB6000`). The exploit vector is the
same LÖVE savedata-shadow trick that boots Balatro into the RPC/FTP
launcher from `../../src`: `love.filesystem.setIdentity(..., false)`
mounts the save directory ahead of romfs, so a `main.lua` placed there
replaces the cart's own. Only `main.lua` is shadowed because `conf.lua`
is loaded before the save is mounted. The JankFFI gadget chain, BC_FUNCC
hijack, module-base resolver and FTP/RPC servers are direct adaptations
of the Balatro launcher. Arco's shipped nnSdk is byte-identical to
Balatro 1.0.1f's, so every SDK gadget offset in `src/ar/ffi_call.lua`
matches at the same address the Balatro work recorded (verified by
re-running the signature scan against the Arco sdk NSO).

## Source

Ported from
[figurophobia/arco-switch-rce](https://github.com/figurophobia/arco-switch-rce).
The Lua tree under `src/ar/` is vendored verbatim from that repository
so `build.py --game arco` can produce a ready-to-install JKSV archive
from this repo alone.

## Verified builds

| Game version       | Title ID            | `present`  | `got_memcpy` | SDK module             |
| ------------------ | ------------------- | ---------- | ------------ | ---------------------- |
| v0 Base            | `0100E6601ACB6000`  | `0x2cb800` | `0x550c18`   | 14.3.1.0 (== Balatro)  |
| v1.2.0 Update      | `0100E6601ACB6800`  | `0x2cb800` | `0x550c18`   | 14.3.1.0 (byte-equal)  |

Both builds boot from the same archive; the base and the v1.2.0 update
ship byte-identical `main` and `sdk` NSOs, so one offset profile
(`arco-v0+v1.2.0`) covers both and the launcher confirms the match at
boot by signature.

Verified on hardware on both Switch 1 and Switch 2 (compatibility mode).

## Build

```sh
python3 build.py --game arco -o Arco-new.zip
```

The output is a JKSV archive carrying `.arco/main.lua` plus the launcher
modules under `.arco/ar/`, with a generated `.nx_save_meta.bin` for
`0100E6601ACB6000` (4 MiB data / 1 MiB journal, as observed on a vanilla
Arco save) and a zero account UID. Copy it to `JKSV/Arco/` on the SD
card and restore. The restore wipes the current Arco save.
