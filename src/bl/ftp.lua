-- FTP command/filesystem core; no native calls here. bl.ftp_server supplies
-- nonblocking control/data sockets and PASV 150/226 sequencing. It is only
-- started by an explicitly enabled network build after SDK setup succeeds.
local M = {}
local MAX_UPLOAD = 1024 * 1024

local function path(cwd, raw)
    if type(raw) ~= "string" or raw:find("%z") or raw:find("\\", 1, true) then return nil end
    local parts = {}
    if raw:sub(1, 1) ~= "/" then
        for part in cwd:gmatch("[^/]+") do parts[#parts + 1] = part end
    end
    for part in raw:gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." then
            if not part:match("^[%w_%.%-]+$") then return nil end
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

-- Self-update surface: launcher code plus launcher assets, nothing else.
-- Still an explicit allowlist, so a traversal-sanitised path cannot reach
-- Balatro's own save files or arbitrary savedata names.
local function writable(p)
    return p == "conf.lua" or p == "main.lua" or
           p:match("^bl/[%w_%-]+%.lua$") ~= nil or
           p:match("^workers/[%w_%-]+%.lua$") ~= nil or
           p:match("^bl/assets/[%w_%-]+%.ttf$") ~= nil
end

local function readable(p)
    return writable(p) or p == "bl_log.txt" or p == "bl_phase.txt"
end

local function folder(p)
    return p == "" or p == "bl" or p == "workers" or p == "bl/assets"
end

function M.new(fs, options)
    options = options or {}
    assert(fs, "FTP requires a filesystem")
    local ip, port = options.ip, options.port
    local self = { cwd = "", fs = fs }

    function self:handle(line)
        if type(line) ~= "string" or #line > 1024 then return "500 command too long" end
        local cmd, arg = line:match("^(%a+)%s*(.-)%s*$")
        cmd, arg = (cmd or ""):upper(), arg or ""
        -- First-throw LAN prototype: intentionally no credential gate.
        if cmd == "USER" or cmd == "PASS" then return "230 logged in" end
        if cmd == "QUIT" then return "221 bye", { op = "close" } end
        if cmd == "SYST" then return "215 UNIX Type: L8" end
        if cmd == "FEAT" then return "211-Features\r\n SIZE\r\n211 End" end
        if cmd == "TYPE" then return arg:match("^[AI]$") and "200 type set" or "504 unsupported type" end
        if cmd == "MODE" then return arg == "S" and "200 stream mode" or "504 unsupported mode" end
        if cmd == "STRU" then return arg == "F" and "200 file structure" or "504 unsupported structure" end
        if cmd == "NOOP" then return "200 ok" end
        if cmd == "PWD" or cmd == "XPWD" then return ('257 "/%s"'):format(self.cwd) end
        if cmd == "CDUP" then self.cwd = ""; return "250 directory changed" end
        if cmd == "CWD" then
            local p = path(self.cwd, arg)
            if p and folder(p) then self.cwd = p; return "250 directory changed" end
            return "550 not a launcher directory"
        end
        if cmd == "PASV" then
            local a,b,c,d
            if type(ip) == "string" then a,b,c,d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") end
            if not a or type(port) ~= "number" or port < 1 or port > 65535 or
               math.max(tonumber(a),tonumber(b),tonumber(c),tonumber(d)) > 255 then
                return "425 passive listener unavailable"
            end
            return ("227 Entering Passive Mode (%s,%s,%s,%s,%d,%d)"):format(
                a,b,c,d,math.floor(port/256),port%256)
        end
        if cmd == "SIZE" then
            local p = path(self.cwd, arg)
            if not p or not readable(p) then return "550 invalid path" end
            local info = fs.getInfo(p)
            return info and info.type == "file" and ("213 %d"):format(info.size) or "550 not found"
        end
        if cmd == "LIST" or cmd == "NLST" then
            local p = path(self.cwd, arg)
            if not p or not folder(p) then return "550 invalid directory" end
            local entries = p == "" and { "bl", "workers", "conf.lua", "main.lua",
                                            "bl_log.txt", "bl_phase.txt" }
                            or fs.getDirectoryItems(p)
            local out = {}
            for _, entry in ipairs(entries or {}) do
                local name = (p == "" and entry or p .. "/" .. entry)
                if folder(name) or readable(name) then
                    local info = fs.getInfo(name)
                    if info then
                        if cmd == "NLST" then
                            out[#out + 1] = entry
                        else
                            out[#out + 1] = ("%s 1 nx nx %10d Jan 01 00:00 %s"):format(
                                info.type == "directory" and "drwxr-xr-x" or "-rw-r--r--",
                                info.size or 0, entry)
                        end
                    end
                end
            end
            table.sort(out)
            return "150 opening data connection", { op = "send", path = p,
                data = table.concat(out, "\r\n") .. "\r\n" }
        end
        if cmd == "RETR" then
            local p = path(self.cwd, arg)
            if not p or not readable(p) then return "550 invalid path" end
            local data = fs.read(p)
            if not data then return "550 not found" end
            return "150 opening data connection", { op = "send", path = p, data = data }
        end
        if cmd == "STOR" then
            local p = path(self.cwd, arg)
            if not p or not writable(p) then return "550 invalid path" end
            return "150 opening data connection", { op = "receive", path = p,
                max_bytes = MAX_UPLOAD,
                complete = function(data)
                    if type(data) ~= "string" or #data > MAX_UPLOAD then
                        return "552 upload exceeds limit"
                    end
                    local ok = fs.write(p, data)
                    return ok and "226 stored" or "550 write failed"
                end }
        end
        return "502 command not implemented"
    end
    return self
end

return M
