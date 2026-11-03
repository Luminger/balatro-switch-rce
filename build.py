#!/usr/bin/env python3
"""Build the Balatro launcher savegame archive for a JKSV restore.

One entry point. There is exactly one install flow:

    .lovegame/conf.lua          shadows the cart's conf.lua -> requires bl.app
    .lovegame/main.lua          shadows the cart's main.lua -> Balatro skipped
    .lovegame/bl/*.lua          guarded native-call layer (no automatic SDK calls)

That works because love.filesystem resolves savedata ahead of the romfs game
source, which was proven on hardware:

    require(savedata)=SHADOWED-FROM-SAVEDATA  path=?.lua;?/init.lua
    read-precedence: savedata WINS romfs

JKSV metadata is generated from the documented packed struct, with a zero
account UID, for an existing selected Balatro save. No exported ZIP, personal
profile or game .jkr files are needed. JKSV WIPES the existing save on
restore; Balatro progress is intentionally not retained by this launcher.

Usage:
  build.py -o work/BL-new.zip
"""
from __future__ import annotations

import argparse
import jksv_meta
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"
IDENTITY = ".lovegame"
META = ".nx_save_meta.bin"
# Shipped but not fingerprinted: the font license must accompany the bundled
# subset, but it is not Lua/asset code and stays out of stamp.lua's identity.
LICENSE_FILES = {"bl/assets/OFL.txt": SRC / "bl" / "assets" / "OFL.txt"}


def luajit() -> str | None:
    return shutil.which("luajit")


def syntax_check(files: list[Path]) -> None:
    lj = luajit()
    if not lj:
        print("warn: luajit not on PATH, skipping syntax checks", file=sys.stderr)
        return
    # Bundled assets are shipped verbatim; only Lua is parsed.
    files = [f for f in files if f.suffix == ".lua"]
    for f in files:
        p = subprocess.run([lj, "-bl", str(f), "/dev/null"], capture_output=True, text=True)
        if p.returncode != 0:
            raise SystemExit(f"syntax error in {f}:\n{p.stderr.strip()}")
    print(f"  syntax ok: {len(files)} lua files")


def run_tests() -> None:
    lj = luajit()
    if lj:
        p = subprocess.run([lj, "test/run.lua"], cwd=HERE, capture_output=True, text=True)
        tail = (p.stdout or "").strip().splitlines()[-1:] or ["(no output)"]
        print(f"  tests: {tail[0]}")
        if p.returncode != 0:
            raise SystemExit("tests failed; refusing to build\n" + p.stdout)
    p = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "test", "-p", "test_*.py"],
                       cwd=HERE, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("metadata tests failed; refusing to build\n" + p.stdout + p.stderr)
    print("  metadata tests: passed")


FNV_PRIME, FNV_OFFSET = 16777619, 2166136261


def fnv1a(h: int, data: bytes) -> int:
    for b in data:
        h ^= b
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h


def fingerprint(files: dict[str, Path]) -> tuple[str, int, int, list[tuple[str, str, int]]]:
    """The same FNV-1a over "path\\0contents" that src/bl/stamp.lua computes.

    Implicit by construction: derived from the bytes themselves, so nothing
    needs bumping, nothing depends on git, and the value printed here is the
    value the console will log.
    """
    h, total, manifest = FNV_OFFSET, 0, []
    for rel in sorted(files):
        # Must mirror TRACKED in src/bl/stamp.lua exactly, or the runtime
        # fingerprint and this one silently disagree.
        if not rel.endswith((".lua", ".ttf")):
            continue
        data = files[rel].read_bytes()
        h = fnv1a(fnv1a(fnv1a(h, rel.encode()), b"\0"), data)
        total += len(data)
        manifest.append((rel, f"{fnv1a(fnv1a(FNV_OFFSET, rel.encode()), data):08x}", len(data)))
    return f"{h:08x}", len(manifest), total, manifest


