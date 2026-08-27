local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open("scratch/radm_wp_020_at_681fc.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_681FC_LAST")) or 30
local frame = 0
local n = 0
_G.radm_681fc_r = mem:install_read_tap(0x20f020, 0x20f021, "radm_681fc_r",
  function(offset, data, mask)
    local pc = cpu.state["PC"].value
    if pc == 0x0681fc then
      n = n + 1
      out:write(string.format("RD f=%d pc=%08x d=%04x\n", frame, pc, data & 0xffff))
    end
    return data
  end)
_G.radm_681fc_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    out:write(string.format("# done frame=%d n=%d\n", frame, n))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
