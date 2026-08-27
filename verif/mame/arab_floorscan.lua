-- arabfgt attract scan: log NBG0/1 scroll+zoom registers EVERY frame for a long
-- window, to (1) locate the floor/gameplay-demo scene (NBG zoom active, != 0x200)
-- and (2) detect whether those registers oscillate period-2 frame-to-frame
-- (game-driven flicker) or move smoothly. Cheap: no snapshots.
--   /usr/games/mame arabfgt -rompath /mnt/d/Arcade/AI/s32/roms \
--     -autoboot_script verif/mame/arab_floorscan.lua -video none -sound none \
--     -seconds_to_run 14 -nothrottle
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local msp = cpu.spaces["program"]
local VBASE = 0x300000
local function rd(boff) return msp:read_u16(VBASE + boff) end
local function reg(bg)
  local s = 8*bg; local z = 4*bg
  return rd(0x1ff12+s), rd(0x1ff10+s), rd(0x1ff16+s), rd(0x1ff14+s), rd(0x1ff50+z), rd(0x1ff52+z)
end
local STOP = tonumber(os.getenv("STOP") or "760")
local fr = 0
local log = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_arab_floorscan.txt", "w")
_G.floorscan = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  local sx0,sfx0,sy0,sfy0,zx0,zy0 = reg(0)
  local sx1,sfx1,sy1,sfy1,zx1,zy1 = reg(1)
  log:write(string.format(
    "f=%d r00=%04x r02=%04x N0 sx=%04x sy=%04x zx=%04x zy=%04x N1 sx=%04x sy=%04x zx=%04x zy=%04x\n",
    fr, rd(0x1ff00), rd(0x1ff02), sx0,sy0,zx0,zy0, sx1,sy1,zx1,zy1))
  if fr % 40 == 0 then log:flush() end
  if fr >= STOP then print("[floorscan] done"); log:close(); manager.machine:exit() end
end)
