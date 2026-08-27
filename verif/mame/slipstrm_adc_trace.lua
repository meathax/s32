-- Deterministic Slip Stream ADC transaction trace for the cold gameplay path.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(os.getenv("S32_SLIPSTRM_ADC_OUT"),
	"S32_SLIPSTRM_ADC_OUT is required")
local log = assert(io.open(out, "w"))

local function find_field(name)
	for _, port in pairs(machine.ioport.ports) do
		for field_name, field in pairs(port.fields) do
			if field_name == name then return field end
		end
	end
	error("missing input field: " .. name)
end

local coin = find_field("Coin 1")
local start = find_field("1 Player Start")
local gear = find_field("mainpcb:Gear Change")
local paddle_port = assert(machine.ioport.ports[":mainpcb:ANALOG1"])
local frame = 0
local count = 0

_G.s32_slip_adc_read = mem:install_read_tap(
	0xc00050, 0xc00057, "slipstrm_adc_read",
	function(offset, data, mask)
		count = count + 1
		log:write(string.format(
			"R f=%d pc=%08x a=%06x d=%02x mask=%08x paddle=%02x\n",
			frame, cpu.state["PC"].value, offset, data & 0xff, mask,
			paddle_port:read() & 0xff))
		return data
	end)

_G.s32_slip_adc_write = mem:install_write_tap(
	0xc00050, 0xc00057, "slipstrm_adc_write",
	function(offset, data, mask)
		count = count + 1
		log:write(string.format(
			"W f=%d pc=%08x a=%06x d=%02x mask=%08x paddle=%02x\n",
			frame, cpu.state["PC"].value, offset, data & 0xff, mask,
			paddle_port:read() & 0xff))
		return data
	end)

_G.s32_slip_adc_result_write = mem:install_write_tap(
	0x200000, 0x20ffff, "slipstrm_adc_result_write",
	function(offset, data, mask)
		local pc = cpu.state["PC"].value
		if pc >= 0x082000 and pc < 0x082100 then
			log:write(string.format(
				"M f=%d pc=%08x a=%06x d=%04x mask=%08x\n",
				frame, pc, offset, data & 0xffff, mask))
		end
		return data
	end)

_G.s32_slip_adc_driver = emu.add_machine_frame_notifier(function()
	frame = frame + 1
	if frame == 240 then coin:set_value(1)
	elseif frame == 260 then coin:set_value(0)
	elseif frame == 320 then coin:set_value(1)
	elseif frame == 340 then coin:set_value(0)
	elseif frame == 460 then start:set_value(1)
	elseif frame == 490 then start:set_value(0)
	elseif frame == 620 then start:set_value(1)
	elseif frame == 623 then start:set_value(0)
	elseif frame == 700 then gear:set_value(0)
	elseif frame == 703 then gear:set_value(1)
	end
	if frame == 1 or frame == 500 or frame == 700 or frame == 900 then
		log:write(string.format("# f=%d pc=%08x paddle=%02x\n",
			frame, cpu.state["PC"].value, paddle_port:read() & 0xff))
		log:flush()
	end
	if frame >= 900 then machine:exit() end
end)

emu.add_machine_stop_notifier(function()
	if log then
		log:write(string.format("# done frame=%d transactions=%d\n", frame, count))
		log:close()
		log = nil
	end
end)
