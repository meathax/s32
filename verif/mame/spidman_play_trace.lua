-- Deterministic Spider-Man stage-one input and camera/spawn reference trace.
-- Coin -> Start -> hold Right.  Prints only changes to the camera structure
-- pointer and world position, plus counts of spawn-gate executions.
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local svc = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local p1 = manager.machine.ioport.ports[":mainpcb:P1_A"]
local coin = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local right = p1.fields["P1 Right"]

local frame = 0
local last = ""
local gate_reads = 0

_G.spid_gate_tap = mem:install_read_tap(0x208344, 0x208347, "spid_gate",
    function(offset, data, mask)
        if cpu.state["PC"].value == 0x087A99 then gate_reads = gate_reads + 1 end
    end)

_G.spid_play = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame >= 300 and frame < 390 then
        coin:set_value(1)
    elseif frame == 390 then
        coin:set_value(0)
    end
    if frame >= 430 and frame < 450 then
        start:set_value(1)
    elseif frame == 450 then
        start:set_value(0)
    end
    if frame >= 600 then right:set_value(1) end

    local ptr = mem:read_u32(0x2082B0)
    local xy = mem:read_u32(0x208344)
    local key = string.format("%08x/%08x", ptr, xy)
    if key ~= last then
        print(string.format("SPIDPLAY f=%d ptr=%08x xy=%08x gates=%d", frame, ptr, xy, gate_reads))
        last = key
    end
    if frame == 1200 then manager.machine:exit() end
end)

emu.register_stop(function()
    print(string.format("SPIDPLAY DONE f=%d gates=%d", frame, gate_reads))
end)
