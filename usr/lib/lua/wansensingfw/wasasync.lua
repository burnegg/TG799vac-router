local netlink=require("tch.netlink")

local runtime = { }
local cb
local timer

local M = {}

function M.init (rt, event_cb)
    -- intialize uloop
    runtime = rt

    cb = event_cb

end

function M.timerstart(timeout)
    -- create a timer to event timeout
    timer = runtime.uloop.timer(function () cb('timeout') end)
    timer:set(timeout)
end

function M.timerstop()
    if timer then
        timer:cancel()
    end
end

function M.start()
    local conn = runtime.ubus
    -- check connection with ubus
    if not conn then
        error("Failed to connect to ubusd")
    end

    -- register for ubus events
    local events = {}
    events['network.interface'] = function(msg)
        if msg and msg.interface and msg.action then
            cb('network_interface_' .. msg.interface:gsub('[^%a%d_]','_') .. '_' .. msg.action:gsub('[^%a%d_]','_'))
        end
    end

    events['xdsl'] = function(msg)
        if msg then
            cb('xdsl_' .. msg.statuscode)
        end
    end

     events['gpon.ploam'] = function(msg)
        if msg and msg.statuscode then
            if msg.statuscode ~= 5 then
                cb('gpon_ploam_0')
            end
         end
    end

     events['gpon.omciport'] = function(msg)
         if msg and msg.statuscode then
             cb('gpon_ploam_' .. msg.statuscode)
         end
     end


    conn:listen(events)

    --register for netlink events
    local nl,err = netlink.listen(function(dev, status)
        if status then
            cb('network_device_' .. dev .. '_up')
        else
            cb('network_device_' .. dev .. '_down')
        end
    end)
    if not nl then
        error("Failed to register with netlink" .. err)
    end

    runtime.uloop.run()
end

return M

