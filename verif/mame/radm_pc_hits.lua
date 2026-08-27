local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local out = assert(io.open("scratch/radm_pc_hits.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_PCH_LAST")) or 900
local frame = 0
local targets = {[0x068216]=0, [0x068218]=0, [0x068236]=0, [0x068242]=0, [0x068278]=0, [0x0682a0]=0}
local seen_first = {}
local mem = cpu.spaces["program"]
for addr,_ in pairs(targets) do
  mem:install_read_tap(addr, addr+1, "t"..addr, function(offset, data, mask)
    targets[addr] = targets[addr] + 1
    if not seen_first[addr] then
      seen_first[addr] = frame
      out:write(string.format("FIRST addr=%06x frame=%d\n", addr, frame))
    end
    return data
  end)
end
_G.radm_pch_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    for addr,cnt in pairs(targets) do
      out:write(string.format("TOTAL addr=%06x count=%d\n", addr, cnt))
    end
    out:write(string.format("# done frame=%d\n", frame))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
