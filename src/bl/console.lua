-- Full-screen, resolution-independent launch console.
--
-- Exactly two regions: a fixed status bar carrying brand, state and credit,
-- and the event log filling everything below it. The installed-file hashes
-- are ordinary log entries written at boot, not a separate pinned widget,
-- so there is nothing between the bar and the log. Old events evict and
-- long lines wrap. All widths follow getWidth(), so the same layout works
-- at 1280x720 and above.
local log = require("bl.log")
-- WRAP_INDENT aligns continuation rows past the "HH:MM:SS.mmm  " stamp
-- written by bl.log, so a wrapped event reads as one block.
local M = { visible = true, font = nil, font_size = 0, grid = nil,
            WRAP_INDENT = 14 }

-- Injected by bl.app so the bar owns clock placement, not the status text.
M.clock = nil

-- LÖVE bundles no monospace face, and none of Balatro's shipped fonts are
-- fixed-pitch (measured on hardware: m6x11plus i=3 W=9, Noto i=40 W=120).
-- A subset of JetBrains Mono NL (printable ASCII only, 8.8 KB) therefore
-- ships in savedata and is loaded from there; hardware confirms genuine
-- fixed pitch (i == W == 0 == space == 80 at size 16). The title's own
-- pixel font is the fallback, then LÖVE's default face, and a forced fixed
-- advance keeps columns aligned even on those proportional fallbacks.
--
-- Lines are baked into cached Text objects, so a line costs ONE draw call
-- per frame and zero allocation after its first appearance; per-frame
-- allocation is what drove GC steps into the native-call borrow window.
local MONO_PATHS = { "bl/assets/mono.ttf", "resources/fonts/m6x11plus.ttf" }
local mono = { font=nil, size=nil, cellw=0, cache={}, cached=0, max=768,
               face="none" }

local C = {
    bg={0.025,0.018,0.044,0.97}, bar={0.11,0.045,0.19,1},
    -- Footer: the same hue family as the status bar but muted, so it reads
    -- as a frame rather than competing with the header for attention.
    foot={0.07,0.032,0.125,1}, foot_rule={0.33,0.16,0.42,1},
    accent={0.93,0.20,0.68,1}, green={0.45,1.00,0.68,1},
    cyan={0.46,0.88,1.00,1}, pale={0.89,0.85,0.95,1},
    dim={0.62,0.57,0.70,1}, error={1.00,0.44,0.48,1},
}
local function color(g, c) g.setColor(c[1],c[2],c[3],c[4]) end

-- Text scales with the display: roughly 47 rows of console at any height,
-- so 720p gives 15px and a 2160p output gives 45px. The upper bound only
-- guards against an absurd reported height, not real hardware - a 21px cap
-- left 4K output unreadably small. The face is a scalable TTF and each size
-- is cached once, so large sizes cost nothing per frame.
local function font(height)
    local size = math.max(14, math.min(48, math.floor(height / 47)))
    if M.font and M.font_size == size then return M.font end
    local face, source = nil, nil
    for _, path in ipairs(MONO_PATHS) do
        if love.filesystem.getInfo(path) then
            face = log.try("newFont:" .. path, love.graphics.newFont, path, size)
            if face then source = path; break end
        end
    end
    if not face then
        face = log.try("newFont", love.graphics.newFont, size)
        source = "love-default"
    end
    if not face then return nil end
    -- Cell width is the widest printable glyph. On the bundled face every
    -- glyph is identical, so this IS the font's advance; on a proportional
    -- fallback it degrades to a correct, if airy, fixed grid.
    local cellw = 0
    for c = 32, 126 do
        local glyph = face:getWidth(string.char(c))
        if glyph > cellw then cellw = glyph end
    end
    if mono.face ~= source then
        log.log(("[UI] console font %s at %dpx, cell %dpx"):format(source, size, cellw))
    end
    M.font, M.font_size = face, size
    mono.font, mono.size, mono.cellw, mono.face = face, size, cellw, source
    mono.cache, mono.cached = {}, 0
    M.grid = nil
    return face
end

