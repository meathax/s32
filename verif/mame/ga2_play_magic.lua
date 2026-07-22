-- Reproduce ga2 gameplay + the magic/flame effect in MAME (reference: sprites
-- must SURVIVE the flame). coin -> start -> select character (Button 1) ->
-- gameplay -> hold Right and pulse magic (Button 3) -> screenshot densely to
-- catch the flame and the after-state.
local svc = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local p1 = manager.machine.ioport.ports[":mainpcb:P1_A"]
local b1 = p1.fields["P1 Button 1"]   -- attack / select-confirm
local b3 = p1.fields["P1 Button 3"]   -- magic (guess)
local right = p1.fields["P1 Right"]

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  -- select character (a couple button taps around player-select)
  if (fr >= 470 and fr < 476) or (fr >= 500 and fr < 506) then b1:set_value(1) elseif fr==476 or fr==506 then b1:set_value(0) end
  -- gameplay: hold Right from 540, and pulse magic (b3) every 60 frames
  if fr >= 540 then right:set_value(1) end
  if fr >= 560 and (fr % 60) < 5 then b3:set_value(1) elseif fr >= 560 then b3:set_value(0) end
  -- dense screenshots to catch the flame + after
  if fr >= 460 and fr % 40 == 0 then manager.machine.video:snapshot() end
  if fr == 1200 then print("[play] done"); manager.machine:exit() end
end)
