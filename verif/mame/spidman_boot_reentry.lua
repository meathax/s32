-- Read-only Spider-Man boot-control trace.  It records the first direct
-- transfer from game ROM back into the low bootstrap and the first few
-- accepted writes that begin the work-RAM clear at byte address 0x200000.
-- No memory, register, input, or persistent state is modified.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out_path = os.getenv("S32_SPID_BOOT_TRACE")
assert(out_path and out_path ~= "", "S32_SPID_BOOT_TRACE is required")
local instruction_trace_path = os.getenv("S32_SPID_INSN_TRACE")
local stop_frame = tonumber(os.getenv("S32_SPID_BOOT_FRAMES") or "12")
local out = assert(io.open(out_path, "w"))

if instruction_trace_path and instruction_trace_path ~= "" then
    machine.debugger:command(string.format(
        'trace "%s",":mainpcb:maincpu",noloop',
        instruction_trace_path:gsub("\\", "/")))
end

local frame = 0
local ordinal = 0
local previous_pc = nil
local transfer_count = 0
local clear_count = 0
local stack_count = 0
local loop_read_count = 0
local loop_write_count = 0

local function state(name)
    local item = cpu.state[name]
    return item and item.value or 0
end

local function observe_pc(pc)
    if pc ~= previous_pc then
        ordinal = ordinal + 1
        if previous_pc and previous_pc >= 0x60000 and pc < 0x1000 then
            transfer_count = transfer_count + 1
            out:write(string.format(
                '{"lane":"mame","event":"high_to_low","ordinal":%d,' ..
                '"frame":%d,"previous_pc":"%08x","pc":"%08x",' ..
                '"sp":"%08x","psw":"%08x"}\n',
                ordinal, frame, previous_pc, pc, state("SP"), state("PSW")))
            out:flush()
        end
        previous_pc = pc
    end
end

-- This pinned native MAME build does not export an instruction-hook method to
-- Lua.  Program-ROM reads include opcode fetches, so use their architectural
-- PC as a bounded control-flow observation.  The clear-write tap below is the
-- accepted-event comparator; this ROM tap is causal context only.
_G.spid_boot_rom_tap = mem:install_read_tap(
    0x000000, 0x1fffff, "spid_boot_rom",
    function(address, data, mask)
        observe_pc(state("PC"))
        return data
    end)

_G.spid_boot_clear_tap = mem:install_write_tap(
    0x200000, 0x200001, "spid_boot_clear",
    function(address, data, mask)
        clear_count = clear_count + 1
        if clear_count <= 4 then
            out:write(string.format(
                '{"lane":"mame","event":"clear_write","ordinal":%d,' ..
                '"frame":%d,"pc":"%08x","addr":"%08x",' ..
                '"data":"%08x","mask":"%08x"}\n',
                clear_count, frame, state("PC"), address, data or 0, mask or 0))
            out:flush()
        end
        return data
    end)

_G.spid_boot_stack_tap = mem:install_read_tap(
    0x200000, 0x20ffff, "spid_boot_stack",
    function(address, data, mask)
        if state("PC") == 0x89532 then
            loop_read_count = loop_read_count + 1
            out:write(string.format(
                '{"lane":"mame","event":"loop_read","ordinal":%d,' ..
                '"frame":%d,"pc":"%08x","r0":"%08x",' ..
                '"r2":"%08x","r12":"%08x","addr":"%08x",' ..
                '"data":"%08x","mask":"%08x"}\n',
                loop_read_count, frame, state("PC"), state("R0"),
                state("R2"), state("R12"), address, data or 0, mask or 0))
        end
        if state("PC") == 0x600a7 then
            stack_count = stack_count + 1
            out:write(string.format(
                '{"lane":"mame","event":"rsr_stack_read","ordinal":%d,' ..
                '"frame":%d,"pc":"%08x","sp":"%08x",' ..
                '"addr":"%08x","data":"%08x","mask":"%08x"}\n',
                stack_count, frame, state("PC"), state("SP"),
                address, data or 0, mask or 0))
            out:flush()
        end
        return data
    end)

_G.spid_boot_io_tap = mem:install_read_tap(
    0xc00000, 0xc000ff, "spid_boot_io",
    function(address, data, mask)
        if state("PC") == 0x89532 then
            loop_read_count = loop_read_count + 1
            out:write(string.format(
                '{"lane":"mame","event":"loop_read","ordinal":%d,' ..
                '"frame":%d,"pc":"%08x","r0":"%08x",' ..
                '"r2":"%08x","r12":"%08x","addr":"%08x",' ..
                '"data":"%08x","mask":"%08x"}\n',
                loop_read_count, frame, state("PC"), state("R0"),
                state("R2"), state("R12"), address, data or 0, mask or 0))
        end
        return data
    end)

_G.spid_boot_io_write_tap = mem:install_write_tap(
    0xc00000, 0xc0001f, "spid_boot_io_write",
    function(address, data, mask)
        if state("PC") == 0x895ee and loop_write_count < 256 then
            loop_write_count = loop_write_count + 1
            out:write(string.format(
                '{"lane":"mame","event":"loop_write","ordinal":%d,' ..
                '"frame":%d,"pc":"%08x","addr":"%08x",' ..
                '"data":"%08x","mask":"%08x"}\n',
                loop_write_count, frame, state("PC"), address,
                data or 0, mask or 0))
        end
        return data
    end)

_G.spid_boot_frame = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == 7 and instruction_trace_path and
        instruction_trace_path ~= "" then
        machine.debugger:command('trace off,":mainpcb:maincpu"')
    end
    if frame >= stop_frame then
        out:write(string.format(
            '{"lane":"mame","event":"stop","frame":%d,' ..
            '"instruction_count":%d,"transfer_count":%d,' ..
            '"clear_count":%d,"stack_count":%d,"loop_read_count":%d}\n',
            frame, ordinal, transfer_count, clear_count, stack_count,
            loop_read_count))
        out:close()
        out = nil
        machine:exit()
    end
end)

emu.add_machine_stop_notifier(function()
    if out then
        out:close()
        out = nil
    end
end)
