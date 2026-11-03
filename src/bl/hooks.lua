-- love.* callback interception.
--
-- Two facts drive the design:
--
-- 1. We run BEFORE the app assigns its callbacks (conf.lua is loaded before
--    main.lua), so there is nothing to wrap yet. A metatable on the `love`
--    table catches the assignments when they happen - which is also what
--    makes this work unchanged whether the host is our standalone main.lua
--    or the game's.
-- 2. The stock love.threaderror, read out of this build's embedded
--    callbacks.lua, is:
--        function love.threaderror(t, err) error("Thread error ...", 0) end
--    i.e. it re-raises in the main state and kills the app. A worker bug
--    must not be able to do that, so ours logs instead.

local log = require("bl.log")
local console = require("bl.console")

local M = { installed = {}, original = {}, ours = {}, wrappers = nil,
            thread_errors = 0 }

function M.install(handlers)
    handlers = handlers or {}
    local wrappers = {}

    wrappers.update = function(real)
        return function(dt, ...)
            if handlers.update then log.try("tick", handlers.update, dt) end
            if real and not M.app_update_dead then
                local ok, err = pcall(real, dt, ...)
                if not ok then
                    M.app_update_dead = true
                    log.log("[bl] app update disabled after: " .. tostring(err))
                end
            end
        end
    end

    wrappers.draw = function(real)
        return function(...)
            -- Self-healing works because update and draw heal each other:
            -- whichever hook survives re-wraps the one that was replaced.
            M.verify()
            if real and pcall(real, ...) and handlers.frame_drawn then
                pcall(handlers.frame_drawn)
            end
            if console.visible then
                local status_ok, text = pcall(handlers.status or function() return "" end)
                local ok, err = pcall(console.draw, status_ok and text or "status unavailable")
                if not ok and not M.console_failed then
                    M.console_failed = true
                    log.log("[ERROR] console draw: " .. tostring(err))
                end
            end
        end
    end

    wrappers.keypressed = function(real)
        return function(key, ...)
            if key == "f8" then console.visible = not console.visible; return end
            if real then return real(key, ...) end
        end
    end

    wrappers.gamepadpressed = function(real)
        return function(js, button, ...)
            if button == "back" then console.visible = not console.visible; return end
            if real then return real(js, button, ...) end
        end
    end

    for _,name in ipairs({"focus", "visible"}) do
        local event = name
        wrappers[event] = function(real)
            return function(value, ...)
                if handlers[event] then log.try(event, handlers[event], value) end
                if real then return real(value, ...) end
            end
        end
    end

    wrappers.threaderror = function()
        return function(t, err)
            M.thread_errors = M.thread_errors + 1
            log.phase("thread-error")
            log.log(("[bl] thread error (%s): %s"):format(tostring(t), tostring(err)))
        end
    end

    wrappers.errhand = function()
        return function(msg)
            pcall(log.log, "[bl] FATAL " .. tostring(msg))
            pcall(log.log, tostring(debug.traceback("", 2)))
            console.visible = true
            pcall(function()
                while true do
                    if love.event then
                        pcall(love.event.pump)
                        for e in love.event.poll() do
                            if e == "quit" then return end
                        end
                    end
                    pcall(console.draw, "FATAL")
                    pcall(love.graphics.present)
                    if love.timer then pcall(love.timer.sleep, 0.1) end
                end
            end)
        end
    end

    M.wrappers = wrappers
    local love_t = rawget(_G, "love")
    local mt = getmetatable(love_t) or {}
    local prev = mt.__newindex
    mt.__newindex = function(t, k, v)
        local wrap = wrappers[k]
        if wrap and type(v) == "function" then
            M.original[k] = v
            local ok, wrapped = pcall(wrap, v)
            rawset(t, k, ok and wrapped or v)
            M.ours[k] = ok and wrapped or nil
            M.installed[k] = true
            return
        end
        if prev then return prev(t, k, v) end
        rawset(t, k, v)
    end
    setmetatable(love_t, mt)

    -- Anything already assigned (different load order) is wrapped in place.
    for k, wrap in pairs(wrappers) do
        local cur = rawget(love_t, k)
        if cur and not M.installed[k] then
            M.original[k] = cur
            local ok, wrapped = pcall(wrap, cur)
            if ok then
                rawset(love_t, k, wrapped)
                M.ours[k] = wrapped
                M.installed[k] = true
            end
        end
    end
    -- These events can arrive before main.lua assigns any callbacks. Own
    -- them immediately; unlike update/draw there is no app implementation
    -- that we need to wait for.
    for _,name in ipairs({"focus","visible"}) do
        if not M.installed[name] then
            local wrapped=wrappers[name](nil)
            rawset(love_t,name,wrapped)
            M.ours[name],M.installed[name]=wrapped,true
        end
    end
    return M
end

-- Lua's __newindex only fires for keys that are ABSENT. Once we have
-- rawset our wrapper, a later `love.update = f` overwrites it directly and
-- our hook is silently gone - so re-wrap anything that is no longer ours.
-- Cheap identity comparisons, called once per frame.
function M.verify()
    if not M.wrappers then return end
    local love_t = rawget(_G, "love")
    for k, wrap in pairs(M.wrappers) do
        local cur = rawget(love_t, k)
        if type(cur) == "function" and M.ours[k] ~= nil and cur ~= M.ours[k] then
            M.original[k] = cur
            local ok, wrapped = pcall(wrap, cur)
            if ok then
                rawset(love_t, k, wrapped)
                M.ours[k] = wrapped
                log.log("[bl] re-wrapped love." .. k .. " (it had been replaced)")
            end
        end
    end
end

return M
