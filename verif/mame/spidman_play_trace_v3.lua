-- Spider-Man input calibration, explicit edge-driven controls.
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local svc = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local p1 = manager.machine.ioport.ports[":mainpcb:P1_A"]
local coin = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local right = p1.fields["P1 Right"]
local frame, gate_reads = 0, 0
local last = ""

_G.spid_gate_tap_v3 = mem:install_read_tap(0x208344, 0x208347, "spid_gate_v3",
    function(offset, data, mask)
        if cpu.state["PC"].value == 0x087A99 then gate_reads = gate_reads + 1 end
    end)

_G.spid_play_v3 = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == 300 or frame == 600 or frame == 900 then coin:set_value(1) end
    if frame == 390 or frame == 690 or frame == 990 then coin:set_value(0) end
    if frame == 430 or frame == 730 or frame == 1030 then start:set_value(1) end
    if frame == 450 or frame == 750 or frame == 1050 then start:set_value(0) end
    if frame == 1100 then right:set_value(1) end

    local ptr = mem:read_u32(0x2082B0)
    local xy = mem:read_u32(0x208344)
    local key = string.format("%08x/%08x", ptr, xy)
    if key ~= last then
        print(string.format("SPIDPLAY f=%d ptr=%08x xy=%08x gates=%d", frame, ptr, xy, gate_reads))
        last = key
    end
    if frame == 2200 then
        print(string.format("SPIDPLAY DONE f=%d gates=%d", frame, gate_reads))
        manager.machine:exit()
    end
end)
