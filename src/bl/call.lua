-- Explicit Lua-facing native invocation. Ordinary LuaJIT ffi casts, cdefs,
-- arrays and reads remain available; callable cdata still cannot be invoked
-- directly on this build (vm_ffi_call is absent). This adapter sends a
-- target and integer/pointer arguments through the verified VM/fiber bridge.
local fiber = require("bl.fiber_call")
local M = {}

function M.install(love_table, ffi, victim, info, backend)
    assert(love_table and ffi and victim and info and info.sdk_base)
    backend = backend or fiber.invoke
    local api = setmetatable({ raw = ffi }, { __index = ffi })
    function api.invoke(target, ...)
        return backend(ffi, victim, info, target, {...})
    end
    love_table.ffi = api
    return api
end

return M
