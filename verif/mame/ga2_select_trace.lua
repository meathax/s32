-- Deterministic Golden Axe: Revenge of Death Adder PLAYER SELECT reference
-- trace.  Drive Coin -> Start, then log accepted V60 work-RAM writes in the
-- coin/credit and title-controller ranges.  The companion Verilator harness
-- emits the same fields with +TRACELO/+TRACEHI; compare semantic event order,
-- not absolute frame numbers.
local cpu = assert(manager.machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local svc = assert(manager.machine.ioport.ports[":mainpcb:SERVICE12_A"])
local coin = assert(svc.fields["Coin 1"])
local start = assert(svc.fields["1 Player Start"])

local output = os.getenv("GA2_TRACE_OUT") or
  "/mnt/d/Arcade/AI/s32/scratch/mame_ga2_select_trace.log"
local log = assert(io.open(output, "w"))
local frame = 0

local function pc()
  return cpu.state["PC"].value
end

local function trace_write(offset, data, mask)
  log:write(string.format(
    "[memtrace] f=%d pc=%08x a=%06x d=%04x mask=%04x\n",
    frame, pc(), offset, data, mask))
end

-- Keep tap handles global so Lua garbage collection cannot remove them.
_G.ga2_select_state_tap = mem:install_write_tap(
  0x20ac7a, 0x20ac83, "ga2_select_state", trace_write)
_G.ga2_select_object_tap = mem:install_write_tap(
  0x204a60, 0x204aff, "ga2_select_object", trace_write)

_G.ga2_select_trace_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1

  if frame >= 60 and frame < 90 then
    coin:set_value(1)
  elseif frame == 90 then
    coin:set_value(0)
  end

  if frame >= 120 and frame < 150 then
    start:set_value(1)
  elseif frame == 150 then
    start:set_value(0)
  end

  if frame == 220 then
    log:write(string.format(
      "[state] ac7a=%04x ac7c=%04x ac7e=%04x ac80=%04x " ..
      "palette=%04x stream_lo=%04x stream_hi=%04x\n",
      mem:read_u16(0x20ac7a), mem:read_u16(0x20ac7c),
      mem:read_u16(0x20ac7e), mem:read_u16(0x20ac80),
      mem:read_u16(0x204a76), mem:read_u16(0x204aa6),
      mem:read_u16(0x204aa8)))
    log:close()
    print("[ga2_select_trace] wrote " .. output)
    manager.machine:exit()
  end
end)
