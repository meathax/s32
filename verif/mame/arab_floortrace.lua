-- arabfgt: capture N consecutive attract frames AND log the NBG0/1 tilemap
-- scroll/zoom registers each frame, to decide whether the floor "period-2
-- flicker" is game-driven (registers oscillate frame-to-frame) or a core bug
-- (registers smooth, only our render jitters).
--
-- Run (WSL):
--   CAPSTART=292 CAPN=8 /usr/games/mame arabfgt -rompath /mnt/d/Arcade/AI/s32/roms \
--     -autoboot_script verif/mame/arab_floortrace.lua -video soft -sound none \
--     -seconds_to_run 12 -nothrottle
-- Snapshots land in MAME snap/arabfgt/.  Register log -> scratch/mame_arab_floorregs.txt
--
-- Register byte-offsets within videoram (base = maincpu 0x300000), from
-- segas32_v.cpp update_tilemap_zoom:
--   zoom:   dstxstep = videoram[0x1ff50/2 + 2*bg], dstystep = [0x1ff52/2 + 2*bg]
--   scroll: sx int [0x1ff12/2+4*bg] frac [0x1ff10/2+4*bg]
--           sy int [0x1ff16/2+4*bg] frac [0x1ff14/2+4*bg]
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local msp = cpu.spaces["program"]
local VBASE = 0x300000
local function rd(boff) return msp:read_u16(VBASE + boff) end
-- byte stride: scroll block = 8 bytes/bg, zoom block = 4 bytes/bg
local function reg(bg)
  local s = 8*bg
  local z = 4*bg
  return rd(0x1ff12+s), rd(0x1ff10+s), rd(0x1ff16+s), rd(0x1ff14+s), rd(0x1ff50+z), rd(0x1ff52+z)
end

local START = tonumber(os.getenv("CAPSTART") or "292")
local N     = tonumber(os.getenv("CAPN") or "8")
local fr = 0
local log = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_arab_floorregs.txt", "w")

_G.floortrace = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= START and fr < START + N then
    manager.machine.video:snapshot()
    local sx0,sfx0,sy0,sfy0,zx0,zy0 = reg(0)
    local sx1,sfx1,sy1,sfy1,zx1,zy1 = reg(1)
    log:write(string.format(
      "f=%d r1ff00=%04x r1ff02=%04x | NBG0 sx=%04x sfx=%04x sy=%04x sfy=%04x zx=%04x zy=%04x"
      .. " | NBG1 sx=%04x sfx=%04x sy=%04x sfy=%04x zx=%04x zy=%04x\n",
      fr, rd(0x1ff00), rd(0x1ff02),
      sx0,sfx0,sy0,sfy0,zx0,zy0, sx1,sfx1,sy1,sfy1,zx1,zy1))
    log:flush()
  end
  if fr == START + N then
    print("[floortrace] done")
    log:close()
    manager.machine:exit()
  end
end)
