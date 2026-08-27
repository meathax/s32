-- Arabian Fight V25 boot reference vector.
--
-- Captures what the REAL NEC V25 writes into the MB8421 from reset, in order,
-- so the same window can be replayed through our s32_v25_cpu + s80x86 and
-- diffed.  Boot is used deliberately: it is the only window with no hidden
-- prior state on either side, so a mismatch localises to an instruction rather
-- than to accumulated divergence.
--
-- The V25's program map (MAME segas32.cpp v25_map) is ROM at 0x00000-0x0ffff,
-- MB8421 at 0x10000-0x1ffff, ROM mirror at 0xf0000-0xfffff.  The dual-port RAM
-- is 2 KiB, so the shared offset is (address & 0x7ff).
--
-- Env:
--   ARAB_V25_OUT     output path (default scratch/arab_v25_boot/writes.txt)
--   ARAB_V25_FRAMES  stop after this many frames (default 120)
--   ARAB_V25_MAX     stop logging after this many writes (default 20000)
--   ARAB_V25_SNAPS   comma-separated frames at which to dump the whole 2 KiB

local machine = manager.machine
local mcu = assert(machine.devices[":mainpcb:mcu"])
local space = assert(mcu.spaces["program"])

local out_path = os.getenv("ARAB_V25_OUT") or "scratch/arab_v25_boot/writes.txt"
local last_frame = tonumber(os.getenv("ARAB_V25_FRAMES") or "120")
local max_writes = tonumber(os.getenv("ARAB_V25_MAX") or "20000")
local log = assert(io.open(out_path, "w"))

local snaps = {}
for value in string.gmatch(os.getenv("ARAB_V25_SNAPS") or "", "%d+") do
  snaps[tonumber(value)] = true
end

-- The V25's program counter is exposed under different names depending on the
-- core revision; probe once rather than assuming.
local pc_key = nil
for _, candidate in ipairs({ "PC", "IP", "CURPC" }) do
  if mcu.state[candidate] then pc_key = candidate break end
end

local function pc()
  if pc_key then return mcu.state[pc_key].value end
  return 0
end

local frame = 0
local seq = 0
local per_frame = 0
local frame_counts = {}

-- Pin the tap handles in _G: Lua GC removes them otherwise and the tap dies
-- silently after about a second of emulated time.
_G.arab_v25_write_tap = space:install_write_tap(0x10000, 0x1ffff, "arab_v25_wr",
  function(offset, data, mask)
    seq = seq + 1
    per_frame = per_frame + 1
    if seq <= max_writes then
      log:write(string.format("%d f=%d off=%03x d=%02x pc=%05x\n",
        seq, frame, offset & 0x7ff, data & 0xff, pc()))
    end
    return data
  end)

local function snapshot(tag)
  log:write(string.format("# snapshot %s frame=%d\n", tag, frame))
  for base = 0, 0x7ff, 16 do
    local row = {}
    for i = 0, 15 do
      row[#row + 1] = string.format("%02x", space:read_u8(0x10000 + base + i))
    end
    log:write(string.format("# %03x: %s\n", base, table.concat(row, " ")))
  end
  log:flush()
end

_G.arab_v25_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  frame_counts[frame] = per_frame
  log:write(string.format("# frame %d writes=%d total=%d\n", frame, per_frame, seq))
  per_frame = 0
  if snaps[frame] then snapshot("f" .. frame) end
  if frame >= last_frame then
    log:write(string.format("# done frames=%d writes=%d pc_key=%s\n",
      frame, seq, tostring(pc_key)))
    snapshot("final")
    log:close()
    log = nil
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
