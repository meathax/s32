-- Dump ga2 work RAM (0x200000-0x20FFFF) at frames 250/400/500/520 with input
-- EXACTLY matching the Verilator sim (coin held 300-390, start 430-450), so the
-- first frame of game-state divergence can be located.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]

local function snap(tag)
  local f = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_wram_"..tag..".hex", "w")
  for a = 0x200000, 0x20ffff do f:write(string.format("%02x\n", msp:read_u8(a))) end
  f:close()
  print("[wram] dumped "..tag)
end

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 250 then snap("250") end
  if fr == 400 then snap("400") end
  if fr == 500 then snap("500") end
  if fr == 520 then snap("520"); manager.machine.video:snapshot() end
end)
