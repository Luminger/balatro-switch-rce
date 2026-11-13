-- Per-game offset tables for Arco on Switch (native image).
--
-- Extracted from the decompressed main / sdk NSOs:
--   present (w_present) via luaL_Reg entry whose name string == "present"
--   got_memcpy via the PLT RELA whose symbol name == "memcpy"
--   SDK symbols via the sdk NSO's symbol table
--   SDK gadgets (ctx/fp/fiber/launder/thunk) by byte-signature match
--
-- Arco's shipped nnSdk is BYTE-IDENTICAL to Balatro 1.0.1f's: every gadget
-- signature from ffi_call.lua matches at the same offset the Balatro work
-- recorded, which is why the sdk subtable below reuses those values
-- verbatim. Verified by re-running the signature scan against arco_sdk.bin.
--
-- Arco v0 Base (0100E6601ACB6000) and v1.2.0 Update (0100E6601ACB6800) ship
-- byte-identical main+sdk NSOs; one profile covers both.

local ARCO_SDK = {
    mod0 = 0x8,
    -- Balatro/GC's sdk had memcpy = 0x5947b0 but that is the thunk's entry; Arco's
    -- dynamic linker resolves the GOT slot straight to the real memcpy body 16
    -- bytes later at 0x5947c0. Verified live against the runtime GOT target with
    -- sys-botbase: peekAbsolute(got_memcpy)[16] == e80301cb0a0940925f0102eb62040054.
    memcpy = 0x5947c0,

    nifm_init = 0x38cca0,
    nifm_submit_now = 0x38dc40,
    nifm_ip = 0x38d9c0,

    sock_init = 0x147b70,
    socket = 0x147700,
    bind = 0x1475f0,
    listen = 0x147680,
    accept = 0x1475d0,
    recv = 0x147550,
    send = 0x147590,
    close = 0x147750,
    setsockopt = 0x1476a0,
    poll = 0x147790,
    fcntl = 0x147840,
    sock_error = 0x147a60,

    -- JankFFI gadgets (verified by byte-signature scan of arco_sdk.bin).
    thunk_ptr = 0x8b1ac,
    launder = 0x76410,
    launder_arg1 = 0x38,
    launder_callee = 0x48,
    launder_arg0 = 0x50,

    fiber_switch = 0x135cd4,
    fiber_pop_gp = 0x3aba24,
    fiber_capture = 0x32d3c,

    -- Full-ABI gadgets for ffi_call.lua.
    ctx_restore = 0x56ee74,
    ctx_save = 0x56ef00,
    fp_capture = 0x56aee8,
}

local ARCO_V0 = {
    id = "arco-v0+v1.2.0",
    game = "arco",
    present = 0x2cb800,
    mod0 = 0x8,
    got_memcpy = 0x550c18,
    sdk = ARCO_SDK,
    expect = {
        present_head = "fd7bbea9f44f01a9fd030091281400d0",
        memcpy_head = "e80301cb0a0940925f0102eb62040054",
    },
}

return {
    ["arco-v0+v1.2.0"] = ARCO_V0,
    ["arco"] = { "arco-v0+v1.2.0" },
}
