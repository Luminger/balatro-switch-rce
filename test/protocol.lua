return function(T,H)
    local check=T.check
    local repl=require("bl.repl")
    check("REPL evaluates a chunk",repl.evaluate("return 2+2"):find("-> 4")~=nil)
    check("REPL contains compile/runtime failures",repl.evaluate("((("):find("compile error")
          and repl.evaluate('error("boom")'):find("boom"))

    local incoming={"return 2","+2",nil,""}
    local read_idx,accepted,sent,closed,events=0,false,"",0,{}
    local io={
        accept=function()
            if accepted then return nil,"would_block" end
            accepted=true;return 7,"192.168.131.20:12345"
        end,
        recv=function()
            read_idx=read_idx+1
            local chunk=incoming[read_idx]
            return chunk==nil and nil or chunk,chunk==nil and "would_block" or nil
        end,
        send=function(_,text)
            local n=math.min(2,#text);sent=sent..text:sub(1,n);return n
        end,
        close=function()closed=closed+1 end,
    }
    local rpc=require("bl.rpc").new(io,99,repl.evaluate,
        {on_event=function(kind,detail)events[#events+1]=kind.." "..detail end})
    rpc:step();rpc:step();rpc:step();rpc:step()
    check("RPC waits for half-close before evaluation",rpc.handled==0)
    rpc:step()
    for _=1,30 do rpc:step();if not rpc.client then break end end
    check("RPC handles chunk, partial response, closes client",sent:find("-> 4",1,true)
          and rpc.handled==1 and closed==1)
    local joined=table.concat(events,"\n")
    check("RPC logs peer connect/call/reply/disconnect",joined:find("connect.*192.168.131.20")
          and joined:find("call.*return 2%+2") and joined:find("reply")
          and joined:find("disconnect.*192.168.131.20"))

    H.files["bl/app.lua"]="old"
    H.files["main.lua"]="return 1"
    H.files["bl_log.txt"]="log evidence"
    local fs=love.filesystem
    local getInfo=fs.getInfo
    fs.getInfo=function(p)
        if p=="bl" or p=="workers" or p=="bl/assets" then
            return {type="directory",size=0} end
        return getInfo(p)
    end
    local ftp=require("bl.ftp").new(fs,{ip="192.168.131.151",port=5001})
    check("FTP advertises PASV",ftp:handle("PASV"):find("192,168,131,151,19,137")~=nil)
    check("FTP blocks traversal and log overwrite",ftp:handle("STOR /../main.lua")=="550 invalid path"
          and ftp:handle("STOR /bl_log.txt")=="550 invalid path")
    local r,plan=ftp:handle("RETR bl_log.txt")
    check("FTP can retrieve persistent log",r:find("150") and plan.data=="log evidence")
    local _,upload=ftp:handle("STOR /bl/updated.lua")
    check("FTP can write launcher module",upload.complete("return 42")=="226 stored"
          and H.files["bl/updated.lua"]=="return 42")
    -- The console font ships in savedata and must be self-updatable exactly
    -- like code, without widening the allowlist to arbitrary savedata.
    local _,fontput=ftp:handle("STOR /bl/assets/mono.ttf")
    check("FTP can replace the bundled console font",
          fontput and fontput.complete("\0\1fontbytes")=="226 stored"
          and H.files["bl/assets/mono.ttf"]=="\0\1fontbytes")
    check("FTP still refuses non-asset binaries and game saves",
          ftp:handle("STOR /bl/assets/payload.so")=="550 invalid path"
          and ftp:handle("STOR /save.jkr")=="550 invalid path")
    local _,assetlist=ftp:handle("LIST /bl/assets")
    check("FTP lists the asset directory",assetlist and assetlist.data~=nil)
    local _,list=ftp:handle("LIST /bl")
    check("FTP LIST has Unix-style rows",list.data:find("%-rw%-r%-%-r%-%-")
          and list.data:find("updated.lua"))

    local ctl="USER nx\r\nPASS secret\r\nPASV\r\nSTOR /bl/fromftp.lua\r\n"..
              "PASV\r\nRETR /bl/fromftp.lua\r\nQUIT\r\n"
    local uploaded={"return 7",""}
    local output,data_output,closedfds,events_ftp="","",{},{ }
    local got_ctl,data_clients=false,0
    -- A real client opens its data socket only AFTER it reads the 227
    -- reply, and the listener reports would_block until then. Modelling
    -- that is what makes stale-backlog handling testable at all.
    local function passive_offers()
        local sent=select(2,output:gsub("227 ",""))
        return sent>data_clients
    end
    local fake={
        accept=function(fd)
            if fd==100 then
                if got_ctl then return nil,"would_block" end
                got_ctl=true;return 11,"192.168.131.20:12345"
            end
            if not passive_offers() then return nil,"would_block" end
            data_clients=data_clients+1
            return 11+data_clients,"192.168.131.20:12346"
        end,
        recv=function(fd)
            if fd==11 then
                if ctl=="" then return nil,"would_block" end
                local bytes=ctl;ctl="";return bytes
            end
            if fd==12 then return table.remove(uploaded,1) or "" end
            return "","eof"
        end,
        send=function(fd,text)
            local n=fd==11 and #text or math.min(3,#text)
            if fd==11 then output=output..text:sub(1,n)
            else data_output=data_output..text:sub(1,n) end
            return n
        end,
        close=function(fd)closedfds[#closedfds+1]=fd end,
    }
    local server=require("bl.ftp_server").new(fake,fs,100,101,
        "192.168.131.151",5001,nil,
        function(kind,detail)events_ftp[#events_ftp+1]=kind.." "..detail end)
    for _=1,120 do server:step();if closedfds[#closedfds]==11 then break end end
    check("FTP serves more than one control session",server.max_sessions>=2)
    check("FTP PASV STOR/RETR roundtrip survived partial data sends",
          server.transfers==2 and H.files["bl/fromftp.lua"]=="return 7"
          and data_output=="return 7" and output:find("226 stored"))
    check("FTP closed both data clients and control",#closedfds==3 and closedfds[3]==11)
    local trace=table.concat(events_ftp,"\n")
    check("FTP logs peers, commands, transfer counts and disconnects",
          trace:find("connect.*192.168.131.20")
          and trace:find("command.*STOR /bl/fromftp.lua")
          and trace:find("transfer.*STOR.*8B")
          and trace:find("data%-disconnect")
          and trace:find("disconnect.*192.168.131.20"))
    check("FTP PASS input is redacted",trace:find("PASS %[redacted%]")
          and not trace:find("secret",1,true))

    -- Regression: a connection left queued on the shared passive listener by
    -- an abandoned transfer used to be handed to the NEXT transfer, which
    -- reported a successful send into a dead socket while the real client
    -- waited forever. Stale connections must be dropped, and a transfer may
    -- only bind a data connection from its own control address.
    do
        local closed,sent,evts={},{},{}
        local ctl2="USER nx\r\nPASV\r\nRETR /bl/fromftp.lua\r\n"
        local offered,accepted_ctl=false,false
        local queue={{fd=70,peer="10.0.0.9:5555"},
                     {fd=71,peer="192.168.131.20:6001"}}
        local io2={
            accept=function(fd)
                if fd==100 then
                    if accepted_ctl then return nil,"would_block" end
                    accepted_ctl=true;return 11,"192.168.131.20:12345"
                end
                if not offered then return nil,"would_block" end
                local nxt=table.remove(queue,1)
                if not nxt then return nil,"would_block" end
                return nxt.fd,nxt.peer
            end,
            recv=function(fd)
                if fd==11 then
                    if ctl2=="" then return nil,"would_block" end
                    local b=ctl2;ctl2="";return b
                end
                return nil,"would_block"
            end,
            send=function(fd,text)
                sent[fd]=(sent[fd] or "")..text
                if fd==11 and text:find("227 ") then offered=true end
                return #text
            end,
            close=function(fd)closed[#closed+1]=fd end,
        }
        local srv2=require("bl.ftp_server").new(io2,fs,100,101,
            "192.168.131.151",5001,nil,
            function(k,d)evts[#evts+1]=k.." "..d end)
        for _=1,80 do srv2:step();if (sent[71] or ""):find("return 7") then break end end
        local log2=table.concat(evts,"\n")
        check("stale queued data connection is never written to",sent[70]==nil)
        check("stale queued data connection is reported and closed",
              log2:find("stale queued data connection")~=nil
              and (function() for _,fd in ipairs(closed) do
                     if fd==70 then return true end end return false end)())
        check("transfer binds the data connection from its own address",
              (sent[71] or ""):find("return 7",1,true)~=nil)
    end

    -- A second client must be accepted rather than hang, and the cap must be
    -- enforced with a status instead of a silent queue.
    do
        local sent,closed={},{}
        local next_fd=20
        local io3={
            accept=function(fd)
                if fd~=100 then return nil,"would_block" end
                next_fd=next_fd+1
                if next_fd>26 then return nil,"would_block" end
                return next_fd,("192.168.131.%d:5000"):format(next_fd)
            end,
            recv=function() return nil,"would_block" end,
            send=function(fd,text) sent[fd]=(sent[fd] or "")..text;return #text end,
            close=function(fd) closed[#closed+1]=fd end,
        }
        local srv3=require("bl.ftp_server").new(io3,fs,100,101,
            "192.168.131.151",5001,nil,function()end)
        for _=1,60 do srv3:step() end
        check("multiple control sessions are served concurrently",
              srv3:sessions_open()==srv3.max_sessions and srv3.max_sessions>1)
        local refused=false
        for _,text in pairs(sent) do
            if text:find("421 too many connections",1,true) then refused=true end
        end
        check("sessions beyond the cap are refused with a status",refused)
        check("refused sessions are closed, not leaked",#closed>0)
    end
end
