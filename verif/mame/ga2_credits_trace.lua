-- ga2 credits timing: log 0x20ac81 (credits) every frame 290-345 and 355-395,
-- with coin press at 300, release at 330 (second coin 360-390).
local OUT = "/mnt/d/Arcade/AI/s32/scratch/ga2_credit_trace.txt"
local frame = 0
local log = io.open(OUT, "w")

local function coin(v)
  manager.machine.ioport.ports[":mainpcb:SERVICE12_A"].fields["Coin 1"]:set_value(v)
end

_G.drive = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == 300 then coin(1) end
  if frame == 330 then coin(0) end
  if frame == 360 then coin(1) end
  if frame == 390 then coin(0) end
  if (frame >= 290 and frame <= 345) or (frame >= 355 and frame <= 395) then
    local mem = manager.machine.devices[":mainpcb:maincpu"].spaces["program"]
    local v = mem:read_u8(0x20ac81)
    local b380 = mem:read_u8(0x20b380)
    log:write(string.format("frame=%d credits=%d b380=%d\n", frame, v, b380))
  end
  if frame == 400 then
    log:close()
    print("TRACE DONE")
  end
end)
