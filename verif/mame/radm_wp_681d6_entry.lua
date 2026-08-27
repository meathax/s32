local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open("scratch/radm_wp_681d6_entry.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_681D6E_LAST")) or 920
local frame = 0
_G.radm_681d6e_w = mem:install_write_tap(0x20f038, 0x20f039, "radm_681d6e_w",
  function(offset, data, mask)
    local pc = cpu.state["PC"].value
    out:write(string.format("WR f=%d pc=%08x a=%06x d=%04x\n", frame, pc, offset, data & 0xffff))
    return data
  end)
_G.radm_681d6e_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    out:write(string.format("# done frame=%d\n", frame))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
