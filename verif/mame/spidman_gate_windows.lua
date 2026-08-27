-- Spider-Man attract-mode reference: dump each unique waiting object's camera
-- window the first time the 0x087A99 spawn gate evaluates it.
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local frame, count = 0, 0
local seen = {}

_G.spid_gate_windows = mem:install_read_tap(0x208346, 0x208347, "spid_gate_windows",
    function(offset, data, mask)
        if cpu.state["PC"].value == 0x087A99 then
            local r20 = cpu.state["R20"].value
            if not seen[r20] and count < 256 then
                seen[r20] = true
                count = count + 1
                print(string.format(
                    "GATEWIN f=%d r20=%08x x=%04x..%04x y=%04x..%04x cam=%08x",
                    frame, r20, mem:read_u16(r20 + 0x3A), mem:read_u16(r20 + 0x38),
                    mem:read_u16(r20 + 0x3E), mem:read_u16(r20 + 0x3C),
                    mem:read_u32(0x208344)))
            end
        end
    end)

_G.spid_gate_frames = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == 2000 then
        print(string.format("GATEWIN DONE count=%d", count))
        manager.machine:exit()
    end
end)