-- Fixed-advance text, cached per unique string. Proportional fallback keeps
-- working if the mono face is unavailable.
local function baked(line)
    local hit = mono.cache[line]
    if hit then return hit end
    if mono.cached >= mono.max then mono.cache, mono.cached = {}, 0 end
    local obj = log.try("newText", love.graphics.newText, mono.font)
    if not obj then return nil end
    local cell = mono.cellw
    for i = 1, #line do
        local ch = line:sub(i, i)
        local pad = (cell - mono.font:getWidth(ch)) * 0.5
        local ok = log.try("Text:add", obj.add, obj, ch,
                           math.floor((i - 1) * cell + pad), 0)
        if not ok then return nil end
    end
    mono.cache[line], mono.cached = obj, mono.cached + 1
    return obj
end

local function mono_width(line)
    if mono.cellw > 0 then return #line * mono.cellw end
    return M.font and M.font:getWidth(line) or #line * 9
end

-- How many characters fit in a pixel width. Monospace makes this exact, so
-- wrapping needs no measuring loop and no per-frame string building.
local function columns_for(width)
    if mono.cellw > 0 then return math.max(8, math.floor(width / mono.cellw)) end
    local glyph = M.font and M.font:getWidth("0") or 9
    return math.max(8, math.floor(width / math.max(1, glyph)))
end

