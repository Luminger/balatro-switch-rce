-- The launcher's native-call surface, exposed to Lua as `love.ffi`.
--
-- Ordinary LuaJIT ffi cdefs, casts, arrays, reads and writes all work on this
-- title. What does NOT work is *calling* a cdata function pointer: this
-- build's lj_vm_ffi_call was linked with no body onto eight bytes of
-- alignment padding, so a cdata call executes an undefined instruction and
-- kills the process. See `docs/luajit-build-defects.md` for the root cause
-- (the VM was generated with DynASM's FFI conditional off while the C library
-- has LJ_HASFFI=1) and for the three sibling defects it causes.
--
-- So native calls go through our own dispatch, rebuilt from SDK gadgets:
--
--   love.ffi.declare(ret, args, addr) -> a plain Lua function  [PRIMARY]
--       Full AAPCS64: up to 8 integer/pointer arguments, up to 8
--       float/double arguments, and a void/integer/pointer/float/double
--       return. This is the interface to use.
--
--   love.ffi.invoke(addr, ...)                                 [COMPAT]
--       The old integer-argument-only shape, kept so existing scripts keep
--       working: integer/pointer arguments in, a { raw, int32, int64 } table
--       out. It is now backed by the same full-ABI chain (gp_invoke); the
--       separate <=8-GP bridge it used to call has been deleted. New code
--       should use declare().
--
--   love.ffi.metatype(ctype, mt)
--       ffi.metatype with a guard: every metamethod shape that would reach
--       lj_meta_tailcall is fatal on this build (it branches to address 0),
--       so those are refused with a Lua error. A table __index is allowed,
--       and methods work through it.
--
--   love.ffi.u64_eq(a, b) / love.ffi.u64_is_zero(v)
--       64-bit cdata equality is broken here (equal values compare unequal),
--       so compare through these.
--
-- Everything else on `love.ffi` falls through to the real ffi module, and
-- `love.ffi.raw` is that module.
local ffi_call = require("bl.ffi_call")
local M = {}

function M.install(love_table, ffi, victim, info, backend)
    assert(love_table and ffi and victim and info and info.sdk_base)
    backend = backend or ffi_call.gp_invoke
    local api = setmetatable({ raw = ffi }, { __index = ffi })

    -- Legacy GP-only bridge, unchanged: the socket stack depends on it.
    function api.invoke(target, ...)
        return backend(ffi, victim, info, target, {...})
    end

    -- Full-ABI surface. The one-time register snapshot it needs is taken
    -- lazily on the first call, so installing this costs nothing at boot and
    -- an unsupported image still fails in preflight rather than mid-chain.
    function api.declare(ret, args, address)
        return ffi_call.declare(ffi, victim, info, ret, args, address)
    end

    function api.describe(fn) return ffi_call.describe(fn) end

    function api.metatype(ctype, mt)
        return ffi_call.metatype(ffi, ctype, mt)
    end

    function api.u64_eq(a, b) return ffi_call.u64_eq(ffi, a, b) end
    function api.u64_is_zero(v) return ffi_call.u64_is_zero(ffi, v) end

    -- Preflight without calling anything, for the status screen and tests.
    function api.native_ready() return ffi_call.preflight(ffi, info) end

    api.ffi_call = ffi_call
    love_table.ffi = api
    return api
end

return M
