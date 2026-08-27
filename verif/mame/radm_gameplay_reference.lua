-- Deterministic Rad Mobile two-credit gameplay reference for MAME 0.289.
-- The journal mirrors verif/common/tb_core_romboot.sv's COIN/COIN2/START/
-- ACCEL inputs.  Captures use the raw screen-device surface, before layout
-- artwork or host scaling.

local machine = manager.machine
local screen = assert(machine.screens[":mainpcb:screen"])
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local ports = machine.ioport.ports
local outdir = os.getenv("RADM_GAMEPLAY_OUT") or "scratch/radm_mame_gameplay"
local log = assert(io.open(outdir .. "/reference.jsonl", "w"))

local function field(name)
  for _, port in pairs(ports) do
    for field_name, value in pairs(port.fields) do
      if field_name == name then return value end
    end
  end
  error("missing input field: " .. name)
end

local coin = field("Coin 1")
local start = field("1 Player Start")
local gas = field("P1 Pedal 1")
local captures = { [600] = true, [900] = true, [1200] = true,
                   [1800] = true, [2400] = true, [3600] = true }

local function port_value(tag)
  local port = ports[tag]
  return port and port:read() or 0xffffffff
end

local function write_ppm(frame)
  local pixels, width, height = screen:pixels()
  assert(#pixels == width * height * 4)
  local path = string.format("%s/frame_%04d.ppm", outdir, frame)
  local file = assert(io.open(path, "wb"))
  file:write(string.format("P6\n%d %d\n255\n", width, height))
  local source = 1
  for _y = 1, height do
    local row = {}
    for x = 1, width do
      local blue, green, red = string.byte(pixels, source, source + 2)
      row[x] = string.char(red, green, blue)
      source = source + 4
    end
    file:write(table.concat(row))
  end
  file:close()
  return width, height
end

local frame = 0
_G.s32_radm_gameplay_reference = emu.register_frame_done(function()
  frame = frame + 1
  if frame == 300 then coin:set_value(1)
  elseif frame == 320 then coin:set_value(0)
  elseif frame == 360 then coin:set_value(1)
  elseif frame == 380 then coin:set_value(0)
  elseif frame == 500 then start:set_value(1)
  elseif frame == 530 then start:set_value(0)
  elseif frame == 600 then gas:set_value(255)
  end

  local width, height = 0, 0
  if captures[frame] then width, height = write_ppm(frame) end
  log:write(string.format(
      '{"frame":%d,"pc":%08x,"svc":%02x,"p1":%02x,"gas":%02x,' ..
      '"ram20ac80":%04x,"ram20f020":%04x,"width":%d,"height":%d}\n',
      frame, cpu.state["PC"].value, port_value(":mainpcb:SERVICE12_A"),
      port_value(":mainpcb:P1_A"), port_value(":mainpcb:ANALOG2"),
      mem:read_u16(0x20ac80), mem:read_u16(0x20f020), width, height))
  log:flush()
  if frame >= 3600 then machine:exit() end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
