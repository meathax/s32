-- At a PLAYER SELECT build frame, dump R25 (object-array base pointer) and the
-- first several object slots (word0 active-flag + handler ptr) so we can see
-- which slots MAME activates. Also disassemble-independent: read via R25-0x7F60.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 480 then
    local r25 = cpu.state["R25"].value
    local base = (r25 - 0x7F60) & 0xffffffff
    local f = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_r25.txt","w")
    f:write(string.format("R25=%08x  objbase(R25-7F60)=%08x\n", r25, base))
    for i=0,15 do
      local a = base + i*0xA0
      local w0 = msp:read_u16(a)
      local hnd = msp:read_u32(a+2)
      f:write(string.format("obj[%2d] @%06x word0=%04x active(b15)=%d handler=%08x\n",
        i, a, w0, (w0>>15)&1, hnd))
    end
    f:close(); print("[r25] done"); manager.machine:exit()
  end
end)
