-- Savedata copy of the cart's conf.lua, which SHADOWS it: love.filesystem
-- resolves savedata ahead of the romfs game source. Proven on hardware:
--     require(savedata)=SHADOWED-FROM-SAVEDATA  path=?.lua;?/init.lua
--     read-precedence: savedata WINS romfs
--
-- conf.lua is the right file to shadow: LÖVE loads it before main.lua and
-- before any game module, it is ten lines long and identical across
-- 0.9.2i/1.0.1f/1.0.1o, and no file the game ever WRITES is involved - so
-- the launcher cannot be deleted by the game saving (which is exactly what
-- happened when it lived in settings.jkr).
--
-- The first half is the cart's conf.lua byte-for-byte. Keep it that way:
-- window 0x0 is what makes the game pick the native resolution.
_RELEASE_MODE = true
_DEMO = false

function love.conf(t)
    t.console = not _RELEASE_MODE
    t.title = 'Balatro'
    t.window.width = 0
    t.window.height = 0
    t.window.minwidth = 100
    t.window.minheight = 100
end

-- Nothing below may raise: an error in conf.lua happens before love.errhand
-- exists, so it is an unrecoverable (and with F_NO_ERROR_HAND, silent) boot
-- failure.
pcall(function()
    local ok, app = pcall(require, "bl.app")
    if not ok then
        pcall(love.filesystem.append, "bl_log.txt", "[conf] require bl.app: " .. tostring(app) .. "\n")
        return
    end
    local ok2, err = pcall(app.boot)
    if not ok2 then
        pcall(love.filesystem.append, "bl_log.txt", "[conf] app.boot: " .. tostring(err) .. "\n")
    end
end)
