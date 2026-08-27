-- Read work-RAM byte 0x20f020 every time PC reaches 0x703d8 (the
-- "test1 #4,7020[R25]" gate that decides whether to re-enter the motor-
-- warmup wait helper at 0x7027a, per radm_dasm_after2.txt).  Also log PC
-- 0x703e8 hits (the bsr into the wait helper) to see how often it's
-- actually taken.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])

local out = os.getenv("RADM_BIT2_OUT") or "scratch/radm_bit2_trace.txt"
local last_frame = tonumber(os.getenv("RADM_BIT2_LAST")) or 90
local log = assert(io.open(out, "w"))
local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_BIT2_MAX")) or 4000

_G.radm_bit2_bp1 = cpu.space["program"] and nil
_G.radm_bit2_hook = cpu:debug()
_G.radm_bit2_hook:bpset(0x703d8, "1", "")
_G.radm_bit2_hook2 = cpu:debug()
_G.radm_bit2_hook2:bpset(0x703e8, "1", "")

emu.register_periodic(function() end)

local function on_break()
  local pc = cpu.state["PC"].value
  if n < max_lines then
    log:write(string.format("BP f=%d pc=%08x byte20f020=%02x\n",
      frame, pc, mem:read_u8(0x20f020)))
    n = n + 1
  end
end
_G.radm_bit2_notif = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    log:write(string.format("# done frame=%d n=%d\n", frame, n))
    log:close(); log = nil
    machine:exit()
  end
end)
_G.radm_bit2_debugnotif = cpu.debug():set_hook("breakpoint", nil)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
