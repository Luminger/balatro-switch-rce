"""Generate JKSV rewrite's packed 86-byte .nx_save_meta.bin (revision 1).

Exact schema: https://github.com/J-D-K/JKSV/blob/rewrite/include/fs/SaveMetaData.hpp
For an EXISTING selected user save, JKSV restore reads only data_size and
journal_size from this struct; it does not read or use AccountUid:
https://github.com/J-D-K/JKSV/blob/rewrite/source/fs/SaveMetaData.cpp

The account UID is ZERO, no personal profile is consulted. This does not
create a new save and is not appropriate for importing into a different user.
JKSV WIPEs the target save before restoring, which is intentional here: the
launcher shadows main.lua and does not need the game's profile/settings files.

The module-level APP_ID/SAVE_SIZE/JOURNAL_SIZE constants retain Balatro's
values for backward compatibility with callers and tests that imported them
before multi-game support; pass the app_id/save_size/journal_size keywords
to target a different game.
"""
from __future__ import annotations

import struct
import time

FORMAT = "<4sBQ16sQBBHQQIqqQB"
SIZE = struct.calcsize(FORMAT)
assert SIZE == 86
APP_ID = 0x0100CD801CE5E000
SAVE_SIZE = 16 * 1024 * 1024
JOURNAL_SIZE = 16 * 1024 * 1024


def encode(*, timestamp: int | None = None, app_id: int = APP_ID,
           save_size: int = SAVE_SIZE, journal_size: int = JOURNAL_SIZE) -> bytes:
    """Build privacy-safe metadata without reading any backup or user config."""
    if timestamp is None:
        timestamp = int(time.time())
    # JKSV: magic, revision, app id, AccountUid, system id, type, rank,
    # index, owner, time, flags, data size, journal size, commit, space.
    data = struct.pack(FORMAT, b"JKSV", 1, app_id, bytes(16),
                       0, 1, 0, 0, app_id, timestamp, 0,
                       save_size, journal_size, 0, 1)
    assert len(data) == SIZE
    return data


def decode(data: bytes) -> dict:
    if len(data) != SIZE:
        raise ValueError("wrong JKSV metadata size")
    magic, revision, app, uid, system, save_type, rank, index, owner, stamp, flags, size, journal, commit, space = struct.unpack(FORMAT, data)
    if magic != b"JKSV" or revision != 1:
        raise ValueError("unexpected JKSV metadata magic/revision")
    return dict(application_id=f"{app:016x}", account_uid=uid.hex(),
                data_size=size, journal_size=journal, revision=revision,
                save_type=save_type, space_id=space, owner_id=owner,
                timestamp=stamp, system_save_id=system, rank=rank,
                index=index, flags=flags, commit_id=commit)
