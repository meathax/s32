-- ga2_torchtrace.lua -- second-stage trace for the stage-2 cave torch effect.
--
-- The first trace (ga2_regtrace.lua) REFUTED both standing hypotheses:
--   * mixer $61004E gradation/blur -- ga2 only ever writes bits 8-11, so the
--     gradation field (bits 0-7) is permanently zero;
--   * rowscroll/rowselect line window on NBG0/1 -- $1FF04 only ever selects
--     NBG2/NBG3 rowscroll, which this core already implements.
--
-- So the "light comes in and out in a circle" (MAMETesters 05233) has to be
-- produced somewhere neither of those covers.  Remaining candidates, in the
-- order this script tests them:
--   1. Colour-offset registers $610040-$61004B -- a global R/G/B brightness
--      pulse.  MacDonald documents these as signed offsets with a measured
--      clamp; a torch flare is exactly the shape of a pulsing offset.
--   2. Palette animation -- direct writes into colour RAM $600000-$60FFFF.
--   3. Sprite-list commands -- a scaled radial-gradient sprite.
--
-- Colour RAM is summarised per frame (count + address span) rather than logged
-- per write, because palette DMA would otherwise produce millions of records.
--
-- Usage:
--   mame ga2 -autoboot_script verif/mame/ga2_torchtrace.lua -autoboot_delay 0
--   GA2_TRACE_OUT selects the output path.

local OUT = os.getenv("GA2_TRACE_OUT") or "/tmp/ga2_torchtrace.txt"

local f = io.open(OUT, "w")
if f == nil then print("ga2_torchtrace: cannot open " .. OUT) return end

local cpu = manager.machine.devices[":mainpcb:maincpu"]
             or manager.machine.devices[":maincpu"]
if cpu == nil then
  f:write("ERROR: no maincpu\n") f:close() return
end
local space = cpu.spaces["program"]

local frame = 0

-- Pin tap tokens in a global: MAME silently removes a tap when its Lua token is
-- garbage collected, and autoboot-chunk locals die as soon as the script ends.
GA2_TORCH_TAPS = {}
GA2_TORCH_FILE = f
local taps = GA2_TORCH_TAPS

-- per-frame colour RAM aggregation
local cram_n, cram_lo, cram_hi = 0, 0xFFFFFFFF, 0

local function rec(fmt, ...)
  f:write(string.format(fmt, ...))
  f:flush()
end

local function wtap(lo, hi, tag)
  local ok, res = pcall(function()
    return space:install_write_tap(lo, hi, tag, function(offset, data, mask)
      rec("%-6d W %-9s %08X %04X\n", frame, tag, offset, data & 0xFFFF)
      return data
    end)
  end)
  if ok then taps[#taps + 1] = res
  else rec("# WARN tap %s failed: %s\n", tag, tostring(res)) end
end

f:write("# ga2 torch trace -- see verif/mame/ga2_torchtrace.lua\n")

-- 1. colour offset banks A and B (signed R/G/B), plus the select register
wtap(0x610040, 0x61004B, "coloroffs")
wtap(0x610030, 0x61003D, "layerctl")

-- 3. sprite control commands (write-only on hardware)
wtap(0x500000, 0x50000F, "sprctl")

-- 2. colour RAM, aggregated per frame
local ok, res = pcall(function()
  return space:install_write_tap(0x600000, 0x60FFFF, "cram",
    function(offset, data, mask)
      cram_n = cram_n + 1
      if offset < cram_lo then cram_lo = offset end
      if offset > cram_hi then cram_hi = offset end
      return data
    end)
end)
if ok then taps[#taps + 1] = res
else rec("# WARN tap cram failed: %s\n", tostring(res)) end

emu.register_frame_done(function()
  if cram_n > 0 then
    rec("%-6d W %-9s %08X-%08X n=%d\n", frame, "cram", cram_lo, cram_hi, cram_n)
    cram_n, cram_lo, cram_hi = 0, 0xFFFFFFFF, 0
  end
  frame = frame + 1
end)

local function on_stop() f:write("# stop\n") f:flush() end
if emu.add_machine_stop_notifier ~= nil then emu.add_machine_stop_notifier(on_stop)
elseif emu.register_stop ~= nil then emu.register_stop(on_stop) end

print("ga2_torchtrace: logging to " .. OUT)
