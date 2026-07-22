-- Disassemble the char-select object init/build loops using the MAME debugger
-- console 'dasm' command (writes to a file). Run with -debug -debugger none.
local dbg = manager.machine.debugger
_G.did = false
_G.t = emu.add_machine_frame_notifier(function()
  if _G.did then return end
  _G.did = true
  -- dasm <file>,<address>,<length>,<opcodes>
  dbg:command('dasm "/mnt/d/Arcade/AI/s32/scratch/ga2_dasm_spawn.txt",0x63B80,0xA0,1')
  dbg:command('dasm "/mnt/d/Arcade/AI/s32/scratch/ga2_dasm_finalize.txt",0x63DB0,0x20,1')
  print("[dasm2] done")
  manager.machine:exit()
end)
