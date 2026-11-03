-- Production launcher. The first frame paints the UI before fingerprinting
-- or entering nnSdk. Then native resolution and network setup run in the
-- main state; RPC/FTP use bounded nonblocking work on subsequent frames.
local log     = require("bl.log")
local console = require("bl.console")
local hooks   = require("bl.hooks")
local resolve = require("bl.resolve")
local call    = require("bl.call")

local M = {state="first-frame", log=log, console=console, hooks=hooks}
local REPL_PORT, FTP_PORT, PASV_PORT = 9026, 5000, 5001
-- No "LIVE" label: when the services are up, the endpoints themselves say
-- so. Only pre-serving and failure states need naming.
local LABEL = {["first-frame"]="BOOTING", identifying="SCANNING",
               connecting="CONNECTING", ["network-error"]="ERROR",
               ["ui-only"]="UI ONLY"}

-- The clock is rendered separately, right-aligned by the console.
function M.clock()
    local ok, now = pcall(os.date,"%H:%M:%S")
    return ok and now or "--:--:--"
end

-- Serving: each service is shown as the address a client actually types,
-- so the IP appears in front of every port rather than once, far away.
local function status()
    local ip = M.net and M.net.ip or nil
    if M.state=="serving" and ip then
        return ("RPC %s:%d    FTP %s:%d"):format(ip,REPL_PORT,ip,FTP_PORT)
    end
    local label = LABEL[M.state] or M.state:upper()
    if M.state=="ui-only" then
        return label .. "  (unknown binary image, network services disabled)"
    end
    if ip then return ("%s   %s"):format(label,ip) end
    return label
end

local function events(tag)
    return function(kind, detail)
        log.log(("[%s] %s %s"):format(tag,kind,tostring(detail or "")))
    end
end

local function startup_error(message)
    if M.recovering then
        M.net_pending=true
        M.net_retry=love.timer.getTime()+1
        if message~=M.last_retry_error then
            M.last_retry_error=message
            log.log("[NET] reconnect pending: "..message)
        end
        return false
    end
    log.log("[ERROR] "..message)
    return false
end

local function start_network(ffi, info)
    M.net_pending=false
    local socket = M.net or require("bl.socket").new(ffi,love.graphics.present,info)
    M.net=socket
    socket.phase=log.phase -- setup breadcrumbs only, never per-frame poll
    local ok, why=socket:initialize()
    if not ok then
        if type(why)=="string" and why:find("^pending:") then
            M.net_pending=true
            M.net_retry=love.timer.getTime()+0.25
            socket.phase=nil
            if not M.net_pending_logged then
                M.net_pending_logged=true
                log.log("[NET] waiting for an IP; will continue without relaunch")
            end
            return false
        end
        socket.phase=nil
        return startup_error("network initialization: "..tostring(why))
    end
    log.log("[NET] IP "..tostring(socket.ip).."; socket pool initialized")
    local rpc_fd, rpc_err=socket:listener(REPL_PORT)
    if not rpc_fd then return startup_error("RPC listener: "..tostring(rpc_err)) end
    local ftp_fd, ftp_err=socket:listener(FTP_PORT)
    if not ftp_fd then
        socket:close(rpc_fd)
        return startup_error("FTP listener: "..tostring(ftp_err))
    end
    local pasv_fd, pasv_err=socket:listener(PASV_PORT)
    if not pasv_fd then
        socket:close(rpc_fd);socket:close(ftp_fd)
        return startup_error("PASV listener: "..tostring(pasv_err))
    end
    socket.phase=nil
    local built, err=pcall(function()
        local io=socket:transport()
        M.rpc=require("bl.rpc").new(io,rpc_fd,function(body)
            return require("bl.repl").evaluate(body,{BL=M})
        end,{on_event=events("RPC")})
        M.ftp=require("bl.ftp_server").new(io,love.filesystem,
            ftp_fd,pasv_fd,socket.ip,PASV_PORT,nil,events("FTP"))
    end)
    if not built then
        socket:close(rpc_fd);socket:close(ftp_fd);socket:close(pasv_fd)
        log.log("[ERROR] server construction: "..tostring(err))
        return false
    end
    M.rpc_fd,M.ftp_fd,M.pasv_fd=rpc_fd,ftp_fd,pasv_fd
    log.log(("[NET] RPC %s:%d / FTP %s:%d / PASV :%d ready, no auth")
        :format(socket.ip or "?",REPL_PORT,socket.ip or "?",FTP_PORT,PASV_PORT))
    M.recovering,M.net_pending_logged,M.last_retry_error,M.io_errors,M.wake_pending=
        false,false,nil,0,false
    log.phase("net:serving")
    return true
end

