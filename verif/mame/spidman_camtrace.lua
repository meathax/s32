-- spidman attract-mode camera/copy trace (deterministic, no input).
-- Logs, once per frame: the world-camera variable 0x208032 (display source),
-- its known copies (0x208304/08/44/48/50 region), and NBG0 scrollx — so the
-- frame where the attract demo starts panning, and how every copy evolves
-- through it, can be diffed against the core.  Output: plain lines on stdout
-- ("CAM f=<frame> ..."), grep-able.
--
-- Usage (WSL):
--   mame spidman -rompath /mnt/d/Arcade/AI/s32/roms -skip_gameinfo -nothrottle \
--        -video none -sound none -seconds_to_run 75 \
--        -autoboot_script /mnt/d/Arcade/AI/s32/verif/mame/spidman_camtrace.lua
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local scr = manager.machine.screens[":mainpcb:screen"]

local frame = 0
local last_line = ""

-- write-tap: record which PCs write the copy block 0x208300-0x20835F.
-- Pin the handle in _G or Lua GC silently removes the tap.
local writers = {}
_G.cam_tap = mem:install_write_tap(0x208300, 0x20835F, "cam_copies",
    function(offset, data, mask)
        local pc = cpu.state["PC"].value
        local key = string.format("%06X->%06X", pc, offset)
        writers[key] = (writers[key] or 0) + 1
    end)

_G.cam_notifier = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame < 120 then return end          -- skip boot/RAM test
    local cam   = mem:read_u16(0x208032)
    local c304  = mem:read_u32(0x208304)
    local c308  = mem:read_u32(0x208308)
    local c344  = mem:read_u32(0x208344)
    local c348  = mem:read_u32(0x208348)
    local c350  = mem:read_u32(0x208350)
    local scrl  = mem:read_u16(0x31FF12)
    local line = string.format(
        "CAM f=%d cam=%04x s=%03x c304=%08x c308=%08x c344=%08x c348=%08x c350=%08x",
        frame, cam, scrl & 0x1FF, c304, c308, c344, c348, c350)
    -- only print on change (keeps the log to the interesting frames)
    local key = line:gsub("f=%d+ ", "")
    if key ~= last_line then
        print(line)
        last_line = key
    end
end)

emu.register_stop(function()
    print("CAMWRITERS begin")
    for k, v in pairs(writers) do
        print(string.format("CAMWRITER %s x%d", k, v))
    end
    print("CAMWRITERS end")
end)
