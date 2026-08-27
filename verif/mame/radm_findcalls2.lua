local machine = manager.machine
local cpu = machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local out = assert(io.open("scratch/radm_findcalls2.txt", "w"))
local targets = {0x0767E4}
for base = 0x60000, 0x7ffff do
  local b0 = mem:read_u8(base)
  local b1 = mem:read_u8(base+1)
  local b2 = mem:read_u8(base+2)
  local b3 = mem:read_u8(base+3)
  local val24 = b0 + b1*256 + b2*65536
  local val32 = val24 + b3*16777216
  for _, t in ipairs(targets) do
    if val24 == t or val32 == t then
      out:write(string.format("MATCH at rom=%06x target=%06x bytes=%02x %02x %02x %02x\n",
        base, t, b0, b1, b2, b3))
    end
  end
end
out:close()
machine:exit()
