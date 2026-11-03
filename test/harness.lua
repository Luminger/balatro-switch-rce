-- A fake `love` good enough to exercise the launcher off-target: in-memory
-- filesystem, no-op graphics, channel-based threads that do NOT actually
-- run. Shared by every test so they stay comparable.

local H = { files = {}, channels = {}, threads = {}, drawn = 0, presented = 0,
            printed = {}, rects = {} }

local function channel(name)
    H.channels[name] = H.channels[name] or {}
    -- Resolve the queue by NAME on every call: closing over the table meant a
    -- test replacing H.channels[name] was invisible to an already-handed-out
    -- channel object, which is not how love.thread channels behave.
    local function q() H.channels[name] = H.channels[name] or {}; return H.channels[name] end
    return {
        push = function(_, v) local t = q(); t[#t + 1] = v end,
        pop = function() return table.remove(q(), 1) end,
        demand = function() return table.remove(q(), 1) end,
        getCount = function() return #q() end,
    }
end

function H.install()
    H.files, H.channels, H.threads = {}, {}, {}
    H.drawn, H.printed, H.rects = 0, {}, {}
    _G.love = {
        filesystem = {
            getInfo = function(n) return H.files[n] and { size = #H.files[n], type = "file" } or nil end,
            read = function(n) return H.files[n] end,
            write = function(n, d) H.files[n] = d; return true end,
            append = function(n, d) H.files[n] = (H.files[n] or "") .. d; return true end,
            remove = function(n) H.files[n] = nil; return true end,
            createDirectory = function() return true end,
            -- Directory-aware, because the launcher now deliberately lists
            -- only its own directories (the real love.filesystem merges
            -- savedata with the romfs game source).
            getDirectoryItems = function(dir)
                local out = {}
                for path in pairs(H.files) do
                    local d, name = path:match("^(.*)/([^/]+)$")
                    if (d or "") == (dir or "") then out[#out + 1] = name or path end
                end
                table.sort(out)
                return out
            end,
            getSaveDirectory = function() return "save:/.lovegame" end,
        },
        graphics = {
            -- Mirrors the hardware signatures: newFont(size) and
            -- newFont(path,size). Per-glyph widths vary so forced-monospace
            -- cell math is exercised, with "W" widest as on the real face.
            newFont = function(a, b)
                local s = tonumber(b) or tonumber(a) or 14
                local path = (type(a) == "string") and a or nil
                -- The title ships m6x11plus; set H.deny_font to prove the
                -- proportional fallback still renders.
                if path and H.deny_font then
                    error("could not open file " .. path, 0)
                end
                return {
                    path = path,
                    getHeight = function() return s end,
                    getWidth = function(_, text)
                        text = tostring(text)
                        local total = 0
                        for i = 1, #text do
                            local ch = text:sub(i, i)
                            local w = (ch == "W" or ch == "M") and 9
                                or (ch == "i" or ch == "l" or ch == "."
                                    or ch == ":" or ch == " ") and 3 or 7
                            total = total + math.floor(w * s / 16)
                        end
                        return total
                    end,
                }
            end,
            newText = function(f)
                local obj = {font = f, glyphs = {}}
                obj.add = function(self, ch, x, y)
                    self.glyphs[#self.glyphs+1] = {ch=ch,x=x,y=y}
                    return #self.glyphs
                end
                obj.getWidth = function(self)
                    local right = 0
                    for _, gl in ipairs(self.glyphs) do
                        right = math.max(right, gl.x + 7)
                    end
                    return right
                end
                return obj
            end,
            draw = function(obj,x,y)
                H.drawn = H.drawn + 1
                local chars = {}
                for _, gl in ipairs(obj.glyphs or {}) do chars[#chars+1]=gl.ch end
                H.printed[#H.printed+1] = {text=table.concat(chars),x=x,y=y,
                                             baked=true,glyphs=#(obj.glyphs or {})}
            end,
            setFont = function() end, setCanvas = function() end, setShader = function() end,
            setBlendMode = function() end, origin = function() end, setColor = function() end,
            clear = function() end,
            -- Recorded so layout tests can assert bands and rules, not just text.
            rectangle = function(mode,x,y,w,hh)
                H.rects[#H.rects+1]={mode=mode,x=x,y=y,w=w,h=hh}
            end,
            print = function(text,x,y)
                H.drawn = H.drawn + 1
                H.printed[#H.printed+1] = {text=tostring(text),x=x,y=y}
            end,
            printf = function(text,x,y,limit,align)
                H.drawn = H.drawn + 1
                H.printed[#H.printed+1] = {text=tostring(text),x=x,y=y,
                                             limit=limit,align=align}
            end,
            present = function() H.presented = H.presented + 1 end,
            isActive = function() return true end,
            getWidth = function() return 1280 end, getHeight = function() return 720 end,
            present_marker = true,
        },
        timer = { getTime = function() return 1.5 end, step = function() return 1/60 end, sleep = function() end },
        event = { pump = function() end, poll = function() return function() end end, quit = function() end },
        system = { getOS = function() return "Nintendo Switch" end },
        keyboard = { isDown = function() return false end },
        thread = {
            getChannel = channel,
            newThread = function(file)
                local t = { file = file, args = nil, err = nil }
                t.start = function(_, ...) t.args = { ... }; return true end
                t.getError = function() return t.err end
                H.threads[#H.threads + 1] = t
                return t
            end,
        },
        getVersion = function() return 11, 4, 0, "Mysterious Mysteries" end,
    }
    love.graphics.present = function() H.presented = H.presented + 1 end
    return H
end

-- The module cache must be cleared between tests or state leaks across them.
function H.reset_modules()
    for _, name in ipairs({ "bl.app", "bl.log", "bl.console", "bl.hooks",
                            "bl.call", "bl.fiber_call", "bl.jffi", "bl.stamp",
                            "bl.rpc", "bl.ftp", "bl.ftp_server",
                            "bl.socket", "bl.offsets", "bl.repl", "bl.resolve" }) do
        package.loaded[name] = nil
    end
    _G.__BL = nil
end

function H.log()
    return H.files["bl_log.txt"] or ""
end

return H
