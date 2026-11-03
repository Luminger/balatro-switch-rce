return function(T,H)
    local check=T.check
    H.files["conf.lua"]="return 1"
    H.files["main.lua"]="return 2"
    H.files["bl/a.lua"]="return 3"
    local log=require("bl.log")
    log.banner("1.0.1f-FULL")
    check("branded identity and credit in file log",H.log():find("%[BOOT%]")
          and H.log():find("github.com/luminger",1,true))
    check("every log line carries a timestamp",(function()
        local n=0
        for line in H.log():gmatch("[^\n]+") do
            n=n+1
            if not line:match("^%d%d:%d%d:%d%d%.%d%d%d  ") then return false end
        end
        return n>0
    end)())
    check("screen log is stamped identically to the file",
          log.lines[1]:match("^%d%d:%d%d:%d%d%.%d%d%d  %[BOOT%]")~=nil)
    check("timestamps carry milliseconds, not an elapsed-seconds column",
          log.timestamp():match("^%d%d:%d%d:%d%d%.%d%d%d$")~=nil
          and not H.log():find("%d%.%ds  "))
    -- Stamps must never run backwards: the sub-second part is anchored to
    -- the monotonic timer rather than sampled from a second clock.
    check("timestamps are monotonic",(function()
        local prev=nil
        for i=1,8 do
            local now=log.timestamp()
            if prev and now<prev then return false end
            prev=now
        end
        return true
    end)())
    check("no boot count or uptime",not H.files["bl_boots.txt"]
          and not H.log():find("uptime") and not H.log():find("boot #"))
    check("manifest identifies installed Lua",#log.manifest==3 and log.build_id:match("^%x%x%x%x%x%x%x%x$"))
    check("file log retains per-file hashes",H.log():find("%[HASH%]")~=nil)
    local getDirectoryItems=love.filesystem.getDirectoryItems
    love.filesystem.getDirectoryItems=function(dir)
        if dir=="workers" then error("directory does not exist") end
        return getDirectoryItems(dir)
    end
    local id,n=require("bl.stamp").compute()
    check("missing old worker directory does not break fingerprint",id==log.build_id and n==3)
    love.filesystem.getDirectoryItems=getDirectoryItems
    log.phase("network:socket")
    check("phase breadcrumb persists",H.files["bl_phase.txt"]=="network:socket")
    check("contained Lua errors are logged",log.try("synthetic",function()error("boom")end)==nil
          and H.log():find("%[ERROR%] synthetic")~=nil)

    -- Layout contract: ONE status bar, then log. The manifest is log
    -- content, so no widget may sit between the bar and the first event.
    check("manifest hashes are ordinary log events",(function()
        for _,line in ipairs(log.lines) do
            if line:find("[HASH]",1,true) then return true end
        end
        return false
    end)())
    log.lines={}
    for i=1,180 do log.lines[i]=("event %03d"):format(i) end
    local console=require("bl.console")
    console.clock=function() return "12:34:56" end
    console.draw("RPC 192.168.131.151:9026    FTP 192.168.131.151:5000")
    local brand,credit,recent,evicted=false,false,false,true
    local bar_y=H.printed[1].y
    local clock_item,brand_item,state_item=nil,nil,nil
    for _,item in ipairs(H.printed) do
        if item.y~=bar_y then break end
        if item.text:find("BALATRO // SWITCH RCE",1,true) then brand=true;brand_item=item end

        if item.text:find("12:34:56",1,true) then clock_item=item end
        if item.text:find("RPC ",1,true) then state_item=item end
    end
    for _,item in ipairs(H.printed) do
        if item.text=="event 180" then recent=true end
        if item.text=="event 001" then evicted=false end
    end
    check("brand and endpoints share the status bar",brand and state_item~=nil)
    -- Credits are a pinned bottom-right footer, never a log event.
    local bottom_y,footer_item=0,nil
    for _,item in ipairs(H.printed) do
        if item.y>bottom_y then bottom_y=item.y end
    end
    for _,item in ipairs(H.printed) do
        if item.text:find("github.com/luminger",1,true) then footer_item=item end
    end
    check("credits are a footer at the bottom",footer_item
          and footer_item.y==bottom_y and footer_item.y>bar_y)
    -- The footer needs its own band and hairline, like the bar, or the text
    -- floats on the background. Both are full-width fills at the bottom.
    local band,rule=false,false
    for _,r in ipairs(H.rects or {}) do
        if r.x==0 and r.w==1280 and r.y<footer_item.y and r.y>bar_y then
            if r.h==1 then rule=true elseif r.h>=footer_item.y-r.y then band=true end
        end
    end
    check("footer has a background band",band)
    check("footer has a separator hairline",rule)
    -- The log must run up to the footer: a reserved bottom margin on top of
    -- the band wasted a whole row and left a visible dead strip.
    local L=console.layout
    check("footer sits flush with the bottom edge",
          L.footer>0 and L.floor+L.footer==love.graphics.getHeight())
    check("no wasted row between the log and the footer",
          L.floor-L.last_bottom<L.step,
          ("floor %d last %d step %d"):format(L.floor,L.last_bottom,L.step))
    check("log fills the viewport",L.rows==L.capacity and L.capacity>10)
    check("log viewport stops above the footer",(function()
        for _,item in ipairs(H.printed) do
            if item.text:find("^event ") and item.y>=footer_item.y then return false end
        end
        return true
    end)())
    check("credits footer is right-aligned",footer_item
          and footer_item.x+#footer_item.text*console.metrics().cell
              <=1280-math.floor(1280*0.012)+1
          and footer_item.x>1280*0.3)
    check("footer offers the project, spelled correctly, with no byline",
          footer_item
          and footer_item.text=="Free and open source, download at: "..
              "https://github.com/luminger/balatro-switch-rce"
          and not footer_item.text:lower():find("brakhane",1,true))
    check("credits are not a log event",(function()
        for _,line in ipairs(log.lines) do
            if line:find("CREDIT",1,true) then return false end
        end
        return true
    end)())
    credit=footer_item~=nil
    -- The clock belongs at the right edge, after everything else.
    local cellw=console.metrics().cell
    check("clock is right-aligned on the status bar",clock_item
          and clock_item.y==bar_y
          and clock_item.x>1280*0.75
          and clock_item.x+#clock_item.text*cellw<=1280-math.floor(1280*0.012)+1)
    check("brand sits left of the clock",brand_item and brand_item.x<clock_item.x)
    check("no LIVE label is rendered",(function()
        for _,item in ipairs(H.printed) do
            if item.text:find("LIVE",1,true) then return false end
        end
        return true
    end)())
    check("each service shows its own address and port",
          state_item.text:find("RPC 192.168.131.151:9026",1,true)
          and state_item.text:find("FTP 192.168.131.151:5000",1,true))
    check("old events evicted, latest event visible",evicted and recent)
    local first_event_y=nil
    for _,item in ipairs(H.printed) do
        if item.text:find("^event ") and (not first_event_y or item.y<first_event_y) then
            first_event_y=item.y
        end
    end
    local step=love.graphics.newFont(15):getHeight()+4
    check("log starts immediately below the bar",first_event_y
          and first_event_y-bar_y<=step*2+16,first_event_y)
    check("no pinned widget survives between bar and log",
          console.grid==nil)
    H.printed={}
    log.lines[181]="event 181"
    console.draw("RPC 192.168.131.151:9026    FTP 192.168.131.151:5000")
    check("status bar stays pinned when events advance",H.printed[1].y==bar_y)
    H.printed={}
    love.graphics.getWidth=function()return 1920 end
    love.graphics.getHeight=function()return 1080 end
    console.draw("RPC 192.168.131.151:9026    FTP 192.168.131.151:5000")

    -- Long RPC/FTP events must FOLD inside the viewport. Nothing may be
    -- drawn past the right margin, and the newest event must stay visible.
    local margin=math.max(12,math.floor(1920*0.012))
    local long="[RPC] call #7 192.168.128.6:52464 207B local l=require(\"bl.log\");"..
               "local out={};for i=math.max(1,#l.lines-14),#l.lines do out[#out+1]=l.lines[i] end"
    log.lines={}
    for i=1,6 do log.lines[i]=("event %03d"):format(i) end
    log.lines[7]=long
    H.printed={}
    console.draw("RPC 192.168.131.151:9026    FTP 192.168.131.151:5000")
    local cell=console.metrics().cell
    check("console renders with a monospace cell",console.metrics().mono and cell>0)
    local widest,folded_rows,tail_seen=0,0,false
    for _,item in ipairs(H.printed) do
        local right_edge=item.x+#item.text*cell
        widest=math.max(widest,right_edge)
        if item.text:find("%[RPC%] call #7") then folded_rows=folded_rows+1 end
        if item.text:find("l.lines[i] end",1,true) then tail_seen=true end
    end
    check("no drawn row overflows the window",widest<=1920-margin+1,widest)
    check("long RPC event is wrapped, not clipped",folded_rows==1 and tail_seen)
    -- Wrapping must break AFTER the tag, never inside the timestamp/tag
    -- prefix, so continuation rows start under the message text.
    local stamped="21:48:07.312  [RPC] call #7 192.168.128.6:52464 207B "..
                  "local l=require(\"bl.log\");local out={};return out"
    local tag_indent=console.indent_for(stamped,80)
    check("indent clears the timestamp and the tag",
          tag_indent==#"21:48:07.312  [RPC] "
          and stamped:sub(1,tag_indent):find("%[RPC%] $")~=nil
          and stamped:sub(tag_indent+1,tag_indent+4)=="call")
    local rows=console.fold(stamped,80,tag_indent)
    check("fold respects the column limit",rows and #rows>=2)
    local over=false
    for _,row in ipairs(rows or {}) do if #row>80 then over=true end end
    check("no folded row exceeds the limit",not over)
    check("continuation rows start under the message, past the tag",
          rows[2]:sub(1,tag_indent)==(" "):rep(tag_indent)
          and rows[2]:sub(tag_indent+1,tag_indent+1)~=" ")
    check("no continuation row repeats or splits the tag",
          not rows[2]:find("%[RPC%]") and not rows[2]:find("^%s*RPC%]"))
    check("untagged lines fall back to the stamp width",
          console.indent_for("21:48:07.312  plain text here",80)
              ==#"21:48:07.312  ")
    check("short lines are not folded",console.fold("event 001",80,14)==nil)
    local same=console.fold(stamped,80,tag_indent)
    check("folding is cached per width",same==rows)
end
