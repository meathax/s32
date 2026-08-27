-- Snapshot Arabian Fight attract screens for PCB/core comparison.
local mac = manager.machine
local coin = nil
for _, port in pairs(mac.ioport.ports) do
    for name, field in pairs(port.fields) do
        if name == "Coin 1" then coin = field end
    end
end
local snaps = { [420]=true, [640]=true, [900]=true, [1200]=true, [1500]=true, [1800]=true, [2100]=true }
local n = 0
_G.__tap = emu.add_machine_frame_notifier(function()
    n = n + 1
    if coin then
        if (n >= 120 and n <= 126) or (n >= 160 and n <= 166) or
           (n >= 200 and n <= 206) or (n >= 240 and n <= 246) then
            coin:set_value(1)
        else
            coin:set_value(0)
        end
    end
    if snaps[n] then
        mac.video:snapshot()
        print(string.format("SNAP frame=%d", n))
    end
end)
