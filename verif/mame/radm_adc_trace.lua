-- Trace ADC (MSM6253) port activity and PC during Rad Mobile's early boot,
-- to find what the "Motor warm up now !! Please wait" wait-loop polls.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])

local out = os.getenv("RADM_ADC_OUT") or "scratch/radm_adc_trace.txt"
local last_frame = tonumber(os.getenv("RADM_ADC_LAST")) or 120
local log = assert(io.open(out, "w"))

local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_ADC_MAX")) or 20000

_G.radm_adc_r = mem:install_read_tap(0xc00050, 0xc00057, "radm_adc_r",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("RD f=%d pc=%08x a=%06x d=%02x\n",
        frame, cpu.state["PC"].value, offset, data & 0xff))
    end
    return data
  end)
_G.radm_adc_w = mem:install_write_tap(0xc00050, 0xc00057, "radm_adc_w",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("WR f=%d pc=%08x a=%06x d=%02x\n",
        frame, cpu.state["PC"].value, offset, data & 0xff))
    end
    return data
  end)

_G.radm_adc_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    log:write(string.format("# done frame=%d taps=%d pc=%08x\n", frame, n, cpu.state["PC"].value))
    log:close()
    log = nil
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
