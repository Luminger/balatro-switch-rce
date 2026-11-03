return function(T,H)
    local check=T.check
    H.files["conf.lua"]="return 1"
    H.files["main.lua"]="return 2"
    local log=require("bl.log")
    local stamp=require("bl.stamp")
    local console=require("bl.console")
    console.clock=function() return "21:48:07" end
    local status="RPC 192.168.131.151:9026    FTP 192.168.131.151:5000"

    log.manifest={}
    for i=1,19 do
        log.manifest[i]={path=("bl/module_%02d.lua"):format(i),
                         hash=("%08x"):format(i*1234567),size=(i*811)%90000}
    end

    -- Switch 1 handheld/docked, Switch 2 handheld and a 4K docked output,
    -- plus a smaller-than-any-hardware fallback. The console is told its
    -- size by LOVE, so portability means surviving all of these.
    local modes={{1280,720},{1920,1080},{2560,1440},{3840,2160},{1024,576}}
    local sizes,prev_rows={},nil
    for _,m in ipairs(modes) do
        local w,h=m[1],m[2]
        love.graphics.getWidth=function() return w end
        love.graphics.getHeight=function() return h end
        log.lines={}
        for _,line in ipairs(stamp.manifest_lines(log.manifest,3)) do
            log.lines[#log.lines+1]=log.timestamp().."  [HASH] "..line
        end
        for i=1,120 do log.lines[#log.lines+1]=log.timestamp().."  [RPC] event "..i end
        H.printed={};H.rects={}
        console.draw(status)
        local L=console.layout
        local cell=console.metrics().cell
        local margin=math.max(12,math.floor(w*0.012))
        local overflow,footer,below=0,false,0
        for _,it in ipairs(H.printed) do
            if it.x+#it.text*cell>w-margin+1 then overflow=overflow+1 end
            if it.text:find("download at",1,true) then footer=true end
            if it.y>h then below=below+1 end
        end
        local tag=w.."x"..h
        check(tag..": nothing is drawn past the right margin",overflow==0,overflow)
        check(tag..": nothing is drawn below the screen",below==0,below)
        check(tag..": footer is present and flush",footer
              and L.floor+L.footer==h)
        check(tag..": log fills the viewport without a wasted row",
              L.rows==L.capacity and L.floor-L.last_bottom<L.step)
        check(tag..": hash rows stay inside the viewport",
              console.columns_for(w-2*margin)>60)
        -- Vertical centring must hold at every font size, so it is derived
        -- from the glyph height rather than a hand-tuned constant.
        local footer_item,bar_item
        for _,it in ipairs(H.printed) do
            if it.text:find("download at",1,true) then footer_item=it end
            if it.text:find("BALATRO",1,true) or it.text:find("BL//RCE",1,true) then
                bar_item=it
            end
        end
        local band_top=h-L.footer
        local above=footer_item.y-(band_top+1)
        local below=(band_top+L.footer)-(footer_item.y+L.glyph)
        check(tag..": footer text is vertically centred",
              math.abs(above-below)<=1,("above %d below %d"):format(above,below))
        local bar_above=bar_item.y
        local bar_below=(L.bar-2)-(bar_item.y+L.glyph)
        check(tag..": status bar text is vertically centred",
              math.abs(bar_above-bar_below)<=1,
              ("above %d below %d"):format(bar_above,bar_below))
        sizes[#sizes+1]={h=h,size=console.metrics().size,rows=L.capacity}
    end

    -- Taller displays must get BIGGER text, not merely more rows: a fixed
    -- cap made 4K output unreadable while still passing every fit check.
    table.sort(sizes,function(a,b) return a.h<b.h end)
    local scaled=true
    for i=2,#sizes do
        if sizes[i].size<sizes[i-1].size then scaled=false end
        if sizes[i].h>sizes[i-1].h and sizes[i].size<=sizes[i-1].size
           and sizes[i-1].h>=720 then scaled=false end
    end
    check("text scales up with display height",scaled,
          ("%d@%d .. %d@%d"):format(sizes[1].size,sizes[1].h,
                                    sizes[#sizes].size,sizes[#sizes].h))
    check("4K output uses a readable size",sizes[#sizes].size>=40,
          sizes[#sizes].size)
    check("row count stays sane at every size",
          sizes[1].rows>20 and sizes[#sizes].rows<120)
end
