-- Savedata copy of the cart's main.lua, which SHADOWS it - so Balatro never
-- runs: no require of game/globals, no G, no asset load, no sound/save
-- manager threads. What remains is LÖVE 11.4 + LuaJIT + ffi on the console,
-- booting in about a second.
--
-- Still the same process and NPDM: same granted services, savedata-only
-- filesystem, no SD on retail. A Lua shell inside that sandbox, not an
-- escape.
--
-- RECOVERY: the shadow wins, so a broken file here can make the title
-- unbootable. The cart ROM is untouched; restore a known-good JKSV backup
-- or remove this shadow from a separate save manager. Once the launcher has
-- started its FTP listener, modules can instead be replaced in-place.
-- Everything here is pcall'd.

function love.load()
    -- conf.lua normally booted the launcher already; reuse it if so.
    local ok, mod = pcall(require, "bl.app")
    if ok then
        mod.boot()
    else
        pcall(love.filesystem.append, "bl_log.txt", "[main] require bl.app: " .. tostring(mod) .. "\n")
    end
end

function love.update(dt)
    -- The launcher's hook does the work; nothing of ours belongs here.
end

function love.draw()
    -- The console paints over this frame; no Balatro renderer is involved.
    love.graphics.clear(0, 0, 0, 1)
end

function love.keypressed(key)
    if key == "escape" then love.event.quit() end
end

function love.errhand(msg)
    -- No G here, so no F_NO_ERROR_HAND: we can show the error ourselves.
    -- (The launcher replaces this with its own once hooks are installed.)
    local text = "standalone error:\n" .. tostring(msg) .. "\n\n" .. debug.traceback("", 2)
    pcall(love.filesystem.append, "bl_log.txt", "[main] " .. text .. "\n")
    if not (love.graphics and love.event) then return end
    local font = love.graphics.newFont(14)
    while true do
        pcall(love.event.pump)
        for e in love.event.poll() do
            if e == "quit" then return end
        end
        pcall(function()
            love.graphics.origin()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.printf(text, font, 12, 12, love.graphics.getWidth() - 24)
            love.graphics.present()
        end)
        if love.timer then love.timer.sleep(0.1) end
    end
end
