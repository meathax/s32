-- List all ga2 input ports and their fields (name -> mask) so we know which
-- bits are the magic button, attack, jump, and joystick directions.
local fr = 0
_G.t = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr ~= 10 then return end
  local out = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_inputs.txt","w")
  for pname, port in pairs(manager.machine.ioport.ports) do
    out:write("PORT "..pname.."\n")
    for fname, f in pairs(port.fields) do
      out:write(string.format("   mask=%04x  %s\n", f.mask, fname))
    end
  end
  out:flush()
  out:close()
  print("[inputs] done")
end)
