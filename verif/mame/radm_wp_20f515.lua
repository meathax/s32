local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open("scratch/radm_wp_20f515.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_515_LAST")) or 920
local frame = 0
_G.radm_515_r = mem:install_read_tap(0x20f514, 0x20f515, "radm_515_r",
  function(offset, data, mask)
    local pc = cpu.state["PC"].value
    if pc == 0x066245 then
      out:write(string.format("RD f=%d pc=%08x a=%06x d=%04x\n", frame, pc, offset, data & 0xffff))
    end
    return data
  end)
_G.radm_515_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    out:write(string.format("# done frame=%d val=%02x\n", frame, mem:read_u8(0x20f515)))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
