-- ga2_paltrace.lua -- fourth-stage trace: is the stage-2 torch palette cycling?
--
-- Prior traces refuted three mechanisms for the MAMETesters 05233 torch effect
-- (mixer $61004E gradation, rowscroll/rowselect line window, colour-offset
-- pulse).  The remaining lead is palette animation: ga2 sustains per-frame
-- writes to a tight colour-RAM range ($608200-$608300) across 1,804 frames, and
-- palette-cycling a pre-drawn radial gradient is the classic way to make a light
-- appear to expand and contract in a circle.
--
-- This logs that range at full detail (frame, address, value) so the series can
-- be tested for the oscillation a flickering torch would produce, as opposed to
-- the monotonic ramps the colour-offset registers were already shown to make.
--
-- Usage:
--   mame ga2 -autoboot_script verif/mame/ga2_paltrace.lua -autoboot_delay 0
--   GA2_TRACE_OUT selects the output path.

local OUT = os.getenv("GA2_TRACE_OUT") or "/tmp/ga2_paltrace.txt"

local f = io.open(OUT, "w")
if f == nil then print("ga2_paltrace: cannot open " .. OUT) return end

local cpu = manager.machine.devices[":mainpcb:maincpu"]
             or manager.machine.devices[":maincpu"]
if cpu == nil then f:write("ERROR: no maincpu\n") f:close() return end
local space = cpu.spaces["program"]

local frame = 0

-- Pin tap tokens: MAME silently drops a tap whose Lua token is collected.
GA2_PAL_TAPS = {}
GA2_PAL_FILE = f
local taps = GA2_PAL_TAPS

local function tap(lo, hi, tag)
  local ok, res = pcall(function()
    return space:install_write_tap(lo, hi, tag, function(offset, data, mask)
      f:write(string.format("%-6d %-4s %08X %04X\n", frame, tag, offset, data & 0xFFFF))
      f:flush()
      return data
    end)
  end)
  if ok then taps[#taps + 1] = res
  else f:write(string.format("# WARN tap %s failed: %s\n", tag, tostring(res))) f:flush() end
end

f:write("# ga2 palette trace -- see verif/mame/ga2_paltrace.lua\n")
f:write("# frame  tag  address  value\n")

-- The sustained-animation window found by ga2_torchtrace.lua, plus a little
-- margin either side so an expanding gradient is not clipped.
tap(0x608180, 0x608380, "pal")

emu.register_frame_done(function() frame = frame + 1 end)

local function on_stop() f:write("# stop\n") f:flush() end
if emu.add_machine_stop_notifier ~= nil then emu.add_machine_stop_notifier(on_stop)
elseif emu.register_stop ~= nil then emu.register_stop(on_stop) end

print("ga2_paltrace: logging to " .. OUT)
