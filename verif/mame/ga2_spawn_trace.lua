-- Find the spawn code that creates/activates the char-select objects: trace
-- writes to object[0].word0 (0x2005a0, the active-flag word that reads 0x8400 in
-- MAME but 0x56e0 in our sim) with PC + data, over PLAYER SELECT entry.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local log = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_spawn_trace.txt", "w")
local fr = 0
-- tap the whole first object record (0xA0 bytes) to see word0 + handler ptr writes
local tap = msp:install_write_tap(0x2005a0, 0x20063f, "spawn", function(offset, data, mask)
  local pc = cpu.state["PC"].value
  log:write(string.format("fr=%d pc=%06x off=%06x data=%04x\n", fr, pc, offset, data))
end)
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 505 then log:close(); print("[spawn] done"); manager.machine:exit() end
end)
