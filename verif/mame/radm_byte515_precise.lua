local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open("scratch/radm_byte515_precise.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_B515_LAST")) or 12
local frame = 0
_G.radm_b515_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    out:write(string.format("f=%d byte515=%02x byte514=%02x word514=%04x\n",
      frame, mem:read_u8(0x20f515), mem:read_u8(0x20f514), mem:read_u16(0x20f514)))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
