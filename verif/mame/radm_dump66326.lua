local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open("scratch/radm_dump66326.txt", "w"))
for i = 0, 7 do
  local addr = 0x066326 + i*2
  out:write(string.format("word@%06x = %04x\n", addr, mem:read_u16(addr)))
end
out:close()
machine:exit()
