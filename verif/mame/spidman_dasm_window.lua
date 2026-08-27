-- One-shot disassembly of the waiting-object camera-window setup path.
local done = false
_G.spid_dasm_window = emu.add_machine_frame_notifier(function()
    if not done then
        done = true
        manager.machine.debugger:command(
            "dasm /mnt/d/Arcade/AI/s32/scratch/spid_window_init.asm,87e40,180,1,mainpcb:maincpu")
        manager.machine:exit()
    end
end)
