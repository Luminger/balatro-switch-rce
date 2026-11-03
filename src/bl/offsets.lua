-- Exact-image offsets for each known Balatro build. ASLR bases are resolved
-- at runtime; an unfamiliar image is rejected before dereferencing a guessed
-- base. The Switch 1 title running in Switch 2 compatibility mode MAY retain
-- these bytes, but the native Switch 2 release has not been recovered.
return {
    ["1.0.1o-FULL"] = {
        present = 0x2b1030,
        mod0 = 0x374060,
        got_memcpy = 0x4d7040,
        sdk = {
            mod0 = 0x602010,
            memcpy = 0x5224e0,

            nifm_init = 0x3a3100, -- nn::nifm::Initialize
            nifm_submit_now = 0x3a4130, -- nn::nifm::SubmitNetworkRequest
            nifm_ip = 0x3a3e50, -- nn::nifm::GetCurrentPrimaryIpAddress(nn::socket::InAddr*)

            sock_init = 0x5ec1c0,
            socket = 0x5ebda0,
            bind = 0x5ebc20,
            listen = 0x5ebd00,
            accept = 0x5ebbf0,
            recv = 0x5ebb30,
            send = 0x5ebb90,
            close = 0x5ebe00,
            setsockopt = 0x5ebd20,
            poll = 0x5ebe50,
            fcntl = 0x5ebe80,
            sock_error = 0x5ec020,

            thunk_ptr = 0x8dfac,
            launder = 0x78a14,
            launder_arg1 = 0x38,
            launder_callee = 0x48,
            launder_arg0 = 0x50,

            fiber_switch = 0x13d3b4,
            fiber_pop_gp = 0x3d9e54,
            fiber_capture = 0x34db0,
        },
        expect = {
            present_head = "fd7bbea9f44f01a9fd03009128110090",
            memcpy_head = "ec0301cb8a0940924b000aeb69040054",
        },
    },
    ["1.0.1f-FULL"] = {
        present = 0x2aff80,
        mod0 = 0x8,
        got_memcpy = 0x52b9c0,
        sdk = {
            mod0 = 0x8,
            memcpy = 0x5947b0, -- resolves sdk base from main's memcpy GOT

            -- nn::nifm
            nifm_init = 0x38cca0,
            nifm_submit_now = 0x38dc40,
            nifm_ip = 0x38d9c0,

            -- nn::socket export branches; dynamically resolved PLT veneers
            sock_init = 0x147b70, -- Initialize(void*,ulong,ulong,int)
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

            -- LuaJIT BC_FUNCC -> established Switch 1 tail thunk ->
            -- zero-result launderer. The borrowed L+0x18 field is gclist;
            -- GC lifetime safety under sustained polling is still under
            -- investigation despite the earlier live server success.
            thunk_ptr = 0x8b1ac,
            launder = 0x76410,
            launder_arg1 = 0x38,   -- ctrl field; must be nonzero
            launder_callee = 0x48,
            launder_arg0 = 0x50,

            -- Same-invocation fiber switch, x0..x7 GP pop, x0 capture.
            -- fiber_call.lua validates the full consumed code bytes.
            fiber_switch = 0x135cd4,
            fiber_pop_gp = 0x3aba24,
            fiber_capture = 0x32d3c,
        },
        expect = {
            -- The valid function pointer is checked BEFORE subtracting
            -- present and reading a potentially unmapped guessed base.
            present_head = "fd7bbea9f44f01a9fd030091e81300b0",
            memcpy_head = "e80301cb0a0940925f0102eb62040054",
        },
    },
    ["0.9.2i-FULL"] = "1.0.1f-FULL",
}
