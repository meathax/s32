-- Capture the ga2 V60<->V25 mailbox (MB8421 dpram) exchange.
-- V60 sees the dpram at 0xA00000-0xA00FFF (low byte lane, even addrs).
-- V25 sees the same dpram at 0x10000-0x1FFFF.
-- Logs every write from each side with the mcu cycle count for later replay.
-- Handles are pinned in _G so Lua GC does not silently drop the taps.
local maincpu = manager.machine.devices[":mainpcb:maincpu"]
local mcu     = manager.machine.devices[":mainpcb:mcu"]
local msp     = maincpu.spaces["program"]
local usp     = mcu.spaces["program"]

local out = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_mbox_trace.csv", "w")
out:write("cyc,who,off,data,mask\n")

local function mcyc()
  local ok, v = pcall(function() return mcu:total_cycles() end)
  if ok and v then return v end
  return math.floor(manager.machine.time:as_double() * 10000000.0) -- 10MHz fallback
end

_G.ga2_tap_v60 = msp:install_write_tap(0xa00000, 0xa00fff, "v60mbox",
  function(offset, data, mask)
    local off = (offset - 0xa00000)
    out:write(string.format("%d,V60,%03x,%04x,%04x\n", mcyc(), (off >> 1) & 0x7ff, data & 0xffff, mask & 0xffff))
  end)

_G.ga2_tap_v25 = usp:install_write_tap(0x10000, 0x1ffff, "v25mbox",
  function(offset, data, mask)
    local off = (offset - 0x10000) & 0x7ff
    out:write(string.format("%d,V25,%03x,%04x,%04x\n", mcyc(), off, data & 0xffff, mask & 0xffff))
  end)

-- flush periodically so a -seconds_to_run exit still leaves a complete file
_G.ga2_flush = emu.add_machine_frame_notifier(function() out:flush() end)
