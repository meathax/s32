local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open("scratch/radm_caller_via_stack.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_CVS_LAST")) or 910
local frame = 0
local hits = 0
_G.radm_cvs_r = mem:install_read_tap(0x0767e4, 0x0767e5, "radm_cvs_r",
  function(offset, data, mask)
    if cpu.state["PC"].value == 0x0767e4 and hits < 20 then
      local sp = cpu.state["SP"].value
      local ret = mem:read_u32(sp)
      out:write(string.format("HIT f=%d pc=%08x sp=%08x ret=%08x\n", frame, cpu.state["PC"].value, sp, ret))
      hits = hits + 1
    end
    return data
  end)
_G.radm_cvs_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    out:write(string.format("# done frame=%d hits=%d\n", frame, hits))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
