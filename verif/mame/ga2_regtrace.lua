-- ga2_regtrace.lua -- register trace for the PCB-accuracy plan (traces T-A..T-D)
--
-- Captures the register activity that decides four open questions in
-- docs/ga2-pcb-accuracy-plan.md and docs/ga2-implementation-backlog.md:
--
--   T-A  writes to $31FF00 / $31FF02 / $31FF04 / $31FF8E
--        -> which mechanism drives the stage-2 cave torch (MAMETesters 05233),
--           whether ga2 sets the $1FF00 bits 12/13 we currently treat as NBG2/3
--           disables, and whether it ever sets the $1FF8E opaque bits 8-11.
--   T-B  writes to the mixer block $610020-$61004F
--        -> whether the torch uses $61004E gradation/blur (MacDonald bits 4-6
--           amount, bit 7 enable), which MAME implements NOT AT ALL because it
--           reads only bits 8-11 of that register.
--   T-C  reads of $500000 / $500002 (sprite buffer + render status)
--        -> whether ga2 polls the status MAME and FBNeo both hardcode.
--   T-D  reads of $D00008-$D0000B (timer down-counts)
--        -> whether ga2 polls the timers MAME returns 0xFF for ("fix me").
--
-- Usage (from the repo root, via the existing WSL MAME harness):
--   mame ga2 -autoboot_script verif/mame/ga2_regtrace.lua -autoboot_delay 0
-- Optional environment:
--   GA2_TRACE_OUT    output path (default /tmp/ga2_regtrace.txt)
--   GA2_TRACE_FRAMES stop after N frames (default 3600, 0 = unlimited)
--
-- Play into the stage-2 cave and light the wall torch while this runs; the
-- interesting window is whatever frames surround the lighting effect.

local OUT    = os.getenv("GA2_TRACE_OUT") or "/tmp/ga2_regtrace.txt"
local FRAMES = tonumber(os.getenv("GA2_TRACE_FRAMES") or "3600")

local f = io.open(OUT, "w")
if f == nil then
  print("ga2_regtrace: cannot open " .. OUT)
  return
end

-- System 32 is a multi-PCB driver in current MAME; fall back for older trees.
local cpu = manager.machine.devices[":mainpcb:maincpu"]
             or manager.machine.devices[":maincpu"]
if cpu == nil then
  f:write("ERROR: could not find maincpu (tried :mainpcb:maincpu and :maincpu)\n")
  f:close()
  return
end
local space = cpu.spaces["program"]

local frame = 0

-- TAPS MUST BE PINNED AGAINST GARBAGE COLLECTION.
-- The autoboot chunk's locals become unreachable as soon as the script finishes
-- executing, and MAME removes a memory tap when its token is collected -- with
-- no error and no log line.  Symptom: records stop dead a few seconds in (we
-- lost four capture runs to this, every one stopping at frame ~180 while the
-- game carried on running perfectly).  Holding the tokens in a global keeps
-- them reachable for the life of the machine.
GA2_REGTRACE_TAPS = {}
GA2_REGTRACE_FILE = f          -- pin the handle for the same reason
local taps = GA2_REGTRACE_TAPS

-- Flush on every record.  Do NOT batch this: under -video none the frame-done
-- callback stops firing, so a periodic flush keyed to frames silently loses the
-- entire tail of the capture (this cost one bad 300 s run).  Volume here is a
-- few hundred lines per attract loop, so per-record flushing is free.
local function note(kind, tag, offset, data, mask)
  f:write(string.format("%-6d %-5s %-10s %08X %04X %04X\n",
                        frame, kind, tag, offset, data & 0xFFFF, mask & 0xFFFF))
  f:flush()
end

-- Tap installation differs slightly between MAME versions; never let a missing
-- API abort the run, just record that the tap could not be installed.
local function wtap(lo, hi, tag)
  local ok, res = pcall(function()
    return space:install_write_tap(lo, hi, tag,
      function(offset, data, mask)
        note("W", tag, offset, data, mask)
        return data        -- observe only; never modify
      end)
  end)
  if ok then taps[#taps + 1] = res
  else f:write(string.format("# WARN: write tap %s failed: %s\n", tag, tostring(res))) end
end

local function rtap(lo, hi, tag)
  local ok, res = pcall(function()
    return space:install_read_tap(lo, hi, tag,
      function(offset, data, mask)
        note("R", tag, offset, data, mask)
        return data        -- observe only
      end)
  end)
  if ok then taps[#taps + 1] = res
  else f:write(string.format("# WARN: read tap %s failed: %s\n", tag, tostring(res))) end
end

f:write("# ga2 register trace -- see verif/mame/ga2_regtrace.lua\n")
f:write("# frame  kind  tag        address  data mask\n")

-- T-A: tilemap/layer control living in VRAM at $31FFxx
wtap(0x31FF00, 0x31FF07, "1FF00_06")   -- width/flip, layer disable, rowscroll ctl
wtap(0x31FF8E, 0x31FF8F, "1FF8E")      -- second disable set + opaque bits 8-11
wtap(0x31FF5E, 0x31FF5F, "1FF5E")      -- backdrop / line colour
wtap(0x31FF30, 0x31FF3F, "1FF30_3E")   -- zoom centre (the 9/10-bit hack input)

-- T-B: mixer block. $61004E is the one MAME only half-implements.
wtap(0x610020, 0x61002B, "61_pixmask")  -- bits 9:8 pixel mask (unmodelled)
wtap(0x61003E, 0x61003F, "61003E")      -- grayscale / brightness (unmodelled)
wtap(0x61004C, 0x61004D, "61004C")      -- sprite priority / shadow control
wtap(0x61004E, 0x61004F, "61004E")      -- blend + gradation/blur (bits 4-7!)

-- T-C: sprite controller status the emulators fake
rtap(0x500000, 0x500003, "sprstat")

-- T-D: interrupt-controller timer down-counts MAME returns 0xFF for
rtap(0xD00008, 0xD0000B, "timercnt")

-- Frame counter only.  Under -video none this stops firing partway through, so
-- the frame column may freeze -- records still land because note() flushes.
emu.register_frame_done(function()
  frame = frame + 1
  if FRAMES > 0 and frame >= FRAMES then
    f:write(string.format("# stopped after %d frames\n", frame))
    f:flush()
    manager.machine:exit()
  end
end)

-- emu.register_stop is deprecated and did not fire on this MAME build; prefer
-- the notifier and keep the old call only as a fallback.  Never close the file
-- here -- a tap can still fire during shutdown and writing to a closed handle
-- raises a Lua error inside the callback.
local function on_stop()
  f:write("# stop\n")
  f:flush()
end
if emu.add_machine_stop_notifier ~= nil then
  emu.add_machine_stop_notifier(on_stop)
elseif emu.register_stop ~= nil then
  emu.register_stop(on_stop)
end

print("ga2_regtrace: logging to " .. OUT)
