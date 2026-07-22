-- Trace the V60 instruction stream during ONE PLAYER SELECT object-build frame
-- (~470) so the character-composition code path can be examined for an
-- instruction our V60 handles differently. Uses the debugger 'trace' command.
local dbg = manager.machine.debugger
local svc = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 435 then dbg:command('trace "/mnt/d/Arcade/AI/s32/scratch/mame_spawn436.txt",":mainpcb:maincpu"') end
  if fr == 437 then dbg:command('trace off'); print("[trace] captured spawn frame 436"); manager.machine:exit() end
end)
