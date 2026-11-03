-- Bounded main-thread FTP control/data state machine. The injected io
-- transport MUST be nonblocking; this file contains no native calls.
-- USER/PASS are accepted without being checked: there is no authentication.
-- STOR writes only launcher .lua paths (bl.ftp gate).
--
-- Concurrency: a small fixed number of control sessions, because one slot
-- made an abandoned client (a crashed script, a closed file manager) lock
-- the service out until its 15s timeout expired.
--
-- The passive listener is shared, so a data connection is bound to the
-- session whose control peer ADDRESS matches it, and connections that match
-- nobody are accepted and dropped. Without that, a connection left queued
-- in the listener backlog by an abandoned transfer was handed to the next
-- transfer, which then reported a successful send into a dead socket while
-- the real client waited forever.
local ftp = require("bl.ftp")
local M = {}
local CHUNK, MAX_COMMAND, DATA_WAIT = 4096, 8192, 15
local MAX_SESSIONS = 4

-- "192.168.1.5:51000" -> "192.168.1.5". Ports differ between the control
-- and data connections, so only the address may be compared.
local function host_of(peer)
    if type(peer) ~= "string" then return nil end
    return peer:match("^([^:]+):") or peer
end

function M.new(io, fs, control_listener, passive_listener, ip, passive_port, clock, on_event)
    assert(io and fs and control_listener and passive_listener and ip and passive_port)
    clock = clock or function() return love.timer.getTime() end
    local self = { io=io, fs=fs, control_listener=control_listener,
                   passive_listener=passive_listener, client=nil,
                   sessions={}, transfers=0, commands=0, max_sessions=MAX_SESSIONS }
    local function emit(kind, detail)
        if on_event then pcall(on_event,kind,detail) end
    end
    local function enqueue(st, line)
        st.out = st.out .. line .. "\r\n"
    end
    local function drop_data(st, reason)
        if st.data_fd then
            io.close(st.data_fd)
            emit("data-disconnect", ("%s fd=%s %s"):format(
                st.data_peer or "peer unknown",tostring(st.data_fd),reason or "done"))
            st.data_fd=nil
        end
        st.data_peer=nil
        st.plan, st.pasv = nil, false
        st.parts, st.total, st.data_pos = nil, nil, nil
    end
    local function forget(st, reason)
        drop_data(st,reason)
        io.close(st.fd)
        for i,other in ipairs(self.sessions) do
            if other==st then table.remove(self.sessions,i); break end
        end
        if self.client==st then self.client=self.sessions[1] end
        emit("disconnect", ("%s fd=%s %s"):format(
            st.peer or "peer unknown",tostring(st.fd),reason or "done"))
    end

    -- close(reason) keeps its single-session meaning for the ACTIVE session.
    function self:close(reason)
        local st = self.client
        if not st then return end
        forget(st, reason)
    end

    function self:close_all(reason)
        while self.sessions[1] do forget(self.sessions[1], reason) end
    end

    -- Accept and discard every connection queued on the passive listener
    -- that no session is waiting for. Runs when a session arms a transfer,
    -- so a stale connection can never be mistaken for the real client.
    local function purge_passive(expect_host)
        local dropped = 0
        for _ = 1, 8 do
            local fd, peer = io.accept(self.passive_listener)
            if not fd then break end
            if expect_host and host_of(peer) == expect_host then
                return fd, peer, dropped
            end
            io.close(fd)
            dropped = dropped + 1
            emit("data-disconnect", ("%s stale queued data connection dropped")
                :format(peer or "peer unknown"))
        end
        return nil, nil, dropped
    end
    self.purge_passive = purge_passive

    local function accept_control()
        local fd, peer_or_err = io.accept(self.control_listener)
        if not fd then
            return peer_or_err == "would_block" and "idle"
                or "accept: " .. tostring(peer_or_err)
        end
        if #self.sessions >= self.max_sessions then
            -- Refuse politely rather than silently queueing: the client sees
            -- a status instead of a hang, and existing transfers continue.
            io.send(fd,"421 too many connections\r\n")
            io.close(fd)
            emit("error",("refused %s: %d/%d sessions busy"):format(
                tostring(peer_or_err),#self.sessions,self.max_sessions))
            return "refused"
        end
        local st = {fd=fd,peer=peer_or_err,core=ftp.new(fs,{ip=ip,port=passive_port}),
                    input="",out="",plan=nil,data_fd=nil,pasv=false,
                    closing=false,parts=nil,total=0,data_pos=1}
        self.sessions[#self.sessions+1]=st
        self.client=st
        emit("connect", ("%s fd=%s %d/%d"):format(peer_or_err or "peer unknown",
            tostring(fd),#self.sessions,self.max_sessions))
        enqueue(st,"220 Balatro launcher FTP")
        return "accepted"
    end

    -- One session's bounded slice of work.
    local function advance(st)
        self.client = st

        -- Drain one bounded control write per frame. Send the 150 response
        -- before accepting/transferring passive data, as ordinary FTP
        -- clients wait for that status before opening their data socket.
        if #st.out > 0 then
            local n, err = io.send(st.fd, st.out:sub(1,CHUNK))
            if not n then
                if err=="would_block" then return "waiting-control" end
                forget(st,"control send: " .. tostring(err))
                return "control send: " .. tostring(err)
            end
            if n <= 0 or n > math.min(#st.out,CHUNK) then
                forget(st,"bad control send count");return "bad control send count"
            end
            st.out = st.out:sub(n+1)
            return "control-written"
        end
        if st.closing then forget(st,"QUIT");return "closed" end

        if st.plan then
            if not st.data_fd then
                if clock() - st.plan_started > DATA_WAIT then
                    forget(st,"PASV data timeout")
                    return "data-timeout"
                end
                -- Only a connection from this session's control address is
                -- accepted; anything else queued is stale and is discarded.
                local fd, peer_or_err = purge_passive(host_of(st.peer))
                if not fd then return "waiting-data" end
                st.data_fd,st.data_peer=fd,peer_or_err
                emit("data-connect", ("%s fd=%s"):format(peer_or_err or "peer unknown",tostring(fd)))
                st.parts,st.total,st.data_pos={},0,1
                return "data-accepted"
            end
            if st.plan.op=="send" then
                local data=st.plan.data or ""
                if st.data_pos > #data then
                    emit("transfer", ("RETR/LIST %s %dB"):format(st.plan.path or "/",#data))
                    drop_data(st);self.transfers=self.transfers+1
                    enqueue(st,"226 transfer complete")
                    return "data-sent"
                end
                local n,err=io.send(st.data_fd,data:sub(st.data_pos,st.data_pos+CHUNK-1))
                if not n then
                    if err=="would_block" then return "waiting-data" end
                    emit("error","data send: "..tostring(err))
                    drop_data(st,"send error");enqueue(st,"426 data send failed")
                    return "data-send-error"
                end
                if n<=0 or n>math.min(CHUNK,#data-st.data_pos+1) then
                    emit("error","bad data send count")
                    drop_data(st,"send error");enqueue(st,"426 bad data send count")
                    return "data-send-error"
                end
                st.data_pos=st.data_pos+n
                return "data-writing"
            end
            if st.plan.op=="receive" then
                local data,err=io.recv(st.data_fd,CHUNK)
                if not data then
                    if err=="would_block" then return "waiting-data" end
                    emit("error","data recv: "..tostring(err))
                    drop_data(st,"recv error");enqueue(st,"426 data recv failed")
                    return "data-recv-error"
                end
                if #data>0 then
                    st.total=st.total+#data
                    if st.total>st.plan.max_bytes then
                        emit("error","STOR exceeded upload limit")
                        drop_data(st,"oversize");enqueue(st,"552 upload too large")
                        return "oversize"
                    end
                    st.parts[#st.parts+1]=data
                    return "data-reading"
                end
                local result=st.plan.complete(table.concat(st.parts))
                emit("transfer", ("STOR %s %dB %s"):format(
                    st.plan.path or "?",st.total,tostring(result)))
                drop_data(st)
                self.transfers=self.transfers+1
                enqueue(st,result)
                return "data-received"
            end
            drop_data(st);enqueue(st,"451 unknown transfer")
            return "bad-plan"
        end

        -- Process at most ONE command per frame. Input may contain many
        -- commands; leftover lines remain buffered for subsequent frames.
        local newline=st.input:find("\n",1,true)
        if not newline then
            local data,err=io.recv(st.fd,CHUNK)
            if not data then
                if err=="would_block" then return "waiting-control" end
                forget(st,"control recv: " .. tostring(err))
                return "control recv: " .. tostring(err)
            end
            if #data==0 then forget(st,"client EOF");return "control-eof" end
            st.input=st.input..data
            if #st.input>MAX_COMMAND then
                enqueue(st,"500 command too long")
                st.input="";st.closing=true
                return "command-overflow"
            end
            return "control-read"
        end
        local line=st.input:sub(1,newline-1):gsub("\r$","")
        st.input=st.input:sub(newline+1)
        local command=(line:match("^(%a+)") or "?"):upper()
        local preview=command=="PASS" and "PASS [redacted]" or
                      line:gsub("[%c]"," "):sub(1,160)
        emit("command", ("%s %s"):format(st.peer or "peer unknown",preview))
        local reply,plan=st.core:handle(line)
        self.commands=self.commands+1
        if reply:match("^227 ") then st.pasv=true end
        if reply:match("^227 ") then
            -- Arming a passive transfer: clear anything already queued, so a
            -- connection from an abandoned session cannot be mistaken for
            -- this client's.
            local _,_,dropped=purge_passive(nil)
            if dropped>0 then
                emit("error",("discarded %d stale data connection(s)"):format(dropped))
            end
        end
        if plan and (plan.op=="send" or plan.op=="receive") then
            if not st.pasv then enqueue(st,"425 use PASV first");return "need-pasv" end
            st.plan=plan
            st.plan_started=clock()
        elseif plan and plan.op=="close" then
            st.closing=true
        end
        enqueue(st,reply)
        return "command"
    end

    -- Round-robin so one busy transfer cannot starve another session, and a
    -- new client is accepted even while transfers are in flight.
    function self:step()
        if #self.sessions == 0 then return accept_control() end
        local outcome = "idle"
        self.cursor = ((self.cursor or 0) % #self.sessions) + 1
        local st = self.sessions[self.cursor]
        if st then outcome = advance(st) end
        -- Always accept, even at the cap: a refused client must receive a
        -- status and a close rather than hang in the listener backlog.
        local accepted = accept_control()
        if accepted ~= "idle" then return accepted end
        return outcome
    end

    function self:sessions_open() return #self.sessions end
    return self
end

return M
