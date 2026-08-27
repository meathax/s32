-- Snapshot 8 consecutive arabfgt frames (PNG) so the period-2 flicker can be
-- measured the same way as the Verilator sim and compared.
local fr = 0
local capstart = 300
_G.cap = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= capstart and fr < capstart + 8 then
    manager.machine.video:snapshot()
  end
  if fr == capstart + 8 then print("[framecap] done"); manager.machine:exit() end
end)
