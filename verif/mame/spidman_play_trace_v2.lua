-- Input-timing calibration for Spider-Man.  Repeats clean coin/start pulses
-- through the title cycle, then holds Right and reports camera initialization.
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local svc = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local p1 = manager.machine.ioport.ports[":mainpcb:P1_A"]
local coin = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local right = p1.fields["P1 Right"]
local frame, gate_reads = 0, 0
local last = ""

_G.spid_gate_tap_v2 = mem:install_read_tap(0x208344, 0x208347, "spid_gate_v2",
    function(offset, data, mask)
        if cpu.state["PC"].value == 0x087A99 then gate_reads = gate_reads + 1 end
    end)

_G.spid_play_v2 = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    local coin_on = (frame >= 300 and frame < 390) or
                    (frame >= 600 and frame < 690) or
                    (frame >= 900 and frame < 990)
    local start_on = (frame >= 430 and frame < 450) or
                     (frame >= 730 and frame < 750) or
                     (frame >= 1030 and frame < 1050)
    coin:set_value(coin_on and 1 or 0)
    start:set_value(start_on and 1 or 0)
    right:set_value(frame >= 1100 and 1 or 0)

    local ptr = mem:read_u32(0x2082B0)
    local xy = mem:read_u32(0x208344)
    local key = string.format("%08x/%08x", ptr, xy)
    if key ~= last then
        print(string.format("SPIDPLAY f=%d ptr=%08x xy=%08x gates=%d", frame, ptr, xy, gate_reads))
        last = key
    end
    if frame == 2200 then manager.machine:exit() end
end)

emu.add_machine_stop_notifier(function()
    print(string.format("SPIDPLAY DONE f=%d gates=%d", frame, gate_reads))
end)
