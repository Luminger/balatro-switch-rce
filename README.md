# Balatro Switch RCE

Userland code execution on the Nintendo Switch 1 and 2, targeting the **Balatro
cartridge for Switch 1**: a payload delivered **entirely inside save
data** that completely replaces the game with a networked Lua REPL and an
FTP server. No cartridge or romfs modification, no title update, no CFW
on the target console: the save is installed with an ordinary save
manager (or arrives through Nintendo's own official save transfer) and
the title boots straight into the launcher instead of Balatro. The same
cartridge also runs on the **Switch 2** in compatibility mode, where the
same save completely replaces the game there as well.

![Launcher status screen after the network came up](docs/screenshot.png)

## What this is

- **A proof of concept, not a product.** It demonstrates that a Switch
  title's savedata can shadow its executable's own LÖVE entry points, and
  that a save alone is enough to run attacker-authored code inside the
  game's process.
- **Userland only.** Everything runs inside the title's own process: no
  kernel, no sysmodule, no backup loading, no piracy. It does not bypass
  Nintendo's DRM and cannot run commercial games.
- **A research and instrumentation tool.** What you get on a supported
  console is an on-screen status console, a Lua REPL reachable over TCP
  (`rpc.py`, port 9026) and an FTP server for the launcher's own files
  (ports 5000/5001), enough to inspect, script and re-stage the title
  from your PC without re-flashing a save.
- **Verified on hardware**: tested with the Balatro **physical cartridge
  for Switch 1** on both a Switch 1 and a Switch 2 (after Nintendo's
  official save transfer),
  at both the patch level the cartridge ships and the latest Balatro
  patch.
- **Written for exact images**: the Switch 1 edition at the cartridge's
  stock patch level (**1.0.1f**) and at the latest patch (**1.0.1o**);
  see `src/bl/offsets.lua`.

Using this software may violate Nintendo's terms of service and can get a
console banned. Run it on hardware you own and accept the risk yourself.

## Why this works

Balatro on the Switch is a [LÖVE](https://love2d.org/) game: the retail
executable is a LÖVE runtime that loads `conf.lua` and `main.lua` from
romfs. LÖVE's `love.filesystem` mounts the **savedata ahead of romfs**, so
identically-named files in savedata shadow their romfs counterparts. A
save that carries `.lovegame/conf.lua`, `.lovegame/main.lua` and
`.lovegame/bl/*.lua` therefore replaces the game's own entry points: the
title boots straight into a standalone launcher instead of Balatro. The
save is written with an ordinary save manager (JKSV) on a hacked console,
or on Switch 2 it simply arrives with the official transfer, which moves
the save verbatim.

## What you get

- A full-screen status console painted on the very first frame (build
  id, per-file hashes, boot/network events) before any fingerprinting or
  SDK initialization.
- **RPC**: evaluate Lua in the title's process,
  `python3 rpc.py <console-ip> 'return 2+2'`.
- **FTP**: read/replace the launcher's own files (`conf.lua`, `main.lua`,
  `bl/*.lua`, `workers/*.lua`), so the launcher re-stages itself without a
  save restore.
- An append-only savedata log of every RPC/FTP peer, command and transfer
  (passwords are never logged), a phase breadcrumb that survives aborts,
  and socket rebind recovery after sleep/wake.

## Building

Enter the development shell and build:

```sh
nix develop -c python3 build.py -o BL-new.zip
```

Each build validates syntax, Lua/Python tests and the runtime file
fingerprint, and writes a manifest next to the archive. The archive
contains no game profiles or settings: only launcher files, the bundled
font license, and generated JKSV metadata with a **zero account UID**;
no personal data is embedded or consulted.

Status-screen renditions like the one at the top are reproducible with
`nix develop -c python3 tools/screenshot.py`.

## Installing on a hacked Switch 1

Copy the built zip to the console's `JKSV/Balatro/` folder on the SD card,
then restore it from JKSV. **The restore deletes the current Balatro
save**: the launcher is a standalone console, not a mod layered on top of
gameplay. Launch the title; the status screen comes up with the RPC/FTP
addresses once the network is ready.

## Getting the save onto a Switch 2

The Switch 2 runs the Switch 1 Balatro edition in backward-compatibility
mode, and Nintendo's own console-to-console transfer carries save data
across verbatim: the launcher files ride along inside the save. No CFW or
other modification is needed on the Switch 2 itself.

1. On the hacked **Switch 1**, restore the built launcher save with JKSV
   (this replaces the Balatro save there).
2. Transfer the save to the **Switch 2** using Nintendo's official path:
   either the full system transfer or the per-game **Save Data Transfer**
   from the Switch 2's system settings.
3. On the Switch 2, launch Balatro (the Switch 1 edition, the physical
   cartridge). The shadowed
   `conf.lua`/`main.lua` load from savedata, the fail-closed image checks
   pass in compatibility mode, and the launcher comes up. Verify the
   status row and `python3 rpc.py <console-ip> 'return 2+2'`.

A separately released **native Switch 2 Balatro** binary is a different
image and cannot inherit these Switch 1 gadget offsets; the resolver fails
closed on it.

## Live use

The status bar shows the address of each service, for example
`RPC 192.168.1.50:9026    FTP 192.168.1.50:5000`. The RPC and FTP
services are unauthenticated and unencrypted, by choice.

```sh
python3 rpc.py <console-ip> 'return 2+2'
curl --disable-epsv ftp://<console-ip>:5000/bl_log.txt
curl --disable-epsv -T local.lua ftp://<console-ip>:5000/bl/local.lua
```

Use RPC to inspect a newly uploaded Lua file immediately, or relaunch the
title to load replacements for already-required modules.

If Wi-Fi is not ready, the screen stays responsive and network setup
continues when an address arrives; a long update gap or repeated listener
errors trigger a socket rebind after sleep/wake (that path has offline
tests but still needs a real suspend/resume check). Startup failures show
`ERROR` and their reason, not a false listening claim.

A broken savedata shadow can be recovered with a known-good JKSV restore
or an external save manager; there is no in-app kill switch.

## Legal

Code: **GPL-3.0** (see `LICENSE`). The bundled JetBrains Mono subset in
`src/bl/assets/` is under the SIL Open Font License 1.1 (`OFL.txt`), which
also ships inside every built save archive.

"Balatro" and "Nintendo Switch" are trademarks of their respective owners;
this project is not affiliated with or endorsed by them. This is a proof
of concept for consoles you own. The authors take no responsibility for
what you do with it.
