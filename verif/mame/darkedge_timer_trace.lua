-- Dark Edge gameplay-countdown reference probe.
--
-- Starts a one-player game, scans the 64 KiB main work RAM once per video
-- frame, and reports byte locations that follow either a binary 90,89,88...
-- sequence or a packed-BCD 0x90,0x89,0x88... sequence.  Write taps are then
-- installed on surviving locations so the decrementing PC is captured too.
-- This is reference instrumentation only; it never writes game RAM.

local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local ports = machine.ioport.ports
local svc = assert(ports[":mainpcb:SERVICE12_A"].fields)
local p1 = assert(ports[":mainpcb:P1_A"].fields)
local coin = assert(svc["Coin 1"])
local start = assert(svc["1 Player Start"])
local attack = assert(p1["P1 Button 1"])
local frame = 0
local stop_frame = tonumber(os.getenv("DARKEDGE_TIMER_STOP") or "2400")
local out_path = os.getenv("DARKEDGE_TIMER_OUT") or
  "scratch/mame_darkedge_timer_trace.log"
local log = assert(io.open(out_path, "w"))
local previous = {}
local candidates = {}
local taps = {}

local function set(field, active)
  field:set_value(active and 1 or 0)
end

local function expected_next(value, bcd)
  if bcd then
    local tens = (value >> 4) & 0x0f
    local ones = value & 0x0f
    if ones == 0 then return ((tens - 1) << 4) | 9 end
    return value - 1
  end
  return value - 1
end

local function arm_tap(address)
  -- The V60 program space is 16-bit wide, so MAME requires taps to cover an
  -- aligned word even when the candidate itself is a byte.
  local tap_address = address & 0xfffffe
  if taps[tap_address] then return end
  taps[tap_address] = mem:install_write_tap(tap_address, tap_address + 1,
    string.format("darkedge_timer_%06x", tap_address), function(offset, data, mask)
      log:write(string.format(
        "[write] frame=%d pc=%08x addr=%06x data=%04x mask=%04x\n",
        frame, cpu.state["PC"].value, offset, data & 0xffff, mask & 0xffff))
      log:flush()
    end)
end

-- Known from the first discovery pass; keeping this armed from reset captures
-- initialization as well as each 35-frame gameplay decrement.
arm_tap(0x20a112)

local function scan_work_ram()
  for address = 0x200000, 0x20ffff do
    local value = mem:read_u8(address)
    local prior = previous[address]
    local candidate = candidates[address]
    if candidate then
      local want = expected_next(candidate.value, candidate.bcd)
      if value == want then
        candidate.value = value
        candidate.score = candidate.score + 1
        candidate.last_frame = frame
        log:write(string.format(
          "[candidate] frame=%d addr=%06x value=%02x score=%d cadence=%d\n",
          frame, address, value, candidate.score, frame - candidate.prev_frame))
        candidate.prev_frame = frame
        if candidate.score >= 2 then arm_tap(address) end
      elseif value ~= candidate.value and frame - candidate.last_frame > 180 then
        candidates[address] = nil
      end
    elseif prior == 90 and value == 89 then
      candidates[address] = {
        value=value, bcd=false, score=1, last_frame=frame, prev_frame=frame
      }
    elseif prior == 0x90 and value == 0x89 then
      candidates[address] = {
        value=value, bcd=true, score=1, last_frame=frame, prev_frame=frame
      }
    end
    previous[address] = value
  end
end

_G.darkedge_timer_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1

  set(coin, frame >= 300 and frame < 315)
  set(start, (frame >= 420 and frame < 435) or
             (frame >= 520 and frame < 535))
  -- Select the default fighter and keep the round alive/advancing.
  set(attack, (frame >= 560 and frame < 575) or
              (frame >= 700 and (frame % 12) < 4))

  scan_work_ram()

  if frame >= stop_frame then
    log:write(string.format("[done] frame=%d pc=%08x\n",
      frame, cpu.state["PC"].value))
    log:close()
    log = nil
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
