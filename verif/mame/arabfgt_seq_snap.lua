-- Dense attract snapshots for frame-matching against MiSTer captures.
local mac = manager.machine
local n = 0
_G.__seq = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n > 300 and n % 20 == 0 then mac.video:snapshot() end
end)
