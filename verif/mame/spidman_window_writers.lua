-- Histogram the V60 PCs that populate waiting-object camera windows.
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local frame = 0
local writers = {}

_G.spid_window_writers = mem:install_write_tap(0x206000, 0x207FFF, "spid_window_writers",
    function(offset, data, mask)
        local slot_off = offset & 0x3F
        if slot_off >= 0x38 then
            local pc = cpu.state["PC"].value
            local key = string.format("%06x->%02x", pc, slot_off)
            writers[key] = (writers[key] or 0) + 1
        end
    end)

_G.spid_window_writer_frames = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == 6000 then
        print("WINWRITERS begin")
        for key, n in pairs(writers) do print(string.format("WINWRITER %s x%d", key, n)) end
        print("WINWRITERS end")
        manager.machine:exit()
    end
end)
