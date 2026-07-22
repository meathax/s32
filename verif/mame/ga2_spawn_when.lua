-- Poll obj[8].word0 (0x2005a0) + handler every frame; log the frame where it
-- transitions to active (0x8400) — the spawn moment — plus PC at that frame.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local log = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_spawn_when.txt","w")
local fr = 0
local prev = -1
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  local w0 = msp:read_u16(0x2005a0)
  if w0 ~= prev then
    log:write(string.format("fr=%d obj8.word0: %04x -> %04x  handler=%08x\n",
      fr, prev & 0xffff, w0, msp:read_u32(0x2005a2)))
    log:flush()
    prev = w0
  end
  if fr == 505 then log:close(); print("[when] done"); manager.machine:exit() end
end)
