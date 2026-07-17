// Isolated synthesis wrapper for the production V60 core.
// Keep every external handshake visible at the probe boundary so Quartus
// cannot constant-fold normal CPU states while area settings are compared.
module v60_probe (
    input             clk,
    input             ce,
    input             rst,
    output            bus_req,
    output            bus_we,
    output     [31:0] bus_addr,
    output      [1:0] bus_size,
    output     [31:0] bus_wdata,
    input      [31:0] bus_rdata,
    input             bus_ack,
    input             irq_n,
    input       [7:0] irq_vector,
    output            irq_ack,
    input             nmi_n,
    output     [31:0] dbg_pc,
    output            dbg_halted
);

s32_v60 #(
    .START_PC(32'h00ff_fff0),
    .IS_V70(1'b0)
) dut (
    .clk(clk),
    .ce(ce),
    .rst(rst),
    .bus_req(bus_req),
    .bus_we(bus_we),
    .bus_addr(bus_addr),
    .bus_size(bus_size),
    .bus_wdata(bus_wdata),
    .bus_rdata(bus_rdata),
    .bus_ack(bus_ack),
    .irq_n(irq_n),
    .irq_vector(irq_vector),
    .irq_ack(irq_ack),
    .nmi_n(nmi_n),
    .dbg_pc(dbg_pc),
    .dbg_halted(dbg_halted)
);

endmodule
