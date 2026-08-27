-- Characterize arabfgt V25 protection: static or dynamic?
-- Log the mailbox addresses+values the V60 READS, and any WRITES (commands),
-- over frames 100-103 of the deck demo. Read-values changing frame-to-frame or
-- any V60 writes => dynamic protection (HLE canned tables can't reproduce it).
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local msp = cpu.spaces["program"]
local fr = 0
local out = io.open("/mnt/d/Arcade/AI/s32/scratch/arab_protchar.txt", "w")
local logging = false
msp:install_read_tap(0xA00000, 0xA00FFF, "mbrd", function(offset, data, mask)
  if logging then out:write(string.format("f=%d RD %06x = %04x\n", fr, offset, data)) end
end)
msp:install_write_tap(0xA00000, 0xA00FFF, "mbwr", function(offset, data, mask)
  if logging then out:write(string.format("f=%d WR %06x = %04x\n", fr, offset, data)) end
end)
_G.t = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  logging = (fr >= 100 and fr <= 103)
  if fr == 104 then print("[protchar] done"); out:close(); manager.machine:exit() end
end)
