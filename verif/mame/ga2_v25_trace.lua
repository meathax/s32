-- Reference capture for the real-V25 replay comparison.
-- ga2's V60 never writes the MB8421 mailbox; the V25 (mcu) writes it proactively.
-- Log every V25 write (off,data,frame) + the final DPRAM, so our real V25
-- (s32_v25_cpu) can be checked to produce the identical output.
local mcu = manager.machine.devices[":mainpcb:mcu"]
local vp  = mcu.spaces["program"]
local mc  = manager.machine.devices[":mainpcb:maincpu"]
local mp  = mc.spaces["program"]
local svc = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin, start = svc.fields["Coin 1"], svc.fields["1 Player Start"]
local fr, nv25, nv60 = 0, 0, 0

_G.t_v25 = vp:install_write_tap(0x10000, 0x1ffff, "v25", function(off, data, mask)
  nv25 = nv25 + 1
  print(string.format("V25w fr=%d off=%03x data=%02x", fr, (off-0x10000)&0x7ff, data&0xff))
end)
_G.t_v60 = mp:install_write_tap(0xa00000, 0xa00fff, "v60", function(off, data, mask)
  nv60 = nv60 + 1
  print(string.format("V60w fr=%d off=%03x data=%02x", fr, (off-0xa00000)&0x7ff, data&0xff))
end)

_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 60 and fr < 90 then coin:set_value(1) elseif fr == 90 then coin:set_value(0) end
  if fr >= 120 and fr < 150 then start:set_value(1) elseif fr == 150 then start:set_value(0) end
  if fr == 260 then
    local s = ""
    for o = 0, 0x7ff do s = s .. string.format("%02x", mp:read_u8(0xa00000 + o*2)) end
    print("DPRAMFINAL " .. s)
    print(string.format("SUMMARY v25writes=%d v60writes=%d", nv25, nv60))
    manager.machine:exit()
  end
end)
