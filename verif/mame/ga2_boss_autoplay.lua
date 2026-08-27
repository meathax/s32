-- Deterministic long-form GA2 autoplay used only to reach the first boss and
-- capture the boss-health meter.  Gameplay health/damage semantics are not the
-- target; repeated coin/start pulses keep the scripted run alive long enough to
-- expose the shared boss-meter routine.
local machine = manager.machine
local screen = assert(machine.screens[":mainpcb:screen"])
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local svc = assert(machine.ioport.ports[":mainpcb:SERVICE12_A"].fields)
local p1 = assert(machine.ioport.ports[":mainpcb:P1_A"].fields)
local p4 = assert(machine.ioport.ports[":mainpcb:EXTRA2"].fields)
local coin = assert(svc["Coin 1"])
local start = assert(svc["1 Player Start"])
local right = assert(p1["P1 Right"])
local up = assert(p1["P1 Up"])
local down = assert(p1["P1 Down"])
local attack = assert(p1["P1 Button 1"])
local jump = assert(p1["P1 Button 2"])
local magic = assert(p1["P1 Button 3"])
local stage_forward = assert(p4["P4 Button 1"])
local frame = 0
local stop_frame = tonumber(os.getenv("GA2_BOSS_STOP_FRAME") or "6000")
-- Wayder's published MAME scene-select value.  0x1e starts Scene 5, whose
-- opening is the shortest deterministic route to a shared boss-health meter.
local start_scene = tonumber(os.getenv("GA2_START_SCENE") or "1e", 16)
local use_stage_forward = os.getenv("GA2_STAGE_FORWARD") == "1"
local force_scene_at = tonumber(os.getenv("GA2_FORCE_SCENE_AT") or "-1")
local force_scene = tonumber(os.getenv("GA2_FORCE_SCENE") or "02", 16)
local snapshot_dir = os.getenv("GA2_BOSS_SNAPSHOT_DIR") or
  "/mnt/d/Arcade/AI/s32/scratch/mame_boss_autoplay"
local log_path = os.getenv("GA2_BOSS_LOG") or
  "/mnt/d/Arcade/AI/s32/scratch/mame_boss_autoplay.log"
local log = assert(io.open(log_path, "w"))

local function set(field, active)
  field:set_value(active and 1 or 0)
end

_G.ga2_boss_autoplay = emu.add_machine_frame_notifier(function()
  frame = frame + 1

  -- Apply the scene selector only while the game's boot variable is clear,
  -- matching the published MAME cheat's condition exactly.
  if mem:read_u8(0x20ac90) == 0 then mem:write_u8(0x20ac90, start_scene) end

  -- A post-start scene poke is a deterministic shortcut to a known subscene;
  -- unlike the boot-time selector, this preserves initialized gameplay state.
  if frame == force_scene_at then mem:write_u8(0x20ac90, force_scene) end

  -- Clean repeated pulses: initial start plus continues if the player dies.
  set(coin, (frame >= 120 and frame < 135) or
            (frame >= 240 and frame < 255) or
            (frame >= 600 and (frame % 300) < 12))
  set(start, (frame >= 220 and frame < 235) or
             (frame >= 650 and (frame % 300) < 12))

  local playing = frame >= 360
  local vertical = frame % 480
  set(right, playing)
  set(up, playing and vertical < 90)
  set(down, playing and vertical >= 240 and vertical < 330)
  set(attack, playing and (frame % 12) < 5)
  set(jump, playing and (frame % 90) < 5)
  set(magic, playing and (frame % 360) < 5)
  -- The game has a built-in P4 debug input that advances a screen/stage when
  -- its debug path is enabled. Keep it opt-in for normal reference captures.
  set(stage_forward, use_stage_forward and frame >= 900 and (frame % 240) < 5)

  if frame % 300 == 0 then
    local filename = string.format("%s/ga2-boss-%05d.png", snapshot_dir, frame)
    local err = screen:snapshot(filename)
    log:write(string.format("frame=%d pc=%08x snapshot=%s error=%s\n",
      frame, cpu.state["PC"].value, filename, tostring(err)))
    log:flush()
  end

  if frame == stop_frame then
    log:write(string.format("done frame=%d pc=%08x\n", frame, cpu.state["PC"].value))
    log:close()
    machine:exit()
  end
end)
