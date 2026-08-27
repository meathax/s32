-- Enumerate ga2 input ports/fields so we can drive coin+start from Lua.
local f = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_ports.txt", "w")
for ptag, port in pairs(manager.machine.ioport.ports) do
  for fname, field in pairs(port.fields) do
    f:write(string.format("%s | %s\n", ptag, fname))
  end
end
f:close()
