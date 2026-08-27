local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open("scratch/radm_wp_20f515_writes.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_515W_LAST")) or 10
local frame = 0
_G.radm_515w_w = mem:install_write_tap(0x20f514, 0x20f515, "radm_515w_w",
  function(offset, data, mask)
    out:write(string.format("WR f=%d pc=%08x a=%06x d=%04x mask=%04x\n", frame, cpu.state["PC"].value, offset, data & 0xffff, mask))
    return data
  end)
_G.radm_515w_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    out:write(string.format("# done frame=%d\n", frame))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
