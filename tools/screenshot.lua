-- Rendition generator: boots the REAL launcher off-target (stubbed love,
-- resolve and sockets, network immediately up), captures the exact draw
-- calls console.draw issues once the app reaches "serving", and dumps them
-- for tools/screenshot.py to rasterize with the bundled font.
--
-- The file set mirrors build.py's collect() by reading src/ from disk, so
-- the on-screen build id and [HASH] manifest are the genuine ones.
--
-- Usage: luajit tools/screenshot.lua <cell-px> <glyph-height-px> <out.ops>
local cell = assert(tonumber(arg and arg[1]), "cell width argument")
local glyph_h = assert(tonumber(arg and arg[2]), "glyph height argument")
local out_path = assert(arg and arg[3], "output path argument")

local ROOT = (arg[0]:match("^(.*)/") or ".") .. "/.."

-- Deterministic wall clock: fixed second, milliseconds from the frame
-- counter, matching how bl.log derives stamps from the monotonic timer.
local FIXED = os.time({ year = 2026, month = 11, day = 2, hour = 21, min = 48, sec = 2 })
local real_date = os.date
os.time = function() return FIXED end
os.date = function(fmt, t) return real_date(fmt, t or FIXED) end

local T = 0.310 -- monotonic; the screenshot's launch second
local CONSOLE_IP = "192.168.1.50"

-- Savedata contents, mirroring the archive build.py packs.
local files = {}
local function load_file(rel)
    local fh = io.open(ROOT .. "/src/" .. rel, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
end
local function list_dir(rel)
    local p = io.popen(("ls -1 '%s/src/%s' 2>/dev/null"):format(ROOT, rel))
    local out = {}
    for name in p:lines() do out[#out + 1] = name end
    p:close()
    return out
end
files["conf.lua"] = assert(load_file("conf.lua"))
files["main.lua"] = assert(load_file("main.lua"))
for _, name in ipairs(list_dir("bl")) do
    if name:match("%.lua$") or name:match("%.ttf$") then
        files["bl/" .. name] = assert(load_file("bl/" .. name))
    end
end
for _, name in ipairs(list_dir("bl/assets")) do
    files["bl/assets/" .. name] = assert(load_file("bl/assets/" .. name))
end

-- Captured draw ops for the final frame.
local ops, color = {}, { 1, 1, 1, 1 }
local capturing = false
local function op(o)
    if capturing then ops[#ops + 1] = o end
end

local g = {
    getWidth = function() return 1280 end,
    getHeight = function() return 720 end,
    setFont = function() end, setCanvas = function() end,
    setShader = function() end, setBlendMode = function() end,
    origin = function() end, clear = function() end,
    setColor = function(r, gg, b, a) color = { r, gg, b, a or 1 } end,
    rectangle = function(mode, x, y, w, h)
        op({ k = "R", x = x, y = y, w = w, h = h, c = color })
    end,
    print = function(text, x, y) op({ k = "T", x = x, y = y, t = tostring(text), c = color }) end,
    draw = function(obj, x, y)
        local chars = {}
        for _, gl in ipairs(obj.glyphs or {}) do chars[#chars + 1] = gl.ch end
        op({ k = "T", x = x, y = y, t = table.concat(chars), c = color })
    end,
    newText = function()
        local obj = { glyphs = {} }
        obj.add = function(self, ch, x)
            self.glyphs[#self.glyphs + 1] = { ch = ch, x = x }
            return #self.glyphs
        end
        return obj
    end,
    -- Metrics come from the real face, measured by tools/screenshot.py at
    -- the same pixel size the console picks for 720p.
    newFont = function()
        return {
            getHeight = function() return glyph_h end,
            getWidth = function(_, text) return cell * #tostring(text) end,
        }
    end,
    present = function() end,
    isActive = function() return true end,
}

_G.love = {
    filesystem = {
        getInfo = function(n) return files[n] and { size = #files[n], type = "file" } or nil end,
        read = function(n) return files[n] end,
        write = function(n, d) files[n] = d; return true end,
        append = function(n, d) files[n] = (files[n] or "") .. d; return true end,
        remove = function(n) files[n] = nil; return true end,
        createDirectory = function() return true end,
        getDirectoryItems = function(dir)
            local out = {}
            for path in pairs(files) do
                local d, name = path:match("^(.*)/([^/]+)$")
                if (d or "") == (dir or "") then out[#out + 1] = name or path end
            end
            table.sort(out)
            return out
        end,
        getSaveDirectory = function() return "save:/.lovegame" end,
    },
    graphics = g,
    timer = { getTime = function() return T end, step = function() return 1 / 60 end,
              sleep = function() end },
    event = { pump = function() end, poll = function() return function() end end,
              quit = function() end },
    system = { getOS = function() return "Nintendo Switch" end },
    keyboard = { isDown = function() return false end },
    thread = {
        getChannel = function()
            return { push = function() end, pop = function() end,
                     demand = function() end, getCount = function() return 0 end }
        end,
        newThread = function()
            return { start = function() return true end, getError = function() return nil end }
        end,
    },
    getVersion = function() return 11, 4, 0, "Mysterious Mysteries" end,
}

package.path = ROOT .. "/src/?.lua;" .. package.path

-- The binary image resolves to the known Switch 1 profile...
local info = { sdk_base = 0x10000000,
               off = require("bl.offsets")["1.0.1f-FULL"].sdk }
package.loaded["bl.resolve"] = {
    version = function() return "1.0.1f-FULL" end,
    resolve = function() return info end,
}
-- ...and nifm/bsd come up immediately on a known address.
package.loaded["bl.socket"] = { new = function()
    return { ip = CONSOLE_IP,
             initialize = function() return true end,
             listener = function(_, port) return port end,
             close = function() return 0 end,
             transport = function()
                 return { accept = function() return nil, "would_block" end,
                          recv = function() return nil, "would_block" end,
                          send = function() return nil, "would_block" end,
                          close = function() return 0 end }
             end }
end }

local app = require("bl.app").boot()
function love.update() end
function love.draw() end

local function frame()
    T = T + 1 / 60
    pcall(love.update, 1 / 60)
    pcall(love.draw)
end

frame() -- first frame: status bar painted before fingerprinting
frame() -- identifying: banner + per-file [HASH] manifest
assert(app.state == "identifying", "state after frame 2: " .. tostring(app.state))
capturing = true
frame() -- bring_up: listeners up, serving status drawn
capturing = false
assert(app.state == "serving", "state after frame 3: " .. tostring(app.state))

local fh = assert(io.open(out_path, "w"))
for _, o in ipairs(ops) do
    local c = ("%g,%g,%g,%g"):format(o.c[1], o.c[2], o.c[3], o.c[4])
    if o.k == "R" then
        fh:write(("R\t%d\t%d\t%d\t%d\t%s\n"):format(o.x, o.y, o.w, o.h, c))
    else
        fh:write(("T\t%d\t%d\t%s\t%s\n"):format(o.x, o.y, c, o.t))
    end
end
fh:close()

local log = require("bl.log")
io.stderr:write(("build %s, %d ops, %d log lines\n")
    :format(log.build_id, #ops, #log.lines))