local function bring_up()
    local ok_ffi,ffi=pcall(require,"ffi")
    if not ok_ffi then log.log("[ERROR] LuaJIT ffi unavailable");return false end
    M.ffi=ffi
    -- Run a one-shot binary probe if bl_probe.lua exists. The probe writes
    -- bl_diag.txt with raw bytes at key addresses, then deletes itself so it
    -- never runs twice. This is the mechanism for profiling a new game
    -- version without needing keys or an NSP decryptor.
    local probe_src = love.filesystem.read("bl_probe.lua")
    if probe_src then
        local probe_ok, probe_err = pcall(function()
            local fn = assert(loadstring(probe_src, "@bl_probe.lua"))
            fn(ffi, log)
        end)
        if not probe_ok then log.log("[PROBE] error: "..tostring(probe_err)) end
        pcall(love.filesystem.remove, "bl_probe.lua")
    end
    local info,why=resolve.resolve(ffi)
    if not info then
        -- Unknown binary: show the console with the manifest and the reason,
        -- but do NOT crash. The save is intact, the UI renders, and an
        -- operator can still read the log. This matters for sysNAND
        -- transfers and for Switch 2 compat-mode images we haven't profiled.
        log.log("[IMG] native path unavailable: "..tostring(why))
        log.log("[IMG] console UI is active; RPC/FTP require a known binary image")
        M.state = "ui-only"
        return false
    end
    M.info=info
    M.call=call.install(love,ffi,love.graphics.present,info)
    return start_network(ffi,info)
end

local function halt_network(why)
    log.log("[ERROR] network stopped: "..tostring(why))
    if M.rpc then pcall(M.rpc.close,M.rpc,"server stopped") end
    if M.ftp then pcall(M.ftp.close,M.ftp,"server stopped") end
    if M.net then
        for _,fd in ipairs({M.rpc_fd,M.ftp_fd,M.pasv_fd}) do
            if fd then pcall(M.net.close,M.net,fd) end
        end
    end
    M.rpc,M.ftp=nil,nil
    M.state="network-error"
end

local function reconnect(reason)
    if M.state~="serving" then return end
    log.log("[NET] rebinding after "..reason)
    if M.rpc then pcall(M.rpc.close,M.rpc,"network resume") end
    if M.ftp then pcall(M.ftp.close,M.ftp,"network resume") end
    if M.net then
        for _,fd in ipairs({M.rpc_fd,M.ftp_fd,M.pasv_fd}) do
            if fd then pcall(M.net.close,M.net,fd) end
        end
    end
    M.rpc,M.ftp,M.rpc_fd,M.ftp_fd,M.pasv_fd=nil,nil,nil,nil,nil
    M.state="connecting"
    M.recovering,M.net_pending,M.net_pending_logged=true,true,false
    M.net_retry=love.timer.getTime()+0.1
    M.io_errors=0
    log.phase("app:connecting")
end

local function visibility_event(visible)
    if not visible then M.was_hidden=true
    elseif M.was_hidden then M.was_hidden=false;M.wake_pending=true end
end

local function attempt(label,fn,...)
    local ok,result=pcall(fn,...)
    if not ok then
        log.log("[ERROR] "..label..": "..tostring(result))
        return false
    end
    return result == true
end

function M.tick(dt)
    hooks.verify()
    local monotonic=love.timer.getTime()
    local clock_ok,wall=pcall(os.time)
    if M.state=="serving" and
       ((M.last_tick and (monotonic<M.last_tick or monotonic-M.last_tick>8)) or
        (clock_ok and M.last_wall and wall-M.last_wall>8)) then
        M.wake_pending=true
    end
    M.last_tick,M.last_wall=monotonic,clock_ok and wall or nil
    if M.wake_pending and M.state=="serving" then
        M.wake_pending=false
        reconnect("sleep/wake or focus resume")
        return
    end
    if M.state=="first-frame" then
        if M.frame_ready then
            M.state="identifying"
            log.banner(resolve.version())
            log.log("[SYS] image identified; preparing network services")
        end
        return
    end
    if M.state=="identifying" then
        local started=attempt("startup",bring_up)
        M.state=started and "serving" or (M.net_pending and "connecting" or "network-error")
        log.phase("app:"..M.state)
    elseif M.state=="connecting" and love.timer.getTime()>=M.net_retry then
        local started=attempt("network retry",start_network,M.ffi,M.info)
        if started then M.state="serving";log.phase("app:serving")
        elseif not M.net_pending then M.state="network-error";log.phase("app:network-error") end
    end
    if M.state~="serving" then return end
    local rok,rstatus=pcall(M.rpc.step,M.rpc)
    if not rok then halt_network("RPC: "..tostring(rstatus));return end
    local fok,fstatus=pcall(M.ftp.step,M.ftp)
    if not fok then halt_network("FTP: "..tostring(fstatus));return end
    local bad_listener=(type(rstatus)=="string" and rstatus:find("^accept:")) or
                       (type(fstatus)=="string" and fstatus:find("^accept:"))
    M.io_errors=bad_listener and ((M.io_errors or 0)+1) or 0
    if M.io_errors>=3 then reconnect("repeated listener errors");return end
    for _,message in ipairs({rstatus,fstatus}) do
        if type(message)=="string" and
           (message:find("error",1,true) or message:find("invalid",1,true)) then
            log.log("[ERROR] "..message)
        end
    end
end

function M.boot()
    if rawget(_G,"__BL") then return rawget(_G,"__BL") end
    rawset(_G,"__BL",M)
    console.clock = M.clock
    hooks.install({update=M.tick,status=status,focus=visibility_event,
                   visible=visibility_event,
                   frame_drawn=function() M.frame_ready=true end})
    return M
end

return M