-- Continuation rows line up under the MESSAGE, past both the timestamp and
-- the tag, so a wrapped [RPC] payload reads as one event and the tag column
-- stays clean. Falls back to the stamp width, then a constant, when a line
-- has no tag or no stamp at all.
local function indent_for(line, limit)
    local tagged = line:match("^%d%d:%d%d:%d%d%.%d%d%d%s+%[%w+%]%s")
    local indent = tagged and #tagged
        or (line:match("^%d%d:%d%d:%d%d%.%d%d%d%s+") and #line:match("^%d%d:%d%d:%d%d%.%d%d%d%s+"))
        or M.WRAP_INDENT
    -- Never let the indent swallow the usable width.
    return math.min(indent, math.max(8, math.floor(limit / 2)))
end
M.indent_for = indent_for

-- Fold one event into viewport-width rows. Continuation rows are indented
-- under the message so a wrapped RPC payload stays visually one event.
-- Results are cached per (line,width): the log is append-only, so a line's
-- folding never changes once computed.
local wrap = { width = 0, cache = {}, cached = 0, max = 512 }

local function fold(line, limit, indent)
    if #line <= limit then return nil end
    if wrap.width ~= limit then wrap.width, wrap.cache, wrap.cached = limit, {}, 0 end
    local hit = wrap.cache[line]
    if hit then return hit end
    if wrap.cached >= wrap.max then wrap.cache, wrap.cached = {}, 0 end
    local pad = (" "):rep(indent)
    local rows, pos, room = {}, 1, limit - indent
    rows[1] = line:sub(1, limit)
    pos = limit + 1
    while pos <= #line do
        -- Prefer a word boundary, but never loop: fall back to a hard cut.
        local chunk = line:sub(pos, pos + room - 1)
        if pos + room - 1 < #line then
            local brk = chunk:find("%s[^%s]*$")
            if brk and brk > room * 0.55 then chunk = chunk:sub(1, brk - 1) end
        end
        rows[#rows + 1] = pad .. chunk
        pos = pos + #chunk
        while line:sub(pos, pos) == " " do pos = pos + 1 end
    end
    wrap.cache[line], wrap.cached = rows, wrap.cached + 1
    return rows
end

M.fold = fold

-- Layout metrics, for tests and RPC inspection: the renderer's own idea of
-- character cell width and how many columns a pixel width holds.
function M.metrics()
    return { cell = mono.cellw, mono = mono.cellw > 0, size = mono.size,
             face = mono.face, baked = mono.cached }
end
M.columns_for = columns_for

-- Single text-drawing entry point: monospace when available, otherwise the
-- plain proportional path. Never printf: wrapping is handled by layout.
local function put(g, line, x, y)
    if mono.cellw > 0 then
        local obj = baked(line)
        if obj then g.draw(obj, math.floor(x), math.floor(y)); return end
    end
    g.print(line, math.floor(x), math.floor(y))
end

local function event_color(line)
    if line:find("[ERROR]",1,true) or line:find("FATAL",1,true) or
       line:find("FAILED",1,true) or line:find("network-error",1,true) then return C.error end
    if line:find("[HASH]",1,true) then return C.cyan end
    if line:find("[UI]",1,true) or line:find("[IMG]",1,true) then return C.cyan end
    if line:find("[RPC]",1,true) then return C.accent end
    if line:find("[FTP]",1,true) then return C.cyan end
    if line:find("[net]",1,true) or line:find("[NET]",1,true) or
       line:find("ready",1,true) then return C.green end
    if line:find("[BOOT]",1,true) then return C.pale end
    return C.dim
end

function M.draw(status)
    local g = love.graphics
    pcall(g.setCanvas)
    pcall(g.setShader)
    pcall(g.origin)
    pcall(g.setBlendMode, "alpha")
    local w,h = g.getWidth(),g.getHeight()
    local f = font(h)
    if f then g.setFont(f) end
    local glyph_h = f and f:getHeight() or M.font_size
    local step = glyph_h + 4
    local margin = math.max(12,math.floor(w * 0.012))
    local width = w - 2 * margin
    local bar = step + 14

    color(g,C.bg);g.rectangle("fill",0,0,w,h)
    color(g,C.bar);g.rectangle("fill",0,0,w,bar)
    color(g,C.accent);g.rectangle("fill",0,bar-2,w,2)

    -- One bar, in reading order: brand, service addresses, clock at the
    -- right edge. Credits live in the footer instead.
    local brand = "BALATRO // SWITCH RCE"
    local state = tostring(status or "")
    local clock = M.clock and M.clock() or ""

    -- Centred in the bar above its 2px accent rule, by the same rule as the
    -- footer: derive the baseline from the glyph height, never a constant.
    local bar_text_y = math.floor((bar - 2 - glyph_h) / 2)
    local clock_w = mono_width(clock)
    color(g,C.dim);put(g,clock,margin+width-clock_w,bar_text_y)

    if mono_width(brand) + mono_width(state) + clock_w + 60 > width then
        brand = "BL//RCE"
    end
    color(g,C.accent);put(g,brand,margin,bar_text_y)
    color(g,C.green);put(g,state,margin+mono_width(brand)+mono_width("  "),
                         bar_text_y)

    -- Footer: attribution pinned to the bottom-right, outside the scrolling
    -- region so it can never be evicted by log traffic. It gets its own band
    -- and a hairline, mirroring the status bar at lower contrast; bare text
    -- floating on the background read as unfinished.
    local credit = log.CREDIT or ""
    local footer = 0
    if #credit > 0 and mono_width(credit) + 2*margin <= w then
        footer = step + 4
        local top = h - footer
        color(g,C.foot);g.rectangle("fill",0,top,w,footer)
        color(g,C.foot_rule);g.rectangle("fill",0,top,w,1)
        color(g,C.dim)
        -- Centred in the band BELOW the hairline, so the visible gap above
        -- and below the text matches instead of hugging the rule.
        put(g,credit,margin+width-mono_width(credit),
            top + 1 + math.floor((footer - 1 - glyph_h) / 2))
    end

    -- Everything between the bar and the footer is log. The log runs right up
    -- to the footer: reserving a bottom margin on top of the band left an
    -- obvious dead strip and cost a usable row.
    local y=bar+8
    local floor_y=h-(footer>0 and footer or margin)
    local capacity=math.max(0,math.floor((floor_y-y)/step))
    -- Exposed for layout tests: dead space at the bottom is a real defect,
    -- and asserting it needs the renderer's own numbers.
    M.layout={top=y,floor=floor_y,step=step,capacity=capacity,footer=footer,
              bar=bar,glyph=glyph_h,bar_text=bar_text_y}
    local limit=columns_for(width)
    -- Walk BACKWARDS from the newest event, accumulating wrapped rows until
    -- the viewport is full. Wrapping therefore evicts old events instead of
    -- pushing recent ones off the bottom edge.
    local rows={}
    for i=#log.lines,1,-1 do
        local line=log.lines[i]
        local folded=fold(line,limit,indent_for(line,limit))
        local tint=event_color(line)
        if folded then
            for j=#folded,1,-1 do
                rows[#rows+1]={text=folded[j],tint=tint}
                if #rows>=capacity then break end
            end
        else
            rows[#rows+1]={text=line,tint=tint}
        end
        if #rows>=capacity then break end
    end
    M.layout.rows=#rows
    M.layout.last_bottom=y+math.min(#rows,capacity)*step
    for i=math.min(#rows,capacity),1,-1 do
        color(g,rows[i].tint)
        put(g,rows[i].text,margin,y)
        y=y+step
    end
end

return M
