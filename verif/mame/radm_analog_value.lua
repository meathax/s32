local machine = manager.machine
local ports = machine.ioport.ports
local out = assert(io.open("scratch/radm_analog_value.txt", "w"))
for name, port in pairs(ports) do
  if name:find("ANALOG") then
    local ok, val = pcall(function() return port:read() end)
    out:write(string.format("%s = %s (raw=%d)\n", name, tostring(val), ok and val or -1))
  end
end
out:close()
machine:exit()
