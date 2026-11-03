-- Event log: bounded on-screen history, append-only savedata file, and an
-- abort-surviving phase breadcrumb. Build identity comes from the Lua files
-- actually installed, not git, a manual version or a boot counter.
local M = { lines = {}, max = 160, manifest = {}, build_id = "identifying",
            CREDIT = "Free and open source, download at: "..
                     "https://github.com/luminger/balatro-switch-rce" }

local LOG_FILE, PHASE_FILE = "bl_log.txt", "bl_phase.txt"

-- Every event is stamped on arrival with a millisecond wall clock.
--
-- os.date alone has one-second resolution, so the sub-second part comes from
-- the monotonic frame timer, anchored to os.time() once. Intervals between
-- entries are therefore exact, and the displayed time cannot run backwards
-- the way two independently sampled clocks can. The anchor is taken from an
-- integer os.time(), so the sub-second PHASE can be off by up to a second
-- against true civil time; the milliseconds are for ordering and durations,
-- not for correlating with another machine's clock.
local anchor_wall, anchor_mono = nil, nil

local function monotonic()
    if love and love.timer and love.timer.getTime then return love.timer.getTime() end
    return os.clock()
end

function M.timestamp()
    local mono = monotonic()
    if not anchor_wall then anchor_wall, anchor_mono = os.time(), mono end
    local wall = anchor_wall + (mono - anchor_mono)
    local whole = math.floor(wall)
    local ms = math.floor((wall - whole) * 1000)
    local ok, clock = pcall(os.date, "%H:%M:%S", whole)
    return ("%s.%03d"):format(ok and clock or "--:--:--", ms)
end

local function append_file(msg)
    local fs = love and love.filesystem
    if fs and fs.append then pcall(fs.append, LOG_FILE, tostring(msg) .. "\n") end
end

function M.phase(name)
    local fs = love and love.filesystem
    if fs and fs.write then pcall(fs.write, PHASE_FILE, tostring(name)) end
    return name
end

-- Lines are stored already stamped, so the screen, the savedata file and an
-- RPC reader all see identical text; nothing re-derives a time later.
function M.log(msg)
    msg = tostring(msg)
    local stamp = M.timestamp()
    for line in (msg .. "\n"):gmatch("(.-)\n") do
        local stamped = stamp .. "  " .. line
        M.lines[#M.lines + 1] = stamped
        append_file(stamped)
    end
    while #M.lines > M.max do table.remove(M.lines, 1) end
    return msg
end

function M.try(what, f, ...)
    local ok, a = pcall(f, ...)
    if not ok then
        M.log(("[ERROR] %s: %s"):format(tostring(what), tostring(a)))
        return nil
    end
    return a == nil and true or a
end

local function build_id()
    local ok, stamp = pcall(require, "bl.stamp")
    if not ok then return "nostamp", 0, 0, nil, nil end
    local ok2, id, n, bytes, manifest = pcall(stamp.compute)
    if not ok2 then return "stampfail", 0, 0, nil, nil end
    return id, n, bytes, manifest, stamp
end
M.build = build_id

function M.banner(version)
    local id, nfiles, nbytes, manifest, stamp = build_id()
    M.build_id, M.manifest = id, manifest or {}
    M.log(("[BOOT] %s / image %s / %d files / %dB")
        :format(tostring(version), id, nfiles, nbytes))
    -- Credits are a permanent footer in the console, not a log event: an
    -- event scrolls away, and attribution should not.
    append_file(M.timestamp() .. "  " .. M.CREDIT)
    -- The installed-file manifest is ordinary log content, not a separate
    -- always-on widget: it scrolls away with everything else, and the
    -- append-only file keeps it for every launch.
    if manifest and stamp then
        for _, line in ipairs(stamp.manifest_lines(manifest, 3)) do
            M.log("[HASH] " .. line)
        end
    end
    return id
end

return M
