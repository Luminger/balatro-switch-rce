-- Implicit build identity: a fingerprint computed AT RUNTIME from the files
-- actually present in savedata.
--
-- Nothing to bump by hand, no git, no generated file to forget. It reflects
-- what is really running - which matters because modules can be replaced
-- individually over FTP without any build step, and because a log that
-- cannot name its own build wastes a launch (a same-named zip once meant the
-- console restored the previous build while the new build's features were
-- being read into its output).
--
-- FNV-1a over "path\0contents" for every module, in sorted path order, so
-- build.py can compute the identical value from the local tree and the two
-- can be compared.

local bit = require("bit")

local M = {}

-- love.filesystem presents a MERGED view of savedata and the romfs game
-- source, so listing "" picked up Balatro's own 28 modules (686 KB, ~1.9 s of
-- boot) and made the fingerprint depend on files we do not ship. Only our
-- own directories are enumerated, and at the root only our two shadows.
local DIRS = { "bl", "workers", "bl/assets" }
local ROOT_FILES = { "conf.lua", "main.lua" }
-- Assets ship with the launcher and are replaceable over FTP exactly like
-- code, so they belong in the identity too: a swapped font is a different
-- build. Extensions are matched, not a bare "everything", so a stray
-- bl_log.txt or crash artefact never changes the fingerprint.
local TRACKED = { "%.lua$", "%.ttf$" }

local function tracked(name)
    for _, pattern in ipairs(TRACKED) do
        if name:match(pattern) then return true end
    end
    return false
end

local function fnv1a(h, s)
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        -- 32-bit multiply by the FNV prime, split to stay exact in a double
        local lo = bit.band(h, 0xFFFF)
        local hi = bit.rshift(h, 16)
        h = bit.band(lo * 16777619 + bit.lshift(bit.band(hi * 16777619, 0xFFFF), 16), 0xFFFFFFFF)
    end
    return h
end

function M.files()
    local out = {}
    for _, name in ipairs(ROOT_FILES) do
        if love.filesystem.getInfo(name) then out[#out + 1] = name end
    end
    for _, dir in ipairs(DIRS) do
        -- A production save need not contain an old probes/workers folder.
        -- Some LÖVE ports throw for a missing directory, others return {}.
        local ok, items = pcall(love.filesystem.getDirectoryItems, dir)
        if ok and type(items) == "table" then
            for _, name in ipairs(items) do
                if tracked(name) then out[#out + 1] = dir .. "/" .. name end
            end
        end
    end
    table.sort(out)
    return out
end

-- Returns id, file count, total bytes, and a PER-FILE manifest.
--
-- The manifest is the point: an aggregate fingerprint alone is unresolvable
-- ("what was 09649ea2?"), whereas per-file hashes identify exactly which
-- module differs from the local tree - which matters most when a single file
-- has been replaced over FTP without a build.
--
-- bit.tohex rather than ("%08x"):format: bit.band yields a SIGNED 32-bit
-- number in LuaJIT, so string.format printed negatives as ffffffff92ed8105.
function M.compute()
    local h, n, bytes = 2166136261, 0, 0
    local manifest = {}
    for _, path in ipairs(M.files()) do
        local data = love.filesystem.read(path)
        if data then
            h = fnv1a(h, path)
            h = fnv1a(h, "\0")
            h = fnv1a(h, data)
            n = n + 1
            bytes = bytes + #data
            manifest[#manifest + 1] = {
                path = path,
                hash = bit.tohex(fnv1a(fnv1a(2166136261, path), data)),
                size = #data,
            }
        end
    end
    return bit.tohex(h), n, bytes, manifest
end

-- Compact lines for the console: several entries per line, since screen
-- space is the scarce resource but the data has to be visible.
--
-- Every cell is the SAME width, derived from the longest path in this
-- manifest, so paths, hashes and sizes line up as columns down the block.
-- A monospace console is assumed; the width is in characters, which is why
-- the console measures its grid in cells rather than pixels.
local function pad_right(s, width)
    local short = width - #s
    return short > 0 and (s .. (" "):rep(short)) or s
end

local function pad_left(s, width)
    local short = width - #s
    return short > 0 and ((" "):rep(short) .. s) or s
end

function M.manifest_lines(manifest, per_line)
    per_line = per_line or 3
    local names, sizes, widest, longest = {}, {}, 0, 0
    for i, e in ipairs(manifest) do
        names[i] = e.path:gsub("%.lua$", "")
        sizes[i] = tostring(e.size)
        if #names[i] > widest then widest = #names[i] end
        if #sizes[i] > longest then longest = #sizes[i] end
    end
    local out, cur = {}, {}
    for i, e in ipairs(manifest) do
        cur[#cur + 1] = ("%s %s %sB"):format(pad_right(names[i], widest),
                                             e.hash:sub(1, 6),
                                             pad_left(sizes[i], longest))
        if #cur == per_line then
            out[#out + 1] = table.concat(cur, "   ")
            cur = {}
        end
    end
    -- The last row is padded too, so a partial row keeps the same columns.
    if #cur > 0 then out[#out + 1] = table.concat(cur, "   ") end
    return out
end

return M
