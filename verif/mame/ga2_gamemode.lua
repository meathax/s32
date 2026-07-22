-- Find ga2's game-mode variable: snapshot work RAM + screenshot at attract vs
-- the interactive PLAYER SELECT (reached via coin+start), so the Verilator sim
-- can probe the same variable to know when it reaches PLAYER SELECT.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local port = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = port.fields["Coin 1"]
local start = port.fields["1 Player Start"]
local p1    = manager.machine.ioport.ports[":mainpcb:P1_A"]
local b1    = p1 and p1.fields["P1 Button 1"] or nil

local function snap(tag)
  local f = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_wram_"..tag..".hex", "w")
  for a = 0x200000, 0x20ffff do f:write(string.format("%02x\n", msp:read_u8(a))) end
  f:close()
  manager.machine.video:snapshot()
end

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr == 250 then snap("attract250") end
  -- coin (long clean pulses), then start, then a button to confirm select
  if fr >= 300 and fr < 330 then coin:set_value(1) elseif fr == 330 then coin:set_value(0) end
  if fr >= 360 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 500 then manager.machine.video:snapshot() end
  if fr == 520 then snap("select520") end
  if fr > 540 and b1 and (fr % 20) < 4 then b1:set_value(1) elseif fr > 540 and b1 then b1:set_value(0) end
  if fr == 620 then manager.machine.video:snapshot() end
  if fr == 640 then snap("game640") end
end)
