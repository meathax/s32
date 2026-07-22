-- Insert a coin and snapshot the screen to confirm the game advances.
local port  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = port.fields["Coin 1"]
local start = port.fields["1 Player Start"]
local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  -- long, clean coin pulses
  if fr >= 300 and fr < 330 then coin:set_value(1) elseif fr == 330 then coin:set_value(0) end
  if fr >= 360 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 480 and fr < 500 then start:set_value(1) elseif fr == 500 then start:set_value(0) end
  if fr == 250 or fr == 450 or fr == 700 or fr == 1000 then
    manager.machine.video:snapshot()
  end
end)
