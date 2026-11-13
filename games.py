"""Supported-game registry.

Each entry describes everything build.py needs to produce a JKSV savegame
archive for a given LÖVE-on-Switch target: the Nintendo application id and
save sizes written into JKSV metadata, the save-identity directory that
shadows the romfs tree, which files go into the archive, and which per-build
sanity checks the launcher's source supports (the Balatro tree ships an
on-console fingerprint computed by `bl/stamp.lua`; third-party ports need
not). Add a new dict here and `build.py --game <name>` picks it up.

To add a game: vendor its launcher sources under `games/<name>/src/`, pick
an identity string, record the application id and save/journal sizes from
`ns_applet.NS_ApplicationControlData`, and declare which subdirectories and
extensions ship. The root files (`top_level`) are the entry points the
title loads first (conf.lua and/or main.lua); everything else is collected
from `collect` ((subdir, extensions) tuples). Set `fingerprint=True` only
if the sources include a `stamp.lua` whose TRACKED list matches the
archive's tracked extensions; the cross-check is how build.py proves that
the on-console identity will read back the same value.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent


@dataclass(frozen=True)
class Game:
    id: str
    display_name: str
    jksv_folder: str            # name of the folder under JKSV/ on the SD card
    identity: str               # love.filesystem save identity, prefix inside the zip
    app_id: int                 # Nintendo application id (titleID)
    save_size: int              # bytes, from applet control data
    journal_size: int           # bytes, from applet control data
    src: Path                   # launcher source tree root
    # Entry-point files shipped at identity/ root, mapping the identity-relative
    # destination to the src-relative source so a launcher whose main.lua lives
    # in a subdir (e.g. "gc/main.lua") can still shadow the title's romfs
    # main.lua.
    top_level: tuple[tuple[str, str], ...]
    # (subdir-relative-to-src, tuple of suffixes to include)
    collect: tuple[tuple[str, tuple[str, ...]], ...]
    # Shipped-but-not-fingerprinted files (relative-path -> source path).
    license_files: dict[str, Path] = field(default_factory=dict)
    fingerprint: bool = False   # run stamp.lua cross-check of the FNV-1a identity
    tests: bool = False         # run test/run.lua and test/test_*.py before packing


GAMES: dict[str, Game] = {
    "balatro": Game(
        id="balatro",
        display_name="Balatro",
        jksv_folder="Balatro",
        identity=".lovegame",
        app_id=0x0100CD801CE5E000,
        save_size=16 * 1024 * 1024,
        journal_size=16 * 1024 * 1024,
        src=HERE / "src",
        top_level=(("conf.lua", "conf.lua"), ("main.lua", "main.lua")),
        collect=(
            ("bl", (".lua",)),
            ("workers", (".lua",)),
            ("bl/assets", (".ttf",)),
        ),
        license_files={
            "bl/assets/OFL.txt": HERE / "src" / "bl" / "assets" / "OFL.txt",
        },
        fingerprint=True,
        tests=True,
    ),
    "gravcirc": Game(
        id="gravcirc",
        display_name="Gravity Circuit",
        jksv_folder="Gravity Circuit",
        identity=".Gravity Circuit",
        app_id=0x01008D9019128000,
        save_size=16 * 1024 * 1024,
        journal_size=16 * 1024 * 1024,
        src=HERE / "games" / "gravcirc" / "src",
        top_level=(("main.lua", "gc/main.lua"),),
        collect=(
            ("gc", (".lua",)),
        ),
        license_files={},
        fingerprint=False,
        tests=False,
    ),
    "arco": Game(
        id="arco",
        display_name="Arco",
        jksv_folder="Arco",
        identity=".arco",
        app_id=0x0100E6601ACB6000,
        save_size=4 * 1024 * 1024,
        journal_size=1 * 1024 * 1024,
        src=HERE / "games" / "arco" / "src",
        top_level=(("main.lua", "ar/main.lua"),),
        collect=(
            ("ar", (".lua",)),
        ),
        license_files={},
        fingerprint=False,
        tests=False,
    ),
}


def get(name: str) -> Game:
    try:
        return GAMES[name]
    except KeyError as e:
        raise SystemExit(
            f"unknown --game {name!r}; choose from: {', '.join(sorted(GAMES))}"
        ) from e
