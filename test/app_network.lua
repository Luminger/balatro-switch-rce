return function(T,H)
    local check=T.check
    local info={sdk_base=0x10000000,off=require("bl.offsets")["1.0.1f-FULL"].sdk}
    local function resolved()
        package.loaded["bl.resolve"]={version=function()return "1.0.1f-FULL" end,
            resolve=function()return info end}
    end
    local function frames(n)
        for _=1,n do pcall(love.update,1/60);pcall(love.draw) end
    end
    H.files["conf.lua"],H.files["main.lua"]="return 1","return 2"
    H.files["bl/app.lua"]="return 3"
    resolved()
    local starts,listeners,closes,unhealthy=0,0,0,false
    package.loaded["bl.socket"]={new=function()
        starts=starts+1
        return {ip="192.168.131.151",initialize=function()return true end,
            listener=function(_,port)listeners=listeners+1;return port end,
            close=function()closes=closes+1;return 0 end,
            transport=function()return {
                accept=function()return nil,unhealthy and "socket error" or "would_block" end,
                recv=function()return nil,"would_block" end,
                send=function()return nil,"would_block" end,
                close=function()return 0 end,
            }end}
    end}
    local app=require("bl.app").boot()
    function love.update()end
    function love.draw()end
    pcall(love.update,1/60);pcall(love.draw)
    -- The status bar is several draws at one y, so assertions read the whole
    -- row rather than a single index.
    local function bar()
        local row,y={},H.printed[1] and H.printed[1].y
        for _,item in ipairs(H.printed) do
            if item.y==y then row[#row+1]=item.text end
        end
        return table.concat(row," ")
    end
    check("first screen paints before fingerprint or SDK setup",app.state=="first-frame"
          and starts==0 and bar():find("BOOTING",1,true)
          and not H.log():find("%[BOOT%]"))
    pcall(love.update,1/60);pcall(love.draw)
    check("second frame draws build hashes before socket initialization",
          app.state=="identifying" and starts==0
          and #require("bl.log").manifest==3)
    H.printed={}
    pcall(love.update,1/60);pcall(love.draw)
    check("third frame starts all three listeners",app.state=="serving"
          and starts==1 and listeners==3 and type(love.ffi.invoke)=="function")
    local row=bar()
    -- Serving needs no "LIVE" label: the endpoints are the status. Each
    -- service carries its own address so a port is never shown alone.
    check("status bar shows brand, clock and both service addresses",
          row:find("BALATRO // SWITCH RCE",1,true)
          and row:find("RPC 192.168.131.151:9026",1,true)
          and row:find("FTP 192.168.131.151:5000",1,true)
          and row:match("%d%d:%d%d:%d%d")
          and not row:find("LIVE",1,true)
          and not row:find("draw")
          and not row:find("ffi"))
    check("ready line states no auth without editorialising",
          H.log():find("no auth",1,true)
          and not H.log():lower():find("trusted",1,true)
          and not H.log():lower():find("any host",1,true)
          and not H.log():lower():find("full control",1,true))
    frames(2)
    check("listeners are not reopened every frame",listeners==3)
    local again=require("bl.app").boot()
    check("conf/main re-entry is silent",again==app and app.loads==nil)

    local now=1.5
    love.timer.getTime=function()return now end
    love.focus(false);love.focus(true)
    frames(1)
    check("focus resume closes stale listeners and enters connecting",
          app.state=="connecting" and closes==3 and listeners==3)
    now=1.7
    frames(1)
    check("focus resume rebinds without title relaunch",
          app.state=="serving" and listeners==6 and starts==1)
    now=12
    frames(1)
    check("time gap detects sleep without a focus event",
          app.state=="connecting" and closes==6)
    now=12.3
    frames(1)
    check("wake gap rebinds all listeners",app.state=="serving"
          and listeners==9 and starts==1)
    unhealthy=true
    frames(3)
    check("persistent listener errors also trigger rebind",
          app.state=="connecting" and closes==9)
    unhealthy=false
    now=12.5
    frames(1)
    check("listener error recovery reuses initialized service",
          app.state=="serving" and listeners==12 and starts==1)

    H.install();H.reset_modules();resolved()
    package.loaded["bl.socket"]={new=function()return {
        initialize=function()return nil,"synthetic socket error" end}end}
    local failed=require("bl.app").boot()
    function love.update()end
    function love.draw()end
    frames(3)
    check("setup errors are visible, not a false serving state",
          failed.state=="network-error" and H.log():find("synthetic socket error"))

    H.install();H.reset_modules();resolved()
    local time,attempts,objects=1.5,0,0
    love.timer.getTime=function()return time end
    package.loaded["bl.socket"]={new=function()
        objects=objects+1
        return {ip="192.168.131.151",
            initialize=function()
                attempts=attempts+1
                if attempts==1 then return nil,"pending: no IP" end
                return true
            end,
            listener=function(_,port)return port end,
            close=function()return 0 end,
            transport=function()return {
                accept=function()return nil,"would_block" end,
                recv=function()return nil,"would_block" end,
                send=function()return nil,"would_block" end,
                close=function()return 0 end,
            }end}
    end}
    local waiting=require("bl.app").boot()
    function love.update()end
    function love.draw()end
    frames(3)
    check("network wait remains responsive",waiting.state=="connecting"
          and objects==1 and attempts==1)
    time=2
    frames(1)
    check("network ready without relaunch",waiting.state=="serving"
          and objects==1 and attempts==2)

end
