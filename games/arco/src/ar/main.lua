-- Savedata shadow of Arco's main.lua. LÖVE mounts the save dir ahead of
-- romfs when setIdentity is called with appendidentity=false, so this file
-- wins over the one shipped in the cart. The game's own main.lua never
-- runs: we boot the launcher (gc-style app, renamed ar.*) and keep the
-- process alive painting the launcher console and servicing RPC/FTP.

if arg == nil then arg = {} end

function love.load()
    if love.window and not love.window.isOpen() then
        pcall(love.window.setMode, 1280, 720, {resizable = false})
        pcall(love.window.setTitle, "arco-switch-rce")
    end

    local ok, app = pcall(require, "ar.app")
    if ok then
        app.boot("Arco", "arco")
    else
        pcall(love.filesystem.append, "ar_log.txt",
            "[main] require ar.app: " .. tostring(app) .. "\n")
        if love.graphics and love.graphics.setBackgroundColor then
            love.graphics.setBackgroundColor(0.1, 0, 0)
        end
    end
end

function love.update(dt)
end

function love.draw()
    love.graphics.clear(0, 0, 0, 1)
end

function love.keypressed(key)
    if key == "escape" then love.event.quit() end
end

function love.errorhandler(msg)
    local text = "error:\n" .. tostring(msg) .. "\n\n" .. debug.traceback("", 2)
    pcall(love.filesystem.append, "ar_log.txt", "[main] " .. text .. "\n")
    if not (love.graphics and love.event) then return end
    if love.window and not love.window.isOpen() then
        pcall(love.window.setMode, 1280, 720)
    end
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
