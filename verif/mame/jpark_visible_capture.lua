-- Capture Jurassic Park once the first gameplay sprite list reaches screen.
local machine = manager.machine
local cpu = machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local service_port = machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin = service_port.fields["Coin 1"]
local start = service_port.fields["1 Player Start"]
local frame = 0

local function dump()
    local spr = assert(io.open(
        "/mnt/d/Arcade/AI/s32/scratch/jpark_visible_spr.hex", "w"))
    for word = 0, 0xffff do
        spr:write(string.format("%04x\n",
            mem:read_u16(0x400000 + word * 2)))
    end
    spr:close()
    print("JPVISIBLE captured frame " .. frame)
end

_G.jpark_visible_capture_frames = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    coin:set_value(frame >= 120 and frame <= 124 and 1 or 0)
    start:set_value(frame >= 180 and frame <= 184 and 1 or 0)
    if frame == 193 then dump() end
    if frame == 194 then machine:exit() end
end)
