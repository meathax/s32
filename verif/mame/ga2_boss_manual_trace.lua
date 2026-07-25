-- User-driven GA2 boss-meter capture.  Drive MAME normally, then create
-- scratch/ga2_boss_trace.arm immediately before the first boss hit.  Changed
-- writes are recorded with the executing V60 PC until .stop is created.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local screen = assert(machine.screens[":mainpcb:screen"])
local root = "/mnt/d/Arcade/AI/s32/scratch"
local arm_path = root .. "/ga2_boss_trace.arm"
local stop_path = root .. "/ga2_boss_trace.stop"
local log_path = root .. "/ga2_boss_manual_trace.csv"
local log = assert(io.open(log_path, "w"))
log:write("frame,space,pc,address,data,mask\n")

local frame = 0
local armed = false
local last = {}

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function changed_write(space_name, offset, data, mask)
  if not armed then return end
  local key = space_name .. string.format("%08x/%08x", offset, mask)
  if last[key] == data then return end
  last[key] = data
  log:write(string.format("%d,%s,%08x,%08x,%08x,%08x\n",
    frame, space_name, cpu.state["PC"].value, offset, data, mask))
end

_G.ga2_boss_work_tap = mem:install_write_tap(
  0x200000, 0x20ffff, "ga2_boss_work",
  function(offset, data, mask) changed_write("work", offset, data, mask) end)
_G.ga2_boss_vram_tap = mem:install_write_tap(
  0x300000, 0x3fffff, "ga2_boss_vram",
  function(offset, data, mask) changed_write("vram", offset, data, mask) end)
_G.ga2_boss_sprite_tap = mem:install_write_tap(
  0x400000, 0x4fffff, "ga2_boss_sprite",
  function(offset, data, mask) changed_write("sprite", offset, data, mask) end)

_G.ga2_boss_manual_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if not armed and exists(arm_path) then
    armed = true
    log:write(string.format("%d,marker,%08x,00000000,00000001,ffffffff\n",
      frame, cpu.state["PC"].value))
    log:flush()
    screen:snapshot(root .. "/ga2-boss-arm.png")
    print("GA2_BOSS_TRACE ARMED")
  end
  if armed and frame % 15 == 0 then
    screen:snapshot(string.format("%s/ga2-boss-trace-%06d.png", root, frame))
    log:flush()
  end
  if armed and exists(stop_path) then
    log:write(string.format("%d,marker,%08x,00000000,00000000,ffffffff\n",
      frame, cpu.state["PC"].value))
    log:close()
    print("GA2_BOSS_TRACE STOPPED")
    machine:exit()
  end
end)
