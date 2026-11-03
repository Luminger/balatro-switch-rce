-- Derive the native module bases. No scanning, no hardcoded base, no dlsym.
--
--   main_base = funcinfo(love.graphics.present).addr - offsets.present
--   sdk_base  = *(main_base + offsets.got_memcpy) - offsets.sdk.memcpy
--
-- Both are then CONFIRMED by reading the MOD0 magic, so a wrong table entry
-- cannot send us walking into unmapped memory. This replaced a backward page
-- scan for the MOD0 header, which is unsound by construction - it must
-- eventually read off the end of the mapping, and it duly segfaulted the
-- host harness before it ever reached hardware.
--
-- ffi.C is useless here: it resolved 0/12 symbols on hardware, i.e. there is
-- no dlsym, which is exactly why the GOT trick is needed.

local log = require("bl.log")
local offsets = require("bl.offsets")

local M = {}

local MOD0_MAGIC = 0x30444f4d   -- "MOD0"

local function rd32(ffi, a) return ffi.cast("uint32_t*", ffi.cast("uintptr_t", a))[0] end
local function rd64(ffi, a) return ffi.cast("uint64_t*", ffi.cast("uintptr_t", a))[0] end
local function hex(v) return string.format("0x%x", tonumber(v) or 0) end
local function code_hex(ffi, address, count)
    local p = ffi.cast("const uint8_t*", ffi.cast("uintptr_t", address))
    local bytes = {}
    for i=0,count-1 do bytes[#bytes+1] = ("%02x"):format(tonumber(p[i])) end
    return table.concat(bytes)
end

-- The game is never loaded; read the title's unshadowed romfs version.
function M.version()
    local v = love.filesystem.read("version.jkr")
    return type(v) == "string" and v:match("^[^\r\n]+") or nil
end

function M.table_for(version)
    local t = offsets[version]
    while type(t) == "string" do t = offsets[t] end     -- follow aliases
    return t
end

function M.resolve(ffi)
    local version = M.version()
    local b = M.table_for(version)
    -- A Switch 1 title in Switch 2 compatibility mode can report different
    -- metadata while still loading the EXACT original main/nnSdk image.
    -- Try every known profile by its real function bytes, not the version
    -- string: the storefront name or OS string can change independently.
    if not b then
        for _, candidate in pairs(offsets) do
            if type(candidate) == "table" and candidate.present then
                b = candidate; break
            end
        end
    end
    if not b or not b.present then return nil, "no known native image profile" end

    local ok_util, util = pcall(require, "jit.util")
    if not ok_util then return nil, "jit.util unavailable" end
    local info = util.funcinfo(love.graphics.present)
    if not (info and info.addr) then return nil, "no present anchor" end
    local anchor = tonumber(info.addr)
    local signature = b.expect and b.expect.present_head
    if signature and code_hex(ffi,anchor,#signature/2) ~= signature then
        return nil, "unsupported present code image (different build or platform)"
    end

    log.phase("resolve:main")
    local main_base = anchor - b.present
    if main_base % 0x1000 ~= 0 then
        return nil, "present anchor does not yield a page-aligned main module"
    end
    if rd32(ffi, main_base + 4) ~= b.mod0 or rd32(ffi, main_base + b.mod0) ~= MOD0_MAGIC then
        return nil, ("main base %s failed the MOD0 check"):format(hex(main_base))
    end

    log.phase("resolve:sdk")
    local slot = rd64(ffi, main_base + b.got_memcpy)
    local memcpy_head = b.expect and b.expect.memcpy_head
    if memcpy_head and code_hex(ffi,tonumber(slot),#memcpy_head/2) ~= memcpy_head then
        return nil, "memcpy GOT points to a different or interposed code image"
    end
    local sdk_base = tonumber(slot) - b.sdk.memcpy
    if sdk_base % 0x1000 ~= 0 then
        return nil, "memcpy GOT does not yield a page-aligned SDK module"
    end
    if rd32(ffi, sdk_base + 4) ~= b.sdk.mod0 or rd32(ffi, sdk_base + b.sdk.mod0) ~= MOD0_MAGIC then
        return nil, ("sdk base %s failed the MOD0 check (GOT slot %s)"):format(hex(sdk_base), hex(slot))
    end

    log.log(("[IMG] %s | main %s | sdk %s | MOD0 confirmed"):format(
        tostring(version or "unknown metadata"), hex(main_base), hex(sdk_base)))
    return { version = version, main_base = main_base, sdk_base = sdk_base,
             off = b.sdk, expect = b.expect }
end

return M
