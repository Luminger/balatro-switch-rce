-- Production launcher tests. Run from tools/balatro: luajit test/run.lua
package.path = "src/?.lua;src/?/init.lua;" .. package.path

local H = require("test.harness")
local T = {checks=0, failures=0}
function T.check(name, condition, detail)
    T.checks=T.checks+1
    if condition then print("  ok   "..name)
    else
        T.failures=T.failures+1
        print(("  FAIL %s%s"):format(name,detail and (" - "..tostring(detail)) or ""))
    end
end

for _,name in ipairs({"log_console", "resolution", "native_core", "socket", "protocol", "app_network"}) do
    print("== "..name)
    H.install();H.reset_modules()
    require("test."..name)(T,H)
end
if T.failures>0 then
    io.stderr:write(("%d of %d CHECKS FAILED\n"):format(T.failures,T.checks))
    os.exit(1)
end
print(("ALL %d CHECKS PASSED"):format(T.checks))