def crosscheck(files: dict[str, Path], expect: str) -> None:
    """Run stamp.lua over the same files and require the same answer.

    Two implementations of one hash drift silently, and the failure mode is a
    log that misidentifies its own build - so it is verified every build. The
    driver reads the files from disk rather than embedding them, because
    embedding Lua sources inside a Lua literal is both huge and ambiguous
    ("[[[" starts a long string, not a table key).
    """
    lj = luajit()
    if not lj:
        return
    rels = sorted(r for r in files if r.endswith((".lua", ".ttf")))
    listing = ", ".join('"%s"' % r for r in rels)
    driver = f"""
package.path = "src/?.lua;" .. package.path
local paths = {{{listing}}}
local function slurp(p)
    local fh = io.open("src/" .. p, "rb")
    if not fh then return nil end
    local d = fh:read("*a"); fh:close(); return d
end
local function known(p)
    for _, q in ipairs(paths) do if q == p then return true end end
    return false
end
love = {{ filesystem = {{
    getDirectoryItems = function(dir)
        local out = {{}}
        for _, p in ipairs(paths) do
            local d, name = p:match("^(.*)/([^/]+)$")
            if (d or "") == dir then out[#out + 1] = name or p end
        end
        table.sort(out)
        return out
    end,
    getInfo = function(p) return known(p) and {{ size = 0 }} or nil end,
    read = slurp,
}} }}
local id = require("bl.stamp").compute()
io.write(id)
"""
    proc = subprocess.run([lj, "-e", driver], capture_output=True, text=True, cwd=HERE)
    got = (proc.stdout or "").strip()
    if proc.returncode != 0 or got != expect:
        raise SystemExit(
            f"fingerprint mismatch: python={expect} lua={got!r}\n{proc.stderr.strip()}")
    print(f"  fingerprint cross-checked against stamp.lua: {expect}")


def collect() -> dict[str, Path]:
    """savedata-relative path -> source file."""
    out = {"conf.lua": SRC / "conf.lua", "main.lua": SRC / "main.lua"}
    for sub in ("bl", "workers", "bl/assets"):
        # Assets are part of the identity: see TRACKED in bl/stamp.lua, which
        # must enumerate exactly these suffixes for the cross-check to agree.
        for pattern in ("*.lua", "*.ttf"):
            for f in sorted((SRC / sub).glob(pattern)):
                out[f"{sub}/{f.name}"] = f
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", required=True, type=Path)
    args = ap.parse_args()

    files = collect()
    bid, nfiles, nbytes, manifest = fingerprint(files)
    print(f"== build {bid} ({nfiles} lua files, {nbytes}B)")
    for rel, fh, size in manifest:
        print(f"     {fh[:6]}  {size:6d}  {rel}")
    print("== validate")
    syntax_check(sorted(set(files.values())))
    crosscheck(files, bid)
    run_tests()

    print("== pack")
    metadata = jksv_meta.encode()
    decoded = jksv_meta.decode(metadata)
    if decoded["application_id"] != f"{jksv_meta.APP_ID:016x}" or decoded["account_uid"] != "00" * 16:
        raise SystemExit("JKSV metadata identity/privacy self-check failed")
    entries = {META, *(f"{IDENTITY}/{n}" for n in files),
               *(f"{IDENTITY}/{n}" for n in LICENSE_FILES)}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    man = args.out.with_suffix(".manifest.txt")
    if args.out.exists() or man.exists():
        raise SystemExit(f"refusing to overwrite {args.out} or {man}; use a new name")
    with args.out.open("xb") as output:
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as dst:
            dst.writestr(META, metadata)
            for rel, path in files.items():
                dst.writestr(f"{IDENTITY}/{rel}", path.read_bytes())
            for rel, path in LICENSE_FILES.items():
                dst.writestr(f"{IDENTITY}/{rel}", path.read_bytes())
    with zipfile.ZipFile(args.out) as check:
        if set(check.namelist()) != entries or len(check.namelist()) != len(entries):
            raise SystemExit("packed archive has an unexpected or duplicate member")
        if check.read(META) != metadata:
            raise SystemExit("packed archive modified generated metadata")
        if any(check.read(f"{IDENTITY}/{rel}") != path.read_bytes()
               for rel, path in files.items()):
            raise SystemExit("packed launcher differs from tested source")
        if any(check.read(f"{IDENTITY}/{rel}") != path.read_bytes()
               for rel, path in LICENSE_FILES.items()):
            raise SystemExit("packed license file differs from source")

    # The manifest lands next to the zip, so a pulled log's per-file hashes
    # can be matched against the exact tree that produced it.
    man.write_text(f"build {bid}  {nfiles} files  {nbytes}B\n" +
                   "".join(f"{fh}  {size:7d}  {rel}\n" for rel, fh, size in manifest))
    print(f"  manifest -> {man}")

    print(f"  {args.out}: {args.out.stat().st_size}B - standalone (Balatro skipped)")
    print(f"  generated JKSV {len(metadata)}-byte metadata; NO game saves/account UID")
    print("  WARNING: JKSV restore wipes Balatro progress (standalone launcher only)")
    for rel, path in files.items():
        print(f"    + {IDENTITY}/{rel} ({path.stat().st_size}B)")
    for rel, path in LICENSE_FILES.items():
        print(f"    + {IDENTITY}/{rel} ({path.stat().st_size}B)")
    print("  next: copy the zip to the console's JKSV/Balatro folder and restore it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
