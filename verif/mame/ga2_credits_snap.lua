-- ga2 credits finder: snapshot work RAM (0x200000-0x20ffff) at f250 (0 credits),
-- f345 (after coin1: expect 1 credit), f430 (after coin2: expect 2 credits).
-- Coin held frames 300-330 and 360-390 (proven-working recipe).
local OUT = "/mnt/d/Arcade/AI/s32/scratch/"
local frame = 0

local function snap(name)
  local mem = manager.machine.devices[":mainpcb:maincpu"].spaces["program"]
  local t = {}
  for a = 0x200000, 0x20ffff do
    t[#t + 1] = string.char(mem:read_u8(a))
  end
  local f = io.open(OUT .. name, "wb")
  f:write(table.concat(t))
  f:close()
  print("SNAP " .. name .. " frame=" .. frame)
end

local function coin(v)
  manager.machine.ioport.ports[":mainpcb:SERVICE12_A"].fields["Coin 1"]:set_value(v)
end

_G.drive = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == 250 then snap("ga2_wram_f250.bin") end
  if frame == 300 then coin(1) end
  if frame == 330 then coin(0) end
  if frame == 345 then snap("ga2_wram_f345.bin") end
  if frame == 360 then coin(1) end
  if frame == 390 then coin(0) end
  if frame == 430 then
    snap("ga2_wram_f430.bin")
    print("DONE")
  end
end)
