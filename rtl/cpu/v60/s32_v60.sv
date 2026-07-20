//============================================================================
//  NEC V60 (uPD70616) / V70 (uPD70632) CPU core for the Sega System 32
//  MiSTer core.  DESIGN.md §5.
//
//  Instruction-accurate microsequenced implementation. Behavioral contract
//  is MAME's v60 core (BSD-3-Clause, Farfetch'd / R. Belmont): opcode
//  dispatch per optable.hxx, addressing modes per am1-3.hxx, exception
//  entry per v60.cpp.
//
//  Scope (per DESIGN.md §5.2/§5.3):
//   - Full integer ISA: F1/F2 two-operand ops, short-format ops, branches,
//     DBcc/TB, JMP/JSR/CALL/RET/RETIU/RETIS, PREPARE/DISPOSE, PUSH(M)/POP(M),
//     string ops (MOVC*/CMPC*/SCHC*/SKPC*), TASI, bit ops, GETPSW/UPDPSW,
//     TRAP/TRAPFL/BRK/BRKV, CHLVL, task save/load, privileged register moves
//     (LDPR/STPR), and MAME-defined decimal/bit-string/bit-field groups.
//   - Not implemented (reserved-instruction exception, logged in sim):
//     FP arithmetic/conversion (0x5C/0x5F groups). MMU/TLB effects are absent
//     like MAME, but CLRTLB still decodes its complete operand. Address-trap
//     and separate IN/OUT-space side effects remain outside the S32 profile.
//
//  Bus: logical access port; unaligned/size handled by s32_v60_bus adapter.
//============================================================================

module s32_v60 #(
    parameter [31:0] START_PC = 32'h00FFFFF0,   // V60 reset PC (V70: FFFFFFF0)
    parameter        IS_V70   = 1'b0
)(
    input             clk,
    input             ce,            // 16.108 MHz (V60) / 20 MHz (V70) enable
    input             rst,

    // logical bus (to s32_v60_bus adapter)
    output reg        bus_req,
    output reg        bus_we,
    output reg [31:0] bus_addr,
    output reg  [1:0] bus_size,      // 0=byte 1=half 2=word
    output reg [31:0] bus_wdata,
    input      [31:0] bus_rdata,
    input             bus_ack,

    // interrupts
    input             irq_n,         // level, active low
    input       [7:0] irq_vector,    // external vector (s32_intc), +0x40 applied here
    output reg        irq_ack,       // pulses when vector consumed
    input             nmi_n,

    // debug/trace
    output reg [31:0] dbg_pc,
    output            dbg_halted
);

// ---------------------------------------------------------------------------
// architectural state
// ---------------------------------------------------------------------------
reg [31:0] r[0:31];             // general registers, r[31]=active SP
integer init_reg_i;
// Deterministic FPGA cold power-up without changing the real V60 reset
// contract: subsequent reset assertions leave GPR contents untouched.
initial begin
    for (init_reg_i = 0; init_reg_i < 32; init_reg_i = init_reg_i + 1)
        r[init_reg_i] = 32'd0;
end
reg [31:0] pc;
reg [31:0] sbr, sycw, tkcw, pir, psw2;
reg [31:0] isp, l0sp, l1sp, l2sp, l3sp;   // shadow stacks (inactive copies)
reg [31:0] atbr0, atlr0, atbr1, atlr1, atbr2, atlr2, atbr3, atlr3;
reg [31:0] trmode;
reg [31:0] adtr0, adtr1, adtmr0, adtmr1;
reg [31:0] trr;                  // TR task register

// PSW fields (MAME bit layout: Z=b0,S=b1,OV=b2,CY=b3,IE=b18,EL=b25:24,IS=b28)
reg f_z, f_s, f_ov, f_cy;
reg [31:0] psw_rest;             // all non-flag PSW bits

wire [31:0] psw = {psw_rest[31:4], f_cy, f_ov, f_s, f_z};
wire        psw_ie = psw_rest[18];
wire  [1:0] psw_el = psw_rest[25:24];
wire        psw_is = psw_rest[28];

reg halted;
assign dbg_halted = halted;

// ---------------------------------------------------------------------------
// fetch buffer: 16 bytes from PC, filled before each decode
// ---------------------------------------------------------------------------
reg [7:0]  fb[0:23];        // 24 bytes: worst-case instruction is 20 bytes
reg [31:0] fb_base;          // PC the buffer window starts at
reg [4:0]  fb_valid;         // valid byte count (0..24)
reg [7:0]  fb_prev[0:23];   // previous sequential window for tight loops
reg [31:0] fb_prev_base;
reg [4:0]  fb_prev_valid;
reg        fb_realigning;
localparam [4:0] FB_THRESH = 5'd20;   // max instruction length
wire [7:0] opcode = fb[0];

// Conservative early-decode threshold.  Complex addressing modes keep the
// 20-byte worst-case requirement; only fixed encodings used heavily in branch
// loops decode sooner.  This avoids five 32-bit fetches after every taken
// branch while preserving the existing safety margin for variable-length EAs.
reg [4:0] fb_need;
always @* begin
    fb_need = FB_THRESH;
    if (fb_valid != 0) begin
        casez (fb[0])
            8'h00,                         // HALT
            8'hc8, 8'hc9, 8'hca, 8'hcd: fb_need = 5'd1; // BRK/V, RSR, NOP
            8'b0110_????:                fb_need = 5'd2; // Bcc disp8
            8'b0111_????, 8'h48:          fb_need = 5'd3; // Bcc/BSR disp16
            8'hc6, 8'hc7:                 fb_need = 5'd4; // DBcc/TB
            8'h2d: begin
                // F2 MOVW #imm32,Rn: 2D, 20|Rn, F4, imm32.
                // Wait for the mode byte before choosing the exact length.
                if (fb_valid < 3) fb_need = 5'd3;
                else if (fb[1][7:5] == 3'b001 && fb[2] == 8'hf4)
                    // Fetch through a following four-byte DBcc.  The saved
                    // window below can then serve a tight MOVW/DBcc loop
                    // without any repeated ROM transactions.
                    fb_need = 5'd11;
            end
            default: ;
        endcase
    end
end

function automatic [31:0] fb32(input [4:0] o);
    fb32 = {fb[o+3], fb[o+2], fb[o+1], fb[o]};
endfunction
function automatic [15:0] fb16(input [4:0] o);
    fb16 = {fb[o+1], fb[o]};
endfunction

// ---------------------------------------------------------------------------
// EA engine state
// ---------------------------------------------------------------------------
// plan for current instruction operands
reg        ea_want_addr;    // 0 = ReadAM (value), 1 = ReadAMAddress
reg [1:0]  ea_dim;          // 0=B 1=H 2=W
reg        ea_modm;
reg [4:0]  ea_ofs;          // mode byte offset within fetch buffer
reg [31:0] ea_out;          // value or address result
reg        ea_flag;         // 1 = out is register number (address of reg)
reg [4:0]  ea_len;          // consumed extension length (incl mode bytes)
reg [31:0] ea_addr;         // scratch: computed address
reg [2:0]  ea_ret;          // return phase selector

// operand results
reg [31:0] op1, op2;
reg        flag1, flag2;
reg [4:0]  len1, len2;

reg [7:0]  instflags;
reg [7:0]  subop;

// exec scratch
reg [31:0] alu_r;
reg [63:0] mdacc;           // mul/div accumulator
reg [5:0]  mdcnt;
reg [31:0] mdop;
reg        md_sign;
reg        md_qsign, md_rsign;   // divide result signs
// DIVX/DIVUX use a 64-bit dividend.  Keeping this path separate from the
// 32-bit MUL/DIV accumulator avoids a 96-bit combined remainder/quotient
// register and, critically, avoids synthesizing a combinational 64/32 divide.
reg [63:0] xdiv_shift;
reg [32:0] xdiv_rem;
reg [31:0] xdiv_den;
reg  [5:0] xdiv_cnt;
reg  [4:0] xdiv_dst;
reg        xdiv_qneg, xdiv_rneg;
reg        xdiv_active;
reg [31:0] exc_pushval;
reg [7:0]  exc_vector;
reg [31:0] exc_code;      // code+size word for trap/brkv-class frames (A2/A3)
reg [31:0] exc_retpc;     // return PC pushed by the frame
reg        exc_has_code;  // 1 = 3-word frame (code,PSW,PC); 0 = IRQ 2-word
reg        exc_has_extra; // BRKV adds the fault PC ahead of its 3-word frame
reg [31:0] exc_extra;
reg [1:0]  exc_target_level;
reg        exc_is_interrupt;
reg [31:0] wb_val;
reg [31:0] op2val;          // loaded value of a memory op2 (V60-1)
reg        ea_isval;        // EA mode was an immediate: result is a pure
                            // value, no address exists (quick + full imm)
reg signed [7:0] rotc_cnt;
reg [31:0] rotc_val;
reg        op2val_v;
reg [2:0]  rmw_kind;   // 0=INC 1=DEC 2=SET1 3=CLR1 4=NOT1 5=TEST1
reg [1:0]  rmw_dim;
reg [31:0] xch_addr;
reg [31:0] task_mask, task_addr;
reg [5:0]  task_phase;
reg        task_reloaded;
// V60 F1 encodings can carry two nine-byte effective-address operands:
// opcode/flags + 9 + 9 = 20 bytes.  Four bits silently wrapped those legal
// instruction lengths and advanced PC into the middle of the instruction.
reg [4:0]  total_len;
reg [4:0]  reg_ptr;         // PUSHM/POPM iterator
reg [31:0] str_cnt;
reg [31:0] str_src, str_dst;   // string op source/dest addresses (A1)
reg [31:0] str_len1, str_len2; // string op operand lengths
reg [7:0]  dec_pat;            // 0x59 decimal group: F7c pattern byte
reg [7:0]  dec_cur;            // current destination byte (BCD ops)
reg [15:0] dec_res;            // result awaiting memory write-back

// 0x5B/0x5D bit string / bit field state (V60-10)
reg [31:0] bam_base;           // BAM: byte base address
reg [31:0] bam_off;            // BAM: bit offset (full, before &7 fold)
reg        bam_second;         // decoding the second BAM operand
reg [1:0]  bam_flow;           // 0=EXTBF 1=INSBF 2=SCHBS 3=MOVBS
reg [31:0] bit_len;            // field/string length
reg [31:0] bit_val;            // op1 value / dword scratch
reg [31:0] bs_base1, bs_off1;  // MOVBS first-operand result
reg [2:0]  bs_soff, bs_doff;   // bit positions in current bytes
reg [7:0]  bs_sdata, bs_ddata; // current source/dest bytes
reg [1:0]  bs_ph;              // MOVB per-bit micro-phase
reg        bs_adv_done;        // MOVS: pointer advance already applied

// ---------------------------------------------------------------------------
// sequencer
// ---------------------------------------------------------------------------
typedef enum logic [6:0] {
    S_RESET, S_FILL, S_FILLW, S_DECODE,
    S_IF2,                       // have instflags, plan F12 operands
    S_EA_MODE, S_EA_IND, S_EA_IND2, S_EA_VAL, S_EA_DONE,
    S_EXEC, S_OP2_LD, S_MULDIV, S_DIVX, S_WB_MEM, S_NEXT, S_RMW_RD, S_RMW_EX, S_XCH1, S_XCH2, S_ROTC,
    S_BR_TAKE,
    S_PUSH, S_POP, S_PUSHM, S_POPM,
    S_JSR1, S_RET1, S_RET2, S_RETI1, S_RETI2, S_RETI3, S_CALL1, S_CALL1b, S_RSR,
    S_STR_OP1, S_STR_OP2, S_STR_RD, S_STR_WR, S_STR_NEXT,
    S_DEC_OP1, S_DEC_OP2, S_DEC_RD, S_DEC_EX, S_DEC_WR,
    S_BAM_MODE, S_BAM_IND, S_BAM_VAL,
    S_BF_EXT1, S_BF_EXTW,
    S_BF_INS1, S_BF_INS2, S_BF_INSRD, S_BF_INSWR,
    S_BS_SCH1, S_BS_SCHRD, S_BS_SCHB, S_BS_SCHW,
    S_BS_MOV1, S_BS_MOV2, S_BS_MOVS, S_BS_MOVD, S_BS_MOVB, S_BS_MOVF,
    S_EXC_PUSH1, S_EXC_EXTRA, S_EXC_CODE, S_EXC_PUSH2, S_EXC_VEC, S_EXC_JMP,
    S_TASK_LD_NEXT, S_TASK_LD_ACK, S_TASK_ST_NEXT, S_TASK_ST_ACK,
    S_TASI1, S_TASI2,
    S_PREP1, S_DISP1,
    S_HALT
} st_t;

st_t st, st_after_ea, st_after_fill;

// One restoring-division bit per enabled CPU clock.  The 33-bit trial value
// is the only compare/subtract datapath used for all 64 dividend bits.
wire [32:0] xdiv_trial = {xdiv_rem[31:0], xdiv_shift[63]};
wire        xdiv_take = xdiv_trial >= {1'b0, xdiv_den};
wire [32:0] xdiv_rem_next = xdiv_take
                            ? xdiv_trial - {1'b0, xdiv_den} : xdiv_trial;
wire [63:0] xdiv_shift_next = {xdiv_shift[62:0], xdiv_take};
wire [31:0] xdiv_qresult = xdiv_qneg
                           ? (~xdiv_shift_next[31:0] + 1'b1)
                           : xdiv_shift_next[31:0];
wire [31:0] xdiv_rresult = xdiv_rneg
                           ? (~xdiv_rem_next[31:0] + 1'b1)
                           : xdiv_rem_next[31:0];

// which operand the EA engine is filling
reg ea_target2;

// instruction class latched at decode
typedef enum logic [4:0] {
    C_NONE, C_F12, C_BR8, C_BR16, C_DBCC, C_JMP, C_JSR, C_RET, C_RETI,
    C_PUSH, C_POP, C_PUSHM, C_POPM, C_PREPARE, C_DISPOSE, C_TRAP, C_BRK,
    C_STRING, C_CLR1GRP, C_SHORT, C_MISC
} cls_t;
cls_t cls;

reg [7:0] cur_op;

// Consolidate every dynamic general-register read onto two explicit ports.
// The architectural register array remains flip-flop based with its existing
// nonblocking write semantics; these selectors only remove duplicated 32:1
// read muxes inferred at each use site.
function automatic [4:0] pushm_index(input [31:0] mask);
    integer i;
    begin
        pushm_index = 5'd31;
        for (i = 0; i < 32; i = i + 1)
            if (mask[i]) pushm_index = i[4:0];
    end
endfunction

// condition codes (V60 order used by Bcc/DBcc): V,NV,C/L,NC/NL,Z/E,NZ/NE,NH,H,N,P,R(always),-,LT,GE,LE,GT
function automatic cond_true(input [3:0] cc);
    case (cc)
        4'h0: cond_true = f_ov;
        4'h1: cond_true = ~f_ov;
        4'h2: cond_true = f_cy;
        4'h3: cond_true = ~f_cy;
        4'h4: cond_true = f_z;
        4'h5: cond_true = ~f_z;
        4'h6: cond_true = f_cy | f_z;
        4'h7: cond_true = ~(f_cy | f_z);
        4'h8: cond_true = f_s;
        4'h9: cond_true = ~f_s;
        4'ha: cond_true = 1'b1;
        4'hb: cond_true = 1'b0;
        4'hc: cond_true = f_s ^ f_ov;
        4'hd: cond_true = ~(f_s ^ f_ov);
        4'he: cond_true = (f_s ^ f_ov) | f_z;
        4'hf: cond_true = ~((f_s ^ f_ov) | f_z);
    endcase
endfunction

// sign/zero helpers per dim
function automatic [7:0] bin2bcd(input [6:0] v);   // 0-99 -> packed BCD
    logic [6:0] t, o;
    t = v / 7'd10; o = v % 7'd10;
    bin2bcd = {t[3:0], o[3:0]};
endfunction

// C-style truncating divide-by-8 of a signed bit offset (MAME bamoffset/8)
function automatic [31:0] bitdiv8(input [31:0] off);
    bitdiv8 = off[31] ? (32'h0 - ((32'h0 - off) >> 3)) : (off >> 3);
endfunction

function automatic [31:0] dimext(input [31:0] v, input [1:0] d);
    case (d)
        2'd0: dimext = {24'b0, v[7:0]};
        2'd1: dimext = {16'b0, v[15:0]};
        default: dimext = v;
    endcase
endfunction
function automatic sgn(input [31:0] v, input [1:0] d);
    case (d) 2'd0: sgn = v[7]; 2'd1: sgn = v[15]; default: sgn = v[31]; endcase
endfunction
function automatic zer(input [31:0] v, input [1:0] d);
    case (d) 2'd0: zer = v[7:0]==0; 2'd1: zer = v[15:0]==0; default: zer = v==0; endcase
endfunction

// Funnel every architectural-register update through two masked write ports.
// The V60 can retire at most two register writes in one FSM cycle.  Keeping
// the decoders here avoids rebuilding a 32-way write network at every
// syntactic assignment site in the monolithic instruction FSM.
reg        rf_we0, rf_we1;
reg [4:0]  rf_waddr0, rf_waddr1;
reg [31:0] rf_wdata0, rf_wdata1;
reg [31:0] rf_wmask0, rf_wmask1;

task automatic queue_reg_write(
    input [4:0] rn,
    input [31:0] v,
    input [31:0] mask
);
    if (!rf_we0) begin
        rf_we0 = 1'b1;
        rf_waddr0 = rn;
        rf_wdata0 = v;
        rf_wmask0 = mask;
    end
    else begin
        rf_we1 = 1'b1;
        rf_waddr1 = rn;
        rf_wdata1 = v;
        rf_wmask1 = mask;
    end
endtask

// merge result into register per dim (SETREG8/16 semantics)
task automatic setreg(input [4:0] rn, input [31:0] v, input [1:0] d);
    case (d)
        2'd0: queue_reg_write(rn, v, 32'h0000_00ff);
        2'd1: queue_reg_write(rn, v, 32'h0000_ffff);
        default: queue_reg_write(rn, v, 32'hffff_ffff);
    endcase
endtask

// stack-bank bookkeeping: swap active SP when PSW level/IS changes
task automatic save_stack(input [31:0] oldpsw);
    if (oldpsw[28]) isp <= r[31];
    else case (oldpsw[25:24])
        2'd0: l0sp <= r[31]; 2'd1: l1sp <= r[31];
        2'd2: l2sp <= r[31]; 2'd3: l3sp <= r[31];
    endcase
endtask
function automatic [31:0] pick_stack(input [31:0] newpsw);
    if (newpsw[28]) pick_stack = isp;
    else case (newpsw[25:24])
        2'd0: pick_stack = l0sp; 2'd1: pick_stack = l1sp;
        2'd2: pick_stack = l2sp; 2'd3: pick_stack = l3sp;
    endcase
endfunction

task automatic write_psw_after_sp(input [31:0] v, input [31:0] sp_now);
    if (((v ^ psw) & 32'h1000_0000) != 0 ||
        (!psw[28] && ((v ^ psw) & 32'h0300_0000) != 0)) begin
        if (psw[28]) isp <= sp_now;
        else case (psw[25:24])
            2'd0: l0sp <= sp_now; 2'd1: l1sp <= sp_now;
            2'd2: l2sp <= sp_now; 2'd3: l3sp <= sp_now;
        endcase
        queue_reg_write(5'd31, pick_stack(v), 32'hffff_ffff);
    end
    psw_rest <= v;
    f_z  <= v[0];
    f_s  <= v[1];
    f_ov <= v[2];
    f_cy <= v[3];
endtask

task automatic write_psw(input [31:0] v);
    // stack switch on IS change, or EL change while IS=0 (MAME v60WritePSW)
    if (((v ^ psw) & 32'h1000_0000) != 0 ||
        (!psw[28] && ((v ^ psw) & 32'h0300_0000) != 0)) begin
        save_stack(psw);
        queue_reg_write(5'd31, pick_stack(v), 32'hffff_ffff);
    end
    psw_rest <= v;
    f_z  <= v[0];
    f_s  <= v[1];
    f_ov <= v[2];
    f_cy <= v[3];
endtask

// ---------------------------------------------------------------------------
// EA engine (combinational mode/extension parse; sequential memory derefs)
//   Implements s_AMTable1/2/3 dispatch:
//   modm=0: 0..2 Disp8/16/32, 3 RegInd, 4..6 DispIndirect(deferred), 7 Group7
//   modm=1: 0..2 DoubleDisp,  3 Reg,    4 AutoInc, 5 AutoDec, 6 Group6(idx)
// ---------------------------------------------------------------------------
wire [7:0] modval  = fb[ea_ofs];
wire [4:0] modreg  = modval[4:0];
wire [2:0] modtop  = modval[7:5];
wire [7:0] modval2 = fb[ea_ofs+1];

reg  [4:0] rf_raddr_a, rf_raddr_b;
// Keep the architectural register file in flops, but expose exactly two
// combinational read ports.  Constant-index case arms are intentional:
// Icarus can corrupt its runtime stack on a variable-index unpacked-array
// read, and a function which reaches out to r[] can miss value-only changes
// in its inferred sensitivity.  These explicit blocks are stable in all
// simulators and still synthesize as one 32:1 mux per port.
reg [31:0] rf_rdata_a, rf_rdata_b;
always @* begin
    case (rf_raddr_a)
        5'd0:  rf_rdata_a = r[0];   5'd1:  rf_rdata_a = r[1];
        5'd2:  rf_rdata_a = r[2];   5'd3:  rf_rdata_a = r[3];
        5'd4:  rf_rdata_a = r[4];   5'd5:  rf_rdata_a = r[5];
        5'd6:  rf_rdata_a = r[6];   5'd7:  rf_rdata_a = r[7];
        5'd8:  rf_rdata_a = r[8];   5'd9:  rf_rdata_a = r[9];
        5'd10: rf_rdata_a = r[10];  5'd11: rf_rdata_a = r[11];
        5'd12: rf_rdata_a = r[12];  5'd13: rf_rdata_a = r[13];
        5'd14: rf_rdata_a = r[14];  5'd15: rf_rdata_a = r[15];
        5'd16: rf_rdata_a = r[16];  5'd17: rf_rdata_a = r[17];
        5'd18: rf_rdata_a = r[18];  5'd19: rf_rdata_a = r[19];
        5'd20: rf_rdata_a = r[20];  5'd21: rf_rdata_a = r[21];
        5'd22: rf_rdata_a = r[22];  5'd23: rf_rdata_a = r[23];
        5'd24: rf_rdata_a = r[24];  5'd25: rf_rdata_a = r[25];
        5'd26: rf_rdata_a = r[26];  5'd27: rf_rdata_a = r[27];
        5'd28: rf_rdata_a = r[28];  5'd29: rf_rdata_a = r[29];
        5'd30: rf_rdata_a = r[30];  default: rf_rdata_a = r[31];
    endcase
end
always @* begin
    case (rf_raddr_b)
        5'd0:  rf_rdata_b = r[0];   5'd1:  rf_rdata_b = r[1];
        5'd2:  rf_rdata_b = r[2];   5'd3:  rf_rdata_b = r[3];
        5'd4:  rf_rdata_b = r[4];   5'd5:  rf_rdata_b = r[5];
        5'd6:  rf_rdata_b = r[6];   5'd7:  rf_rdata_b = r[7];
        5'd8:  rf_rdata_b = r[8];   5'd9:  rf_rdata_b = r[9];
        5'd10: rf_rdata_b = r[10];  5'd11: rf_rdata_b = r[11];
        5'd12: rf_rdata_b = r[12];  5'd13: rf_rdata_b = r[13];
        5'd14: rf_rdata_b = r[14];  5'd15: rf_rdata_b = r[15];
        5'd16: rf_rdata_b = r[16];  5'd17: rf_rdata_b = r[17];
        5'd18: rf_rdata_b = r[18];  5'd19: rf_rdata_b = r[19];
        5'd20: rf_rdata_b = r[20];  5'd21: rf_rdata_b = r[21];
        5'd22: rf_rdata_b = r[22];  5'd23: rf_rdata_b = r[23];
        5'd24: rf_rdata_b = r[24];  5'd25: rf_rdata_b = r[25];
        5'd26: rf_rdata_b = r[26];  5'd27: rf_rdata_b = r[27];
        5'd28: rf_rdata_b = r[28];  5'd29: rf_rdata_b = r[29];
        5'd30: rf_rdata_b = r[30];  default: rf_rdata_b = r[31];
    endcase
end

always @* begin
    rf_raddr_a = 5'd0;
    rf_raddr_b = 5'd0;
    case (st)
        S_DECODE:  rf_raddr_a = fb[1][4:0];
        S_IF2:     rf_raddr_a = instflags[4:0];
        S_EA_MODE: begin
            rf_raddr_a = modreg;
            rf_raddr_b = modval2[4:0];
        end
        S_PUSHM:   rf_raddr_a = pushm_index(op1);
        S_STR_OP1: rf_raddr_a = fb[5'd2 + len1][4:0];
        S_STR_OP2: rf_raddr_a = fb[5'd3 + len1 + len2][4:0];
        S_DEC_OP2: begin
            rf_raddr_a = fb[5'd2 + len1 + len2][4:0];
            rf_raddr_b = op2[4:0];
        end
        S_BAM_MODE: begin
            rf_raddr_a = modreg;
            rf_raddr_b = modval2[4:0];
        end
        S_BF_EXT1, S_BS_SCH1, S_BS_MOV1:
            rf_raddr_a = fb[5'd2 + len1][4:0];
        S_BF_INS2:
            rf_raddr_a = fb[5'd2 + len1 + len2][4:0];
        S_TASK_ST_NEXT:
            if (task_phase >= 6'd5) rf_raddr_a = task_phase - 6'd5;
        S_EXEC: begin
            rf_raddr_a = ((cur_op == 8'ha6) || (cur_op == 8'hb6))
                         ? op2[4:0] + 5'd1 : op1[4:0];
            rf_raddr_b = op2[4:0];
        end
        default: ;
    endcase
end

// extension displacement follows mode byte(s)
// A 20-byte F1 instruction can place the second double-displacement field at
// fetch-buffer offset 16.  Keep the full five-bit offset used by the buffer.
function automatic [31:0] disp_of(input [4:0] base, input [1:0] sz);
    case (sz)
        2'd0: disp_of = {{24{fb[base][7]}}, fb[base]};
        2'd1: disp_of = {{16{fb[base+1][7]}}, fb16(base)};
        default: disp_of = fb32(base);
    endcase
endfunction
function automatic [4:0] disp_len(input [1:0] sz);
    disp_len = (sz==2'd0) ? 5'd1 : (sz==2'd1) ? 5'd2 : 5'd4;
endfunction

// immediate length by dim
function automatic [4:0] imm_len(input [1:0] d);
    imm_len = (d==2'd0) ? 5'd1 : (d==2'd1) ? 5'd2 : 5'd4;
endfunction

// autoinc step
function automatic [31:0] dim_step(input [1:0] d);
    dim_step = (d==2'd0) ? 32'd1 : (d==2'd1) ? 32'd2 : 32'd4;
endfunction

// ---------------------------------------------------------------------------
// main FSM
// ---------------------------------------------------------------------------

reg [3:0] fill_lo;
reg nmi_r, nmi_seen;

// ALU for F12 exec (combinational on latched ops)
wire [1:0] dim  = cur_op[2:1];   // many ops encode B/H/W in bits 2:1 (see decode)

always @(posedge clk) begin
if (rst) begin
    st <= S_RESET;
    bus_req <= 0; bus_we <= 0; irq_ack <= 0;
    bus_addr <= 0; bus_size <= 0; bus_wdata <= 0;
    halted <= 0;
    dbg_pc <= START_PC;
    nmi_seen <= 0;
    nmi_r <= 0;
    xdiv_active <= 0;
end
else if (ce) begin
    rf_we0 = 1'b0;
    rf_we1 = 1'b0;
    rf_waddr0 = 5'd0;
    rf_waddr1 = 5'd0;
    rf_wdata0 = 32'd0;
    rf_wdata1 = 32'd0;
    rf_wmask0 = 32'd0;
    rf_wmask1 = 32'd0;
    irq_ack <= 0;
    nmi_r <= ~nmi_n;
    if (~nmi_n & ~nmi_r) nmi_seen <= 1'b1;

    case (st)
    // ------------------------------------------------------------------
    S_RESET: begin
        pc       <= START_PC;
        psw_rest <= 32'h1000_0000;
        {f_z,f_s,f_ov,f_cy} <= 4'b0;
        sbr  <= 32'h0000_0000;
        sycw <= 32'h0000_0070;
        tkcw <= 32'h0000_e000;
        pir  <= IS_V70 ? 32'h0000_7000 : 32'h0000_6000;
        psw2 <= 32'h0000_f002;
        isp <= 0; l0sp <= 0; l1sp <= 0; l2sp <= 0; l3sp <= 0;
        trr <= 0;
        atbr0 <= 0; atlr0 <= 0; atbr1 <= 0; atlr1 <= 0;
        atbr2 <= 0; atlr2 <= 0; atbr3 <= 0; atlr3 <= 0;
        trmode <= 0;
        adtr0 <= 0; adtr1 <= 0; adtmr0 <= 0; adtmr1 <= 0;
        halted <= 0;
        fb_base <= START_PC;
        fb_valid <= 0;
        fb_prev_base <= START_PC;
        fb_prev_valid <= 0;
        fb_realigning <= 0;
        st <= S_FILL;
        st_after_fill <= S_DECODE;
       
    end

    // ------------------------------------------------------------------
    // incremental fetch buffer (perf): keep bytes across sequential flow.
    //  - window realign: if pc moved forward within the valid window,
    //    shift out consumed bytes (4/cycle).  Save the pre-shift window so a
    //    branch back to the preceding instruction can restore it directly.
    //    Other misses invalidate normally.
    //  - top-up 4 bytes per 32-bit logical read until fb_need is valid.
    S_FILL: begin
        if (fb_base != pc) begin
            logic [31:0] delta;
            delta = pc - fb_base;
            if (delta < {27'b0, fb_valid}) begin
                // consume min(delta,4) bytes this cycle
                logic [2:0] s;
                s = (delta >= 4) ? 3'd4 : delta[2:0];
                if (!fb_realigning) begin
                    for (int i = 0; i < 24; i++) fb_prev[i] <= fb[i];
                    fb_prev_base  <= fb_base;
                    fb_prev_valid <= fb_valid;
                end
                for (int i = 0; i < 24; i++)
                    if (i + s < 24) fb[i] <= fb[i + s];
                fb_base  <= fb_base + {29'b0, s};
                fb_valid <= fb_valid - {2'b0, s};
                fb_realigning <= (delta > 4);
            end
            else begin
                fb_realigning <= 0;
                if (fb_prev_valid != 0 && pc == fb_prev_base) begin
                    for (int i = 0; i < 24; i++) fb[i] <= fb_prev[i];
                    fb_valid <= fb_prev_valid;
                    fb_base  <= fb_prev_base;
                end
                else begin
                    fb_valid <= 0;
                    fb_base  <= pc;
                    fb_prev_valid <= 0;
                end
            end
        end
        else if (fb_valid >= fb_need) begin
            fb_realigning <= 0;
            st <= st_after_fill;
        end
        else begin
            bus_req  <= 1'b1;
            bus_we   <= 1'b0;
            bus_size <= 2'd2;
            bus_addr <= pc + {27'b0, fb_valid};
            st <= S_FILLW;
        end
    end
    S_FILLW: if (bus_ack) begin
        bus_req <= 0;
        for (int i = 0; i < 24; i++)
            if (i >= fb_valid && i < fb_valid + 4)
                fb[i] <= bus_rdata[(i - fb_valid)*8 +: 8];
        fb_valid <= (fb_valid > 5'd20) ? 5'd24 : fb_valid + 5'd4;
        st <= S_FILL;
    end

    // ------------------------------------------------------------------
    S_DECODE: begin
        dbg_pc <= pc;
        cur_op <= opcode;
        total_len <= 5'd2;      // default for F12 base
        // exception-frame defaults (A8): 2-word frame returning to current PC;
        // TRAP/BRKV override with a 3-word code frame and adjusted return PC.
        exc_has_code <= 1'b0;
        exc_has_extra <= 1'b0;
        exc_target_level <= 2'd0;
        exc_is_interrupt <= 1'b0;
        exc_retpc    <= pc;
        rmw_kind     <= 3'd7;   // sentinel: not an RMW writeback
        op2val_v     <= 1'b0;
        // interrupts sampled at instruction boundary
        if (nmi_seen) begin
            nmi_seen <= 0;
            exc_vector <= 8'd2;
            exc_pushval <= psw;
            exc_retpc <= pc;
            exc_has_code <= 1'b0;      // NMI: 2-word frame (v60_do_irq)
            exc_is_interrupt <= 1'b1;
            st <= S_EXC_PUSH1;
        end
        else if (!irq_n && psw_ie) begin
            irq_ack <= 1'b1;
            exc_vector <= irq_vector + 8'h40;
            exc_pushval <= psw;
            exc_retpc <= pc;
            exc_has_code <= 1'b0;      // IRQ: 2-word frame
            exc_is_interrupt <= 1'b1;
            st <= S_EXC_PUSH1;
        end
        else if (halted) st <= S_HALT;
        else begin
        // primary dispatch (per MAME optable.hxx)
        casez (opcode)
        // ---- one-byte / special ----
        8'h00: begin halted <= 1'b1; st <= S_HALT; end                    // HALT
        8'hcd: begin pc <= pc + 1; st <= S_FILL; st_after_fill <= S_DECODE; end // NOP
        8'hc8: begin // BRK — MAME skips this opcode (A4)
            // synthesis translate_off
            $display("V60: BRK skipped at %08x", pc);
            // synthesis translate_on
            pc <= pc + 1; st <= S_FILL; st_after_fill <= S_DECODE;
        end
        8'hc9: begin // BRKV (A3): only if OV; 3-word frame code 0x1501, vector 21
            if (f_ov) begin
                exc_vector   <= 8'd21;
                exc_code     <= 32'h1501_0004;   // EXCEPTION_CODE_AND_SIZE(0x1501,4)
                exc_extra    <= pc;
                exc_pushval  <= psw;
                exc_retpc    <= pc + 1;
                exc_has_code <= 1'b1;
                exc_has_extra <= 1'b1;
                st <= S_EXC_PUSH1;
            end
            else begin pc <= pc + 1; st <= S_FILL; st_after_fill<=S_DECODE; end
        end

        // 0x6B/0x7B are holes in MAME's authoritative primary dispatch
        // table, not branch-condition encodings.  Enter the reserved-
        // instruction vector rather than silently treating condition B as
        // false and continuing after the displacement.
        8'h6b, 8'h7b: begin
            exc_vector <= 8'd8;
            exc_pushval <= psw;
            st <= S_EXC_PUSH1;
        end

        // ---- Bcc disp8 (0x60-0x6a,0x6c-0x6f) / disp16 equivalent ----
        8'b0110_????: begin
            if (cond_true(opcode[3:0]))
                 pc <= pc + {{24{fb[1][7]}}, fb[1]};
            else pc <= pc + 2;
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
        8'b0111_????: begin
            logic [15:0] bd16;
            bd16 = fb16(1);
            if (cond_true(opcode[3:0]))
                 pc <= pc + {{16{bd16[15]}}, bd16};
            else pc <= pc + 3;
            st <= S_FILL; st_after_fill <= S_DECODE;
        end

        // ---- BSR disp16 (0x48): push return, branch ----
        8'h48: begin
            logic [15:0] bd16;
            bd16 = fb16(1);
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= r[31] - 4;
            bus_wdata <= pc + 3;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            wb_val <= pc + {{16{bd16[15]}}, bd16};
            st <= S_JSR1;
        end

        // ---- DBcc/TB (0xC6/0xC7): sub-op byte = {cc[2:0], reg[4:0]} ----
        8'hc6, 8'hc7: begin
            logic [3:0] cc4;
            case ({opcode[0], fb[1][7:5]})
                4'b0000: cc4 = 4'h0; 4'b0001: cc4 = 4'h2; 4'b0010: cc4 = 4'h4;
                4'b0011: cc4 = 4'h6; 4'b0100: cc4 = 4'h8; 4'b0101: cc4 = 4'ha; // DBR
                4'b0110: cc4 = 4'hc; 4'b0111: cc4 = 4'he;
                4'b1000: cc4 = 4'h1; 4'b1001: cc4 = 4'h3; 4'b1010: cc4 = 4'h5;
                4'b1011: cc4 = 4'h7; 4'b1100: cc4 = 4'h9; 4'b1101: cc4 = 4'hb; // TB: cond false = never -> only reg!=0? (TB tests true)
                4'b1110: cc4 = 4'hd; default: cc4 = 4'hf;
            endcase
            // MAME opDBcc: reg ALWAYS decrements; branch iff cond true and
            // decremented reg != 0. TB: branch iff reg == 0 (no decrement).
            begin
                logic [15:0] bd16;
                bd16 = fb16(2);
                if ({opcode[0], fb[1][7:5]} == 4'b1101) begin
                    if (rf_rdata_a == 0) pc <= pc + {{16{bd16[15]}}, bd16};
                    else pc <= pc + 4;
                end
                else begin
                    queue_reg_write(fb[1][4:0], rf_rdata_a - 1, 32'hffff_ffff);
                    if (cond_true(cc4) && (rf_rdata_a - 1) != 0)
                         pc <= pc + {{16{bd16[15]}}, bd16};
                    else pc <= pc + 4;
                end
            end
            st <= S_FILL; st_after_fill <= S_DECODE;
        end

        // ---- F12 two-operand groups ----
        // MOV/logic/arith B/H/W + friends: route through generic F12 engine
        8'h01,                                   // LDTASK
        8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d,       // MOVB, MOVSBH, MOVZBH, MOVSBW, MOVZBW
        8'h19, 8'h1b, 8'h1c, 8'h1d,              // MOVTHB, MOVH, MOVSHW, MOVZHW
        8'h29, 8'h2b, 8'h2c, 8'h2d, 8'h08,       // MOVTWB, MOVTWH, RVBYT, MOVW, RVBIT
        8'h38, 8'h39, 8'h3a, 8'h3b, 8'h3c, 8'h3d,// NOT/NEG B/H/W
        8'h40, 8'h42, 8'h44,                     // MOVEA B/H/W
        8'h41, 8'h43, 8'h45,                     // XCH B/H/W
        8'h47,                                   // SETF
        8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55,// REM/REMU B/H/W
        8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h85,// ADD/MUL B/H/W
        8'h88, 8'h89, 8'h8a, 8'h8b, 8'h8c, 8'h8d,// OR/ROT B/H/W
        8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95,// ADDC/MULU
        8'h98, 8'h99, 8'h9a, 8'h9b, 8'h9c, 8'h9d,// SUBC/ROTC
        8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5,// AND/DIV
        8'ha7, 8'h97, 8'h87, 8'hb7,              // CLR1/SET1/TEST1/NOT1
        8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had,// SUB/SHL
        8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5,// XOR/DIVU
        8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd,// CMP/SHA
        8'h86, 8'h96, 8'ha6, 8'hb6,              // MULX/MULUX/DIVX/DIVUX
        8'h3f: begin                             // MOVD (64-bit move)
            instflags <= fb[1];
            cls <= C_F12;
            st <= S_IF2;
        end

        // ---- single-operand format (opcode LSB = modm), operand at PC+1 ----
        8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5,          // DEC B/H/W
        8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd,          // INC B/H/W
        8'hd6, 8'hd7,                                      // JMP
        8'he0, 8'he1,                                      // TASI
        8'he6, 8'he7,                                      // POP
        8'he8, 8'he9,                                      // JSR
        8'hee, 8'hef,                                      // PUSH
        8'he4, 8'he5, 8'hec, 8'hed,                        // POPM/PUSHM
        8'hf0, 8'hf1, 8'hf2, 8'hf3, 8'hf4, 8'hf5,          // TEST B/H/W
        8'hf6, 8'hf7,                                      // GETPSW
        8'hf8, 8'hf9,                                      // TRAP
        8'hfc, 8'hfd,                                      // STTASK
        8'hfe, 8'hff,                                      // CLRTLB (operand consumed; MMU absent)
        8'hde, 8'hdf,                                      // PREPARE
        8'he2, 8'he3,                                      // RET
        8'hea, 8'heb, 8'hfa, 8'hfb: begin                  // RETIU/RETIS
            cls <= C_SHORT;
            ea_modm  <= opcode[0];
            ea_ofs   <= 5'd1;
            ea_target2 <= 1'b0;
            // choose value vs address per op
            casez (opcode)
                // JMP/JSR/TASI: MAME sets moddim=0 — the dim scales INDEXED
                // modes' index register, and ga2's jump tables (3-byte BR
                // entries, `JMP [PC+d](rN)`) rely on the unscaled index
                // (found by real-ROM boot: dim=2 quadrupled the index and
                // jumped mid-table into a reserved-op trap)
                8'hd6, 8'hd7, 8'he8, 8'he9: begin ea_want_addr <= 1'b1; ea_dim <= 2'd0; end // JMP/JSR
                8'he0, 8'he1: begin ea_want_addr <= 1'b1; ea_dim <= 2'd0; end               // TASI (byte)
                8'hee, 8'hef, 8'hf6, 8'hf7: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end // PUSH val / GETPSW dst? (GETPSW writes -> addr)
                8'he6, 8'he7: begin ea_want_addr <= 1'b1; ea_dim <= 2'd2; end               // POP dst addr
                8'hd0, 8'hd1, 8'hd8, 8'hd9: begin ea_want_addr <= 1'b1; ea_dim <= 2'd0; end // DEC/INC B (RMW)
                8'hd2, 8'hd3, 8'hda, 8'hdb: begin ea_want_addr <= 1'b1; ea_dim <= 2'd1; end
                8'hd4, 8'hd5, 8'hdc, 8'hdd: begin ea_want_addr <= 1'b1; ea_dim <= 2'd2; end
                8'hf0, 8'hf1: begin ea_want_addr <= 1'b0; ea_dim <= 2'd0; end               // TEST reads
                8'hf2, 8'hf3: begin ea_want_addr <= 1'b0; ea_dim <= 2'd1; end
                8'hf4, 8'hf5: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end
                8'hf8, 8'hf9: begin ea_want_addr <= 1'b0; ea_dim <= 2'd0; end               // TRAP vector operand
                8'hfc, 8'hfd: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // STTASK mask
                8'hfe, 8'hff: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // CLRTLB operand
                8'hde, 8'hdf: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // PREPARE imm
                8'he2, 8'he3: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end // RET adj (word)
                8'hea, 8'heb, 8'hfa, 8'hfb:
                              begin ea_want_addr <= 1'b0; ea_dim <= 2'd1; end // RETI adj (halfword, MAME moddim=1)
                8'he4, 8'he5, 8'hec, 8'hed:
                              begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end               // POPM/PUSHM mask (imm)
                default: begin ea_want_addr <= 1'b0; ea_dim <= 2'd2; end
            endcase
            ea_ret <= 3'd0;
            st <= S_EA_MODE;
            st_after_ea <= S_EXEC;
        end

        // ---- GETPSW is a write op: handle as address ----
        // (covered above; exec handles)

        // ---- string groups (A1): F7a operand+length encoding ----
        //   subop @ fb[1]; op1 = source EA (modm=subop[6]) @ ofs2;
        //   len1 byte follows op1; op2 = dest EA (modm=subop[5]); len2 byte.
        8'h58, 8'h5a: begin  // byte/half string ops
            subop <= fb[1];
            case (fb[1][4:0])
            5'h00, 5'h01, 5'h02,
            5'h08, 5'h09, 5'h0a, 5'h0b, 5'h0c,
            5'h18, 5'h19, 5'h1a, 5'h1b: begin
                cls <= C_STRING;
                ea_want_addr <= 1'b1;
                ea_dim   <= 2'd2;
                ea_modm  <= fb[1][6];
                ea_ofs   <= 5'd2;
                ea_target2 <= 1'b0;
                ea_ret   <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_STR_OP1;
            end
            default: begin
                exc_vector <= 8'd8;
                exc_pushval <= psw;
                st <= S_EXC_PUSH1;
            end
            endcase
        end
        8'h59: begin
            // decimal group (F7c): op1 = value, op2 = address, ext byte.
            // MAME implements ADDDC/SUBDC/SUBRDC/CVTDPZ/CVTDZP (radm timer);
            // remaining subops are reserved there too.
            subop <= fb[1];
            case (fb[1][4:0])
            5'h00, 5'h01, 5'h02, 5'h10, 5'h18: begin
                cls <= C_STRING;
                ea_want_addr <= 1'b0;                            // op1 value
                ea_dim  <= (fb[1][4:0] == 5'h18) ? 2'd1 : 2'd0;  // CVTDZP: half
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b0;
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_DEC_OP1;
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                // synthesis translate_off
                $display("V60: unimplemented 59 sub %02x at %08x", fb[1], pc);
                // synthesis translate_on
            end
            endcase
        end
        8'h5b: begin
            // bit strings: SCH0BSU(0)/SCH1BSU(2), MOVBSU(8)/MOVBSD(9)
            subop <= fb[1];
            case (fb[1][4:0])
            5'h00, 5'h02, 5'h08, 5'h09: begin
                cls <= C_STRING;
                bam_flow <= fb[1][3] ? 2'd3 : 2'd2;   // MOVBS : SCHBS
                bam_second <= 1'b0;
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                st <= S_BAM_MODE;
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                // synthesis translate_off
                $display("V60: unimplemented 5B sub %02x at %08x", fb[1], pc);
                // synthesis translate_on
            end
            endcase
        end
        8'h5d: begin
            // bit fields: EXTBFS(8)/EXTBFZ(9)/EXTBFL(A), INSBFR(18)/INSBFL(19)
            subop <= fb[1];
            case (fb[1][4:0])
            5'h08, 5'h09, 5'h0a: begin              // EXTBF*: op1 = bit VALUE
                cls <= C_STRING;
                bam_flow <= 2'd0;
                bam_second <= 1'b0;
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                st <= S_BAM_MODE;
            end
            5'h18, 5'h19: begin                     // INSBF*: op1 = word value
                cls <= C_STRING;
                bam_flow <= 2'd1;
                ea_want_addr <= 1'b0;
                ea_dim  <= 2'd2;
                ea_modm <= fb[1][6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b0;
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_BF_INS1;
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                // synthesis translate_off
                $display("V60: unimplemented 5D sub %02x at %08x", fb[1], pc);
                // synthesis translate_on
            end
            endcase
        end
        8'h5c, 8'h5f: begin
            // single-float ops: reserved-instruction trap (MAME leaves the
            // groups un-dispatched for S32 games as well)
            exc_vector <= 8'd8;
            exc_pushval <= psw;
            st <= S_EXC_PUSH1;
            // synthesis translate_off
            $display("V60: unimplemented group %02x sub %02x at %08x", opcode, fb[1], pc);
            // synthesis translate_on
        end

        // ---- privileged / system ----
        8'h02: begin // STPR: privileged reg -> operand : treat via F12-like short path
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end
        8'h12: begin // LDPR
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end
        8'h13, 8'h4a: begin // UPDPSW.W / UPDPSW.H
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end
        8'h4b: begin instflags <= fb[1]; cls <= C_F12; st <= S_IF2; end // CHLVL
        8'h4d, 8'h4e, 8'h4f: begin instflags <= fb[1]; cls <= C_F12; st <= S_IF2; end // CHKA*
        8'h49: begin instflags <= fb[1]; cls <= C_F12; st <= S_IF2; end // CALL
        8'hcc: begin // DISPOSE: SP = FP (R30), pop FP
            queue_reg_write(5'd31, r[30], 32'hffff_ffff);
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2; bus_addr <= r[30];
            st <= S_DISP1;
        end
        8'hca: begin // RSR (A9): pop PC ONLY (MAME opRSR: PC=[SP]; SP+=4)
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2; bus_addr <= r[31];
            st <= S_RSR;
        end
        8'hcb: begin // TRAPFL
            // MAME/NEC floating-exception test: enabled TKCW causes are
            // intersected with the PSW floating-status field.  PSW.TP alone
            // is unrelated and must not spuriously vector here.
            if ((tkcw & 32'h0000_01f0) & ((psw & 32'h0000_1f00) >> 4)) begin
                exc_vector <= 8'd15; exc_pushval <= psw; st <= S_EXC_PUSH1;
            end else begin
                pc <= pc + 1; st <= S_FILL; st_after_fill<=S_DECODE;
            end
        end
        8'h10: begin // CLRTLBA: no MMU -> one-byte NOP
            pc <= pc + 1;
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
        8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25: begin // IN/OUT -> F12 engine
            instflags <= fb[1]; cls <= C_F12; st <= S_IF2;
        end

        default: begin
            // reserved instruction
            // synthesis translate_off
            $display("V60: reserved opcode %02x at %08x", opcode, pc);
            // synthesis translate_on
            exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
        end
        endcase
        end
    end

    // ------------------------------------------------------------------
    // F12: plan operands per instflags (MAME F12DecodeOperands)
    S_IF2: begin
        // operand roles: for most ops op1=ReadAM(value), op2=addr(write) —
        // exceptions handled in S_EXEC via flags.
        if (instflags[7]) begin
            // F1: both operands have mode bytes
            ea_modm  <= instflags[6];
            ea_ofs   <= 5'd2;
            ea_target2 <= 1'b0;
            // MOVEA takes op1 as an ADDRESS (MAME ReadAMAddress) — decoding
            // it as a value loaded SP with a byte read instead of the EA and
            // sent ga2's boot stub off a cliff (found by real-ROM boot)
            ea_want_addr <= f12_op1_is_addr(cur_op);
            ea_dim   <= f12_dim1(cur_op);
            ea_ret   <= 3'd1;       // after op1 -> decode op2
            st <= S_EA_MODE;
            st_after_ea <= S_EXEC;  // will be overridden by ea_ret handling
        end
        else begin
            if (instflags[5]) begin
                // F2 D=1: op2 = reg, op1 = AM
                op2   <= {27'b0, instflags[4:0]};
                flag2 <= 1'b1;
                len2  <= 0;
                ea_modm <= instflags[6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b0;
                ea_want_addr <= f12_op1_is_addr(cur_op);
                ea_dim  <= f12_dim1(cur_op);
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_EXEC;
            end
            else begin
                // F2 D=0: op1 = reg value, op2 = AM(write)
                op1   <= dimext(rf_rdata_a, f12_dim1(cur_op));
                flag1 <= 1'b0;
                len1  <= 0;
                ea_modm <= instflags[6];
                ea_ofs  <= 5'd2;
                ea_target2 <= 1'b1;
                ea_want_addr <= 1'b1;   // op2 as address for write
                ea_dim  <= f12_dim2(cur_op);
                ea_ret  <= 3'd0;
                st <= S_EA_MODE;
                st_after_ea <= S_EXEC;
            end
        end
    end

    // ------------------------------------------------------------------
    // EA engine.
    // NOTE: all fb-reading helper functions (disp_of/fb16/fb32) are hoisted
    // into blocking temporaries before use in nonblocking assignments —
    // the Verilator simulator (5.020) mis-evaluates such calls in an NBA RHS
    // inside this case tree (found by real-ROM boot: ga2's MOVEA PC-relative
    // displacement silently read as 0).
    S_EA_MODE: begin
        logic [31:0] d1t, d2t;
        ea_flag  <= 1'b0;
        ea_isval <= 1'b0;
        if (!ea_modm) begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // Displacement
                d1t = disp_of(ea_ofs+1, modtop[1:0]);
                ea_addr <= rf_rdata_a + d1t;
                ea_len  <= 5'd1 + disp_len(modtop[1:0]);
                st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
            end
            3'd3: begin             // Register Indirect
                ea_addr <= rf_rdata_a;
                ea_len  <= 5'd1;
                st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
            end
            3'd4, 3'd5, 3'd6: begin // Displacement Indirect (deferred)
                d1t = disp_of(ea_ofs+1, modtop - 3'd4);
                bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                bus_addr <= rf_rdata_a + d1t;
                ea_len  <= 5'd1 + disp_len(modtop - 3'd4);
                st <= S_EA_IND;
            end
            default: begin          // Group 7
                casez (modreg)
                5'b0????: begin      // immediate quick
                    ea_out <= {28'b0, modreg[3:0]};
                    ea_len <= 5'd1;
                    ea_flag <= 1'b0;
                    ea_isval <= 1'b1;
                    st <= S_EA_DONE;  // value already
                end
                5'h10, 5'h11, 5'h12: begin // PC displacement
                    d1t = disp_of(ea_ofs+1, modreg[1:0]);
                    ea_addr <= pc + d1t;
                    ea_len  <= 5'd1 + disp_len(modreg[1:0]);
                    st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
                end
                5'h13: begin        // direct address
                    d1t = fb32(ea_ofs+1);
                    ea_addr <= d1t;
                    ea_len  <= 5'd5;
                    st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
                end
                5'h14: begin        // immediate full
                    d1t = fb32(ea_ofs+1);
                    d2t = {16'b0, fb16(ea_ofs+1)};
                    case (ea_dim)
                        2'd0: ea_out <= {24'b0, fb[ea_ofs+1]};
                        2'd1: ea_out <= d2t;
                        default: ea_out <= d1t;
                    endcase
                    ea_len <= 5'd1 + imm_len(ea_dim);
                    ea_isval <= 1'b1;
                    st <= S_EA_DONE;
                end
                5'h18, 5'h19, 5'h1a: begin // PC displacement indirect
                    d1t = disp_of(ea_ofs+1, modreg[1:0]);
                    bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                    bus_addr <= pc + d1t;
                    ea_len  <= 5'd1 + disp_len(modreg[1:0]);
                    st <= S_EA_IND;
                end
                5'h1b: begin        // direct address deferred
                    d1t = fb32(ea_ofs+1);
                    bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                    bus_addr <= d1t;
                    ea_len  <= 5'd5;
                    st <= S_EA_IND;
                end
                5'h1c, 5'h1d, 5'h1e: begin // PC double displacement
                    d1t = disp_of(ea_ofs+1, modreg[1:0]);
                    d2t = disp_of(ea_ofs+1+disp_len(modreg[1:0]), modreg[1:0]);
                    bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                    bus_addr <= pc + d1t;
                    ea_addr <= d2t;      // second disp follows first
                    ea_len  <= 5'd1 + {disp_len(modreg[1:0]), 1'b0}; // 1 + 2*len
                    st <= S_EA_IND2;
                end
                default: begin
                    exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                end
                endcase
            end
            endcase
        end
        else begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // Double displacement: [[reg+d1]+d2]
                d1t = disp_of(ea_ofs+1, modtop[1:0]);
                d2t = disp_of(ea_ofs+1+disp_len(modtop[1:0]), modtop[1:0]);
                bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                bus_addr <= rf_rdata_a + d1t;
                ea_addr  <= d2t;
                ea_len   <= 5'd1 + {disp_len(modtop[1:0]), 1'b0};
                st <= S_EA_IND2;
            end
            3'd3: begin             // Register direct
                if (ea_want_addr) begin
                    ea_out  <= {27'b0, modreg};
                    ea_flag <= 1'b1;
                end
                else ea_out <= dimext(rf_rdata_a, ea_dim);
                ea_len <= 5'd1;
                st <= S_EA_DONE;
            end
            3'd4: begin             // Autoincrement
                ea_addr <= rf_rdata_a;
                queue_reg_write(modreg, rf_rdata_a + dim_step(ea_dim), 32'hffff_ffff);
                ea_len <= 5'd1;
                st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
            end
            3'd5: begin             // Autodecrement
                ea_addr <= rf_rdata_a - dim_step(ea_dim);
                queue_reg_write(modreg, rf_rdata_a - dim_step(ea_dim), 32'hffff_ffff);
                ea_len <= 5'd1;
                st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
            end
            3'd6: begin             // Group 6: indexed, second mode byte
                case (modval2[7:5])
                3'd0, 3'd1, 3'd2: begin // Displacement indexed: [reg2+disp] + reg1*size
                    d1t = disp_of(ea_ofs+2, modval2[6:5]);
                    ea_addr <= rf_rdata_b + d1t + (rf_rdata_a << ea_dim);
                    ea_len  <= 5'd2 + disp_len(modval2[6:5]);
                    st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
                end
                3'd3: begin            // Register indirect indexed
                    ea_addr <= rf_rdata_b + (rf_rdata_a << ea_dim);
                    ea_len  <= 5'd2;
                    st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
                end
                3'd4, 3'd5, 3'd6: begin // Displacement indirect indexed
                    d1t = disp_of(ea_ofs+2, modval2[6:5]);
                    bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                    bus_addr <= rf_rdata_b + d1t;
                    ea_addr <= (rf_rdata_a << ea_dim);  // index added after deref
                    ea_len  <= 5'd2 + disp_len(modval2[6:5]);
                    st <= S_EA_IND2;
                end
                default: begin // Group7a: PC/direct indexed
                    if (!modval2[4]) begin
                        exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                    end
                    else case (modval2[3:0])
                    4'h0, 4'h1, 4'h2: begin
                        d1t = disp_of(ea_ofs+2, modval2[1:0]);
                        ea_addr <= pc + d1t + (rf_rdata_a << ea_dim);
                        ea_len  <= 5'd2 + disp_len(modval2[1:0]);
                        st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
                    end
                    4'h3: begin
                        d1t = fb32(ea_ofs+2);
                        ea_addr <= d1t + (rf_rdata_a << ea_dim);
                        ea_len  <= 5'd6;
                        st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
                    end
                    4'h8, 4'h9, 4'ha: begin
                        d1t = disp_of(ea_ofs+2, modval2[1:0]);
                        bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                        bus_addr <= pc + d1t;
                        ea_addr <= (rf_rdata_a << ea_dim);
                        ea_len  <= 5'd2 + disp_len(modval2[1:0]);
                        st <= S_EA_IND2;
                    end
                    4'hb: begin
                        d1t = fb32(ea_ofs+2);
                        bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                        bus_addr <= d1t;
                        ea_addr <= (rf_rdata_a << ea_dim);
                        ea_len  <= 5'd6;
                        st <= S_EA_IND2;
                    end
                    default: begin
                        exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                    end
                    endcase
                end
                endcase
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
            end
            endcase
        end
    end

    // deferred pointer fetched -> address is pointer (+0)
    S_EA_IND: if (bus_ack) begin
        bus_req <= 0;
        ea_addr <= bus_rdata;
        st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
    end
    // deferred pointer fetched -> address = pointer + saved offset (double disp / indexed deferred)
    S_EA_IND2: if (bus_ack) begin
        bus_req <= 0;
        ea_addr <= bus_rdata + ea_addr;
        st <= ea_want_addr ? S_EA_DONE : S_EA_VAL;
    end
    // load value at ea_addr
    S_EA_VAL: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0;
            bus_size <= ea_dim;
            bus_addr <= ea_addr;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            ea_out <= dimext(bus_rdata, ea_dim);
            st <= S_EA_DONE;
        end
    end
    S_EA_DONE: begin
        if (ea_want_addr && !ea_flag && st == S_EA_DONE) begin
            // address results: pass ea_addr unless already produced (imm/reg)
        end
        // Immediate modes carry no address: the "address requested" path
        // must still hand back the value (MAME LDPR-quirk equivalent), and
        // op2 immediates pre-fill op2val so S_OP2_LD never dereferences a
        // stale ea_addr (found by real-ROM boot: ga2's `LDPR #imm, #5`
        // loaded SBR with garbage and the first vblank IRQ derailed).
        if (!ea_target2) begin
            op1   <= (ea_want_addr && !ea_isval) ? (ea_flag ? ea_out : ea_addr) : ea_out;
            flag1 <= ea_flag;
            len1  <= ea_len;
        end
        else begin
            op2   <= (ea_want_addr && !ea_isval) ? (ea_flag ? ea_out : ea_addr) : ea_out;
            flag2 <= ea_flag;
            len2  <= ea_len;
            if (ea_isval) begin
                op2val   <= ea_out;
                op2val_v <= 1'b1;
            end
        end
        // continuation: ea_ret==1 -> decode operand 2 (F1)
        if (ea_ret == 3'd1) begin
            ea_ret <= 3'd0;
            ea_modm <= instflags[5];
            ea_ofs  <= 5'd2 + ea_len;
            ea_target2 <= 1'b1;
            ea_want_addr <= 1'b1;    // op2 default = address (write target)
            ea_dim  <= f12_dim2(cur_op);
            st <= S_EA_MODE;
        end
        else st <= st_after_ea;
    end

    // ------------------------------------------------------------------
    // EXEC: per-opcode semantics on op1/op2
    S_EXEC: begin
        if (cls == C_F12 && !flag2 && !op2val_v && f12_reads_dest(cur_op)) begin
            st <= S_OP2_LD;   // V60-1: load memory destination before exec
        end
        else begin
            st <= S_NEXT;   // default: single-cycle exec, then advance
            total_len <= 5'd2 + len1 + len2;
            exec_op();      // task below sets wb / flags / possibly overrides st
        end
    end
    S_OP2_LD: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0;
            bus_size <= f12_dim2(cur_op);
            bus_addr <= op2;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            op2val   <= dimext(bus_rdata, f12_dim2(cur_op));
            op2val_v <= 1'b1;
            st <= S_EXEC;
        end
    end

    // iterative multiply/divide
    S_MULDIV: begin
        if (mdcnt == 0) begin
            md_finish();
            st <= S_NEXT;
        end
        else begin
            md_step();
            mdcnt <= mdcnt - 1'd1;
        end
    end

    // DIVX/DIVUX: unsigned magnitude division followed by architectural sign
    // correction.  Sixty-four iterations preserve the old 64-bit expression,
    // including low-32 quotient truncation when the mathematical result is
    // wider than the destination register.
    S_DIVX: begin
        xdiv_shift <= xdiv_shift_next;
        xdiv_rem <= xdiv_rem_next;
        if (xdiv_cnt == 6'd63) begin
            queue_reg_write(xdiv_dst, xdiv_qresult, 32'hffff_ffff);
            queue_reg_write(xdiv_dst + 5'd1, xdiv_rresult, 32'hffff_ffff);
            f_z <= (xdiv_qresult == 0);
            f_s <= xdiv_qresult[31];
            f_ov <= 1'b0;
            xdiv_active <= 1'b0;
            st <= S_NEXT;
        end
        else xdiv_cnt <= xdiv_cnt + 1'd1;
    end

    // ROTC: 1 bit/cycle through carry (V60-5)
    S_ROTC: begin
        if (rotc_cnt == 0) begin
            logic [1:0] d2l;
            d2l = f12_dim2(cur_op);
            set_zs(rotc_val, d2l);
            f_ov <= 0;
            wb_op2(rotc_val, d2l);
            if (st == S_ROTC) st <= S_NEXT;  // wb_op2 may set S_WB_MEM
        end
        else if (rotc_cnt > 0) begin
            logic [1:0] d2l;
            logic msb;
            d2l = f12_dim2(cur_op);
            msb = sgn(rotc_val, d2l);
            // MAME opROTC*: the carry bit enters the active operand's LSB;
            // bits above a byte/halfword operand are not part of the ring.
            case (d2l)
                2'd0: rotc_val <= {24'b0, rotc_val[6:0], f_cy};
                2'd1: rotc_val <= {16'b0, rotc_val[14:0], f_cy};
                default: rotc_val <= {rotc_val[30:0], f_cy};
            endcase
            f_cy <= msb;
            rotc_cnt <= rotc_cnt - 1;
        end
        else begin
            logic [1:0] d2l;
            logic ls;
            d2l = f12_dim2(cur_op);
            ls = rotc_val[0];
            // Right rotate-through-carry enters at bit 7/15/31 according
            // to the destination width (op12.hxx opROTCB/H/W).
            case (d2l)
                2'd0: rotc_val <= {24'b0, f_cy, rotc_val[7:1]};
                2'd1: rotc_val <= {16'b0, f_cy, rotc_val[15:1]};
                default: rotc_val <= {f_cy, rotc_val[31:1]};
            endcase
            f_cy <= ls;
            rotc_cnt <= rotc_cnt + 1;
        end
    end

    // generic memory RMW: read op2 -> modify per rmw_kind -> write back
    S_RMW_RD: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= rmw_dim; bus_addr <= op2;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            alu_r <= bus_rdata;
            st <= S_RMW_EX;
        end
    end
    S_RMW_EX: begin
        logic [31:0] v;
        logic [4:0]  bi;
        v = alu_r;
        bi = wb_val[4:0];
        case (rmw_kind)
            3'd0: begin // INC
                v = dimext(alu_r, rmw_dim) + 1;
                f_cy <= zer(v, rmw_dim);        // carry when wrapped to 0
                set_zs(v, rmw_dim);
            end
            3'd1: begin // DEC
                f_cy <= zer(alu_r, rmw_dim);    // borrow when was 0
                v = dimext(alu_r, rmw_dim) - 1;
                set_zs(v, rmw_dim);
            end
            3'd2: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; v[bi] = 1'b1; end // SET1
            3'd3: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; v[bi] = 1'b0; end // CLR1
            3'd4: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; v[bi] = ~alu_r[bi]; end // NOT1
            default: begin f_z <= ~alu_r[bi]; f_cy <= alu_r[bi]; end            // TEST1
        endcase
        if (rmw_kind == 3'd5) st <= S_NEXT;      // TEST1: no write
        else begin
            wb_val <= v;
            // write via S_WB_MEM but with rmw width
            st <= S_WB_MEM;
        end
    end

    // XCH reg<->mem: read mem, write reg value to mem, mem value to reg
    S_XCH1: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= rmw_dim; bus_addr <= xch_addr;
        end
        else if (bus_ack) begin
            // drop the request for one cycle — the bus adapter starts a new
            // transaction on a c_req RISING EDGE; re-asserting back-to-back
            // deadlocked ga2's XCH.W lock idiom (found by real-ROM boot)
            bus_req <= 0;
            setreg(wb_val[4:0], bus_rdata, rmw_dim);   // mem -> reg
            st <= S_XCH2;
        end
    end
    S_XCH2: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= rmw_dim;
            bus_addr <= xch_addr; bus_wdata <= alu_r;  // reg -> mem
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            st <= S_NEXT;
        end
    end

    // memory writeback of wb_val to op2 address (dim = f12_dim2)
    S_WB_MEM: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1;
            bus_size <= (rmw_kind != 3'd7) ? rmw_dim : f12_dim2(cur_op);
            bus_addr <= op2;
            bus_wdata <= wb_val;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            st <= S_NEXT;
        end
    end

    // advance PC and refill
    S_NEXT: begin
        pc <= pc + total_len;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // ------------------------------------------------------------------
    // JSR/BSR: return pushed, jump
    S_JSR1: if (bus_ack) begin
        bus_req <= 0; bus_we <= 0;
        pc <= wb_val;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // CALL (A6): AP push completes here, then push return PC and jump.
    S_CALL1: begin
        if (bus_ack) begin               // AP push done
            // one-cycle request gap: the adapter needs a c_req rising edge
            bus_req <= 0; bus_we <= 0;
            st <= S_CALL1b;
        end
    end
    S_CALL1b: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= r[31] - 4;
            bus_wdata <= wb_val;          // return PC
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        end
        else if (bus_ack) begin           // return-PC push done
            bus_req <= 0; bus_we <= 0;
            pc <= alu_r;                  // target
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
    end

    // RET (A5): pop PC, then restore AP (R30), then skip frame (SP += operand)
    S_RET1: if (bus_ack) begin
        bus_req <= 0;
        pc <= bus_rdata;
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
        st <= S_RET2;
    end
    S_RET2: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
            bus_addr <= r[31];
        end
        else if (bus_ack) begin
            bus_req <= 0;
            queue_reg_write(5'd29, bus_rdata, 32'hffff_ffff); // AP (R29)
            queue_reg_write(5'd31, r[31] + 4 + wb_val, 32'hffff_ffff);
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
    end

    // RETIU/RETIS/RSR: pop PC then PSW
    S_RETI1: if (bus_ack) begin
        bus_req <= 0;
        wb_val <= bus_rdata;   // new PC
        st <= S_RETI2;
    end
    S_RETI2: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
            bus_addr <= r[31] + 4;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            st <= S_RETI3;
            alu_r <= bus_rdata;  // new PSW
        end
    end
    S_RETI3: begin
        // pops (8) + frame-destroy operand (MAME: SP += amout), then the
        // PSW write may bank-switch SP — order matters: adjust THEN switch.
        queue_reg_write(5'd31, r[31] + 8 + xch_addr, 32'hffff_ffff);
        write_psw_after_sp(alu_r, r[31] + 8 + xch_addr);
        pc <= wb_val;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // DISPOSE: FP fetched
    S_DISP1: if (bus_ack) begin
        bus_req <= 0;
        queue_reg_write(5'd30, bus_rdata, 32'hffff_ffff); // FP = R30
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
        pc <= pc + 1;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // RSR (A9): pop PC only, SP += 4
    S_RSR: if (bus_ack) begin
        bus_req <= 0;
        pc <= bus_rdata;
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
        st <= S_FILL; st_after_fill <= S_DECODE;
    end

    // PUSHM/POPM iterate register mask in op1
    S_PUSHM: begin
        if (reg_ptr == 5'd31 && !op1[31]) begin
            // done check handled in loop below
        end
        if (op1 == 0) st <= S_NEXT;
        else if (!bus_req) begin
            // push highest set register first (MAME pushes from r31 down? actual: PUSHM pushes ascending list to stack)
            // idx = lowest set bit; push in increasing register order
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= r[31] - 4;
            bus_wdata <= rf_rdata_a;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            reg_ptr <= pushm_index(op1);
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            op1[reg_ptr] <= 1'b0;
        end
    end
    S_POPM: begin
        if (op1 == 0) st <= S_NEXT;
        else if (!bus_req) begin
            logic [4:0] idx;
            idx = 5'd0;
            for (int i = 31; i >= 0; i--) if (op1[i]) idx = i[4:0];
            // pop lowest-numbered... (POPM restores in reverse of PUSHM)
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
            bus_addr <= r[31];
            reg_ptr <= idx;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            queue_reg_write(reg_ptr, bus_rdata, 32'hffff_ffff);
            queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
            op1[reg_ptr] <= 1'b0;
        end
    end

    // TASI: read byte at addr, set flags, write 0xFF
    S_TASI1: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd0; bus_addr <= op1;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            f_z <= (bus_rdata[7:0] != 0);   // MAME opTASI: Z = (old != 0)? per notes
            f_s <= bus_rdata[7];
            f_ov <= 0; f_cy <= (bus_rdata[7:0] == 8'hff);
            st <= S_TASI2;
        end
    end
    S_TASI2: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd0;
            bus_addr <= op1; bus_wdata <= 32'hff;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            st <= S_NEXT;
        end
    end

    // PREPARE: push FP, FP=SP, SP-=imm
    S_PREP1: if (bus_ack) begin
        bus_req <= 0; bus_we <= 0;
        queue_reg_write(5'd30, r[31] - 4, 32'hffff_ffff); // FP = R30
        queue_reg_write(5'd31, r[31] - 4 - op1, 32'hffff_ffff);
        st <= S_NEXT;
    end

    // ------------------------------------------------------------------
    // string operations (A1): F7a operand+length decode.
    //   op1 (from S_EA_DONE, ea_target2=0) = source address.
    //   length byte at fb[2+len1]; op2 = dest address; length at fb[3+len1+len2].
    //   R27 (dst) / R28 (src) updated at completion (MAME MOVSTR).
    S_STR_OP1: begin
        // op1 = source address; read len1 byte then decode op2
        logic [7:0] lb;
        str_src <= op1;
        lb = fb[5'd2 + len1];
        str_len1 <= lb[7] ? rf_rdata_a : {24'b0, lb};
        // decode op2 at ofs = 3 + len1. F7a (MOVC/CMPC): address. F7b
        // (SCHC/SKPC 0x18-0x1B): search VALUE, and no len2 byte follows.
        ea_want_addr <= (subop[4:0] >= 5'h18) ? 1'b0 : 1'b1;
        ea_dim   <= 2'd2;
        ea_modm  <= subop[5];
        ea_ofs   <= 5'd3 + len1;
        ea_target2 <= 1'b1;
        ea_ret   <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_STR_OP2;
    end
    S_STR_OP2: begin
        logic [7:0] lb;
        logic [31:0] l2;
        str_dst <= op2;                      // F7b: search value lives here
        if (subop[4:0] >= 5'h18) begin
            // F7b: single length; count = len1
            str_cnt <= str_len1;
            total_len <= 5'd3 + len1 + len2;
            // SEARCH also finalizes Z/R27/R28 for a zero-length range.
            st <= S_STR_RD;
        end
        else begin
            lb = fb[5'd3 + len1 + len2];
            l2 = lb[7] ? rf_rdata_a : {24'b0, lb};
            str_len2 <= l2;
            str_cnt <= (str_len1 < l2) ? str_len1 : l2;
            total_len <= 5'd4 + len1 + len2;
            st <= ((str_len1 < l2 ? str_len1 : l2) == 0) ? S_NEXT : S_STR_RD;
        end
    end
    S_STR_RD: begin
        if (str_cnt == 0) begin
            // V60 SEARCH uses the opposite Z sense from the published
            // manual: Z=1 only when the whole range is exhausted.  R27 is
            // the element index and R28 is the address at that index.  GA2
            // exercises the upward form; downward pointer semantics remain
            // separate from this completion/flag correction.
            if (subop[4:0] >= 5'h18) begin
                f_z <= 1'b1;
                queue_reg_write(5'd27, str_len1, 32'hffff_ffff);
                queue_reg_write(5'd28, str_src, 32'hffff_ffff);
            end
            st <= S_NEXT;
        end
        else if (!bus_req) begin
            bus_req <= 1; bus_we <= 0;
            bus_size <= cur_op[1] ? 2'd1 : 2'd0;  // 0x58=byte, 0x5a=half
            bus_addr <= str_src;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            alu_r <= bus_rdata;
            case (subop[4:0])
            5'h08, 5'h09, 5'h0a, 5'h0b, 5'h0c: st <= S_STR_WR; // MOVC*
            5'h00, 5'h01, 5'h02: st <= S_STR_WR;                // CMPC* (2nd read)
            5'h18, 5'h19, 5'h1a, 5'h1b: begin                   // SCHC/SKPC
                logic eq;
                // compare element with the decoded search value (F7b op2)
                eq = (cur_op[1] ? (bus_rdata[15:0]==str_dst[15:0]) : (bus_rdata[7:0]==str_dst[7:0]));
                if (eq == (subop[1] ? 1'b0 : 1'b1)) begin
                    f_z <= 1'b0;
                    queue_reg_write(5'd27, str_len1 - str_cnt, 32'hffff_ffff);
                    queue_reg_write(5'd28, str_src, 32'hffff_ffff);
                    st <= S_NEXT;
                end
                else begin
                    str_src <= subop[0] ? str_src - (cur_op[1]?2:1) : str_src + (cur_op[1]?2:1);
                    str_cnt <= str_cnt - 1;
                    st <= S_STR_RD;
                end
            end
            default: st <= S_NEXT;
            endcase
        end
    end
    S_STR_WR: begin
        if (!bus_req) begin
            case (subop[4:0])
            5'h00, 5'h01, 5'h02: begin // CMPC second read (dest element)
                bus_req <= 1; bus_we <= 0;
                bus_size <= cur_op[1] ? 2'd1 : 2'd0;
                bus_addr <= str_dst;
            end
            default: begin             // MOVC write
                bus_req <= 1; bus_we <= 1;
                bus_size <= cur_op[1] ? 2'd1 : 2'd0;
                bus_addr <= str_dst;
                bus_wdata <= alu_r;
            end
            endcase
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            if (subop[4:0] <= 5'h02) begin
                // CMPC: compare source vs dest element
                logic [31:0] a, b;
                a = cur_op[1] ? {16'b0,alu_r[15:0]} : {24'b0,alu_r[7:0]};
                b = cur_op[1] ? {16'b0,bus_rdata[15:0]} : {24'b0,bus_rdata[7:0]};
                if (a != b) begin
                    f_z <= 0;
                    f_s <= (a < b);
                    queue_reg_write(5'd28, str_src, 32'hffff_ffff);
                    queue_reg_write(5'd27, str_dst, 32'hffff_ffff);
                    st <= S_NEXT;
                end
                else begin f_z <= 1; st <= S_STR_NEXT; end
            end
            else st <= S_STR_NEXT;
        end
    end
    // ------------------------------------------------------------------
    // 0x59 decimal group (F7c): op1 value decoded; now op2 as address
    S_DEC_OP1: begin
        ea_want_addr <= 1'b1;
        ea_dim  <= (subop[4:0] == 5'h10) ? 2'd1 : 2'd0;  // CVTDPZ dest: half
        ea_modm <= subop[5];
        ea_ofs  <= 5'd2 + len1;
        ea_target2 <= 1'b1;
        ea_ret  <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_DEC_OP2;
    end
    S_DEC_OP2: begin
        // trailing ext byte (pattern), same reg-or-literal coding as lengths
        logic [7:0] xb;
        xb = fb[5'd2 + len1 + len2];
        dec_pat <= xb[7] ? rf_rdata_a[7:0] : xb;
        total_len <= 5'd3 + len1 + len2;
        if (subop[4:0] <= 5'h02) begin            // ADDDC/SUBDC/SUBRDC: RMW
            if (flag2) begin
                dec_cur <= rf_rdata_b[7:0];
                st <= S_DEC_EX;
            end
            else st <= S_DEC_RD;
        end
        else st <= S_DEC_EX;                       // CVTD*: write-only dest
    end
    S_DEC_RD: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd0; bus_addr <= op2;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            dec_cur <= bus_rdata[7:0];
            st <= S_DEC_EX;
        end
    end
    S_DEC_EX: begin
        logic [6:0] srcv, dstv;
        logic signed [8:0] sum;
        logic [7:0]  resb;
        logic [15:0] resh;
        logic        cyo;
        srcv = ({3'b0, op1[7:4]} * 7'd10) + {3'b0, op1[3:0]};
        dstv = ({3'b0, dec_cur[7:4]} * 7'd10) + {3'b0, dec_cur[3:0]};
        case (subop[4:0])
        5'h00, 5'h01, 5'h02: begin
            case (subop[4:0])
            5'h00:   sum = $signed({2'b0, srcv}) + $signed({2'b0, dstv})
                           + (f_cy ? 9'sd1 : 9'sd0);              // ADDDC
            5'h01:   sum = $signed({2'b0, dstv}) - $signed({2'b0, srcv})
                           - (f_cy ? 9'sd1 : 9'sd0);              // SUBDC
            default: sum = $signed({2'b0, srcv}) - $signed({2'b0, dstv})
                           - (f_cy ? 9'sd1 : 9'sd0);              // SUBRDC
            endcase
            if (subop[4:0] == 5'h00) begin
                cyo = (sum >= 9'sd100);
                if (cyo) sum = sum - 9'sd100;
            end
            else begin
                cyo = (sum < 0);
                if (cyo) sum = sum + 9'sd100;
            end
            f_cy <= cyo;
            if (sum != 0 || cyo) f_z <= 1'b0;      // Z sticky-clears only
            resb = bin2bcd(sum[6:0]);
            if (flag2) begin
                queue_reg_write(op2[4:0], resb, 32'h0000_00ff);
                st <= S_NEXT;
            end
            else begin
                dec_res <= {8'b0, resb};
                st <= S_DEC_WR;
            end
        end
        5'h10: begin                               // CVTDPZ: packed -> zoned
            resh = {({4'b0, op1[3:0]} | dec_pat),
                    ({4'b0, op1[7:4]} | dec_pat)};
            if (op1[7:0] != 0) f_z <= 1'b0;
            if (flag2) begin
                queue_reg_write(op2[4:0], resh, 32'h0000_ffff);
                st <= S_NEXT;
            end
            else begin
                dec_res <= resh;
                st <= S_DEC_WR;
            end
        end
        default: begin                             // CVTDZP: zoned -> packed
            resb = {op1[3:0], op1[11:8]};
            if (resb != 0) f_z <= 1'b0;
            if (flag2) begin
                queue_reg_write(op2[4:0], resb, 32'h0000_00ff);
                st <= S_NEXT;
            end
            else begin
                dec_res <= {8'b0, resb};
                st <= S_DEC_WR;
            end
        end
        endcase
    end
    S_DEC_WR: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1;
            bus_size <= (subop[4:0] == 5'h10) ? 2'd1 : 2'd0;
            bus_addr <= op2;
            bus_wdata <= {16'b0, dec_res};
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            st <= S_NEXT;
        end
    end

    // ------------------------------------------------------------------
    // BAM: bit addressing modes for the 0x5B/0x5D groups (MAME BAMTable1/2
    // implemented subset — everything MAME fatalerrors on traps here too).
    // Produces {bam_base (byte address), bam_off (bit offset)}.
    S_BAM_MODE: begin
        if (!ea_modm) begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // displacement IS the bit offset
                logic [31:0] bdt;
                bdt = disp_of(ea_ofs+1, modtop[1:0]);
                bam_base <= rf_rdata_a;
                bam_off  <= bdt;
                bam_fill_len(5'd1 + disp_len(modtop[1:0]));
                st <= bam_next();
            end
            3'd3: begin             // register indirect
                bam_base <= rf_rdata_a;
                bam_off  <= 32'd0;
                bam_fill_len(5'd1);
                st <= bam_next();
            end
            3'd4, 3'd5, 3'd6: begin // [reg + disp] deref -> base, off 0
                logic [31:0] bdt;
                bdt = disp_of(ea_ofs+1, modtop - 3'd4);
                bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                bus_addr <= rf_rdata_a + bdt;
                bam_off <= 32'd0;
                bam_fill_len(5'd1 + disp_len(modtop - 3'd4));
                st <= S_BAM_IND;
            end
            default: begin          // group 7: direct forms only
                case (modreg)
                5'h13: begin
                    logic [31:0] bdt;
                    bdt = fb32(ea_ofs+1);
                    bam_base <= bdt;
                    bam_off  <= 32'd0;
                    bam_fill_len(5'd5);
                    st <= bam_next();
                end
                5'h17: begin        // direct address deferred
                    logic [31:0] bdt;
                    bdt = fb32(ea_ofs+1);
                    bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                    bus_addr <= bdt;
                    bam_off <= 32'd0;
                    bam_fill_len(5'd5);
                    st <= S_BAM_IND;
                end
                default: begin
                    exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                end
                endcase
            end
            endcase
        end
        else begin
            case (modtop)
            3'd0, 3'd1, 3'd2: begin // double displacement: deref d1, off = d2
                logic [31:0] bdt, bdt2;
                bdt  = disp_of(ea_ofs+1, modtop[1:0]);
                bdt2 = disp_of(ea_ofs+1+disp_len(modtop[1:0]), modtop[1:0]);
                bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                bus_addr <= rf_rdata_a + bdt;
                bam_off  <= bdt2;
                bam_fill_len(5'd1 + {disp_len(modtop[1:0]), 1'b0});
                st <= S_BAM_IND;
            end
            3'd4: begin             // autoincrement (+1 strings, +4 fields)
                bam_base <= rf_rdata_a;
                bam_off  <= 32'd0;
                queue_reg_write(
                    modreg,
                    rf_rdata_a + ((cur_op == 8'h5b) ? 32'd1 : 32'd4),
                    32'hffff_ffff
                );
                bam_fill_len(5'd1);
                st <= bam_next();
            end
            3'd5: begin             // autodecrement
                bam_base <= rf_rdata_a - ((cur_op == 8'h5b) ? 32'd1 : 32'd4);
                queue_reg_write(
                    modreg,
                    rf_rdata_a - ((cur_op == 8'h5b) ? 32'd1 : 32'd4),
                    32'hffff_ffff
                );
                bam_off  <= 32'd0;
                bam_fill_len(5'd1);
                st <= bam_next();
            end
            3'd6: begin             // group 6: register indirect indexed only
                if (modval2[7:5] == 3'd3) begin
                    bam_base <= rf_rdata_b;
                    bam_off  <= rf_rdata_a;
                    bam_fill_len(5'd2);
                    st <= bam_next();
                end
                else begin
                    exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
                end
            end
            default: begin
                exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
            end
            endcase
        end
    end
    S_BAM_IND: if (bus_ack) begin
        bus_req <= 0;
        bam_base <= bus_rdata;
        st <= bam_next();
    end
    // bit-field VALUE form (BAM1): dword at base + off/8, fold off to &7
    S_BAM_VAL: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
            bus_addr <= bam_base + bitdiv8(bam_off);
        end
        else if (bus_ack) begin
            bus_req <= 0;
            bit_val <= bus_rdata;
            bam_off <= {29'b0, bam_off[2:0]};
            st <= S_BF_EXT1;
        end
    end

    // ------------------------------------------------------------------
    // EXTBFS/EXTBFZ/EXTBFL: field extracted from bit_val; ext len byte,
    // then op2 (normal AM) receives the word result
    S_BF_EXT1: begin
        logic [7:0] lb;
        lb = fb[5'd2 + len1];
        bit_len <= lb[7] ? rf_rdata_a : {24'b0, lb};
        ea_want_addr <= 1'b1;
        ea_dim  <= 2'd2;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd3 + len1;
        ea_target2 <= 1'b1;
        ea_ret  <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_BF_EXTW;
    end
    S_BF_EXTW: begin
        logic [31:0] mask, v, res;
        mask = (32'h1 << bit_len[4:0]) - 32'h1;
        v = (bit_val >> bam_off[2:0]) & mask;
        if (bam_flow == 2'd2) res = bit_val;             // SCHBS result
        else case (subop[4:0])
            5'h08: res = (v & ((mask + 32'h1) >> 1)) ? (v | ~mask) : v; // S
            5'h09: res = v;                                             // Z
            default: res = v << (6'd32 - {1'b0, bit_len[4:0]});         // L
        endcase
        if (flag2) begin
            queue_reg_write(op2[4:0], res, 32'hffff_ffff);
            total_len <= 5'd3 + len1 + len2;
            st <= S_NEXT;
        end
        else if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= op2; bus_wdata <= res;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            total_len <= 5'd3 + len1 + len2;
            st <= S_NEXT;
        end
    end

    // ------------------------------------------------------------------
    // INSBFR/INSBFL: op1 word value decoded; op2 = BAM address; ext len;
    // RMW the 32-bit field at the bit position
    S_BF_INS1: begin
        bam_second <= 1'b1;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd2 + len1;
        st <= S_BAM_MODE;
    end
    S_BF_INS2: begin
        logic [7:0] lb;
        lb = fb[5'd2 + len1 + len2];
        bit_len <= lb[7] ? rf_rdata_a : {24'b0, lb};
        str_dst <= bam_base + bitdiv8(bam_off);
        bam_off <= {29'b0, bam_off[2:0]};
        total_len <= 5'd3 + len1 + len2;
        st <= S_BF_INSRD;
    end
    S_BF_INSRD: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
            bus_addr <= str_dst;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            bit_val <= bus_rdata;
            st <= S_BF_INSWR;
        end
    end
    S_BF_INSWR: begin
        logic [31:0] mask, v, neww;
        mask = (32'h1 << bit_len[4:0]) - 32'h1;
        v = subop[0] ? (op1 >> (6'd32 - {1'b0, bit_len[4:0]})) : op1;  // L pre-shifts
        neww = (bit_val & ~(mask << bam_off[2:0]))
             | ((v & mask) << bam_off[2:0]);
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= str_dst; bus_wdata <= neww;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            st <= S_NEXT;
        end
    end

    // ------------------------------------------------------------------
    // SCH0BSU/SCH1BSU: scan bit string for first 0/1
    S_BS_SCH1: begin
        logic [7:0] lb;
        logic [31:0] l;
        lb = fb[5'd2 + len1];
        l = lb[7] ? rf_rdata_a : {24'b0, lb};
        bit_len <= l;
        str_src <= bam_base + bitdiv8(bam_off);
        bs_soff <= bam_off[2:0];
        str_cnt <= 0;
        if (l == 0) begin
            f_z <= 1'b1;
            bit_val <= 0;
            st <= S_BS_SCHW;
        end
        else st <= S_BS_SCHRD;
    end
    S_BS_SCHRD: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd0;
            bus_addr <= str_src;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            bs_sdata <= bus_rdata[7:0];
            st <= S_BS_SCHB;
        end
    end
    S_BS_SCHB: begin
        queue_reg_write(5'd28, str_src, 32'hffff_ffff);
        if (bs_sdata[bs_soff] == subop[1]) begin   // sub 0 finds 0, sub 2 finds 1
            f_z <= 1'b0;
            bit_val <= str_cnt;
            st <= S_BS_SCHW;
        end
        else if (str_cnt + 1 == bit_len) begin     // exhausted
            f_z <= 1'b1;
            bit_val <= bit_len;
            st <= S_BS_SCHW;
        end
        else begin
            str_cnt <= str_cnt + 1;
            if (bs_soff == 3'd7) begin
                bs_soff <= 3'd0;
                str_src <= str_src + 1;
                st <= S_BS_SCHRD;
            end
            else bs_soff <= bs_soff + 1'd1;
        end
    end
    S_BS_SCHW: begin
        // result goes to op2 via the shared writer
        ea_want_addr <= 1'b1;
        ea_dim  <= 2'd2;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd3 + len1;
        ea_target2 <= 1'b1;
        ea_ret  <= 3'd0;
        st <= S_EA_MODE;
        st_after_ea <= S_BF_EXTW;   // bam_flow==2 writes bit_val
    end

    // ------------------------------------------------------------------
    // MOVBSU/MOVBSD: bit-string copy (subop bit0: 0=up, 1=down)
    S_BS_MOV1: begin
        logic [7:0] lb;
        lb = fb[5'd2 + len1];
        bit_len <= lb[7] ? rf_rdata_a : {24'b0, lb};
        bs_base1 <= bam_base;
        bs_off1  <= bam_off;
        bam_second <= 1'b1;
        ea_modm <= subop[5];
        ea_ofs  <= 5'd3 + len1;
        st <= S_BAM_MODE;
    end
    S_BS_MOV2: begin
        // resolve byte addresses / bit positions (down: offsets += len-1)
        logic [31:0] o1, o2;
        o1 = subop[0] ? bs_off1 + bit_len - 1 : bs_off1;
        o2 = subop[0] ? bam_off + bit_len - 1 : bam_off;
        str_src <= bs_base1 + bitdiv8(o1);
        str_dst <= bam_base + bitdiv8(o2);
        bs_soff <= o1[2:0];
        bs_doff <= o2[2:0];
        total_len <= 5'd3 + len1 + len2;
        bs_ph <= 2'd0;
        bs_adv_done <= 1'b0;
        if (bit_len == 0) st <= S_NEXT;
        else st <= S_BS_MOVS;
    end
    // source-byte load. bs_ph: 0 = initial (no advance; dst load follows),
    // 2 = mid-loop src reload (advance first; back to the bit loop),
    // 1 = src+dst reload after a dst flush (advance; dst load follows)
    S_BS_MOVS: begin
        if (bs_ph != 2'd0 && !bs_adv_done) begin
            str_src <= subop[0] ? str_src - 1 : str_src + 1;
            bs_soff <= subop[0] ? 3'd7 : 3'd0;
            bs_adv_done <= 1'b1;
        end
        else if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd0;
            bus_addr <= str_src;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            bs_sdata <= bus_rdata[7:0];
            bs_adv_done <= 1'b0;
            if (bs_ph == 2'd2) begin bs_ph <= 2'd0; st <= S_BS_MOVB; end
            else begin bs_ph <= 2'd0; st <= S_BS_MOVD; end
        end
    end
    S_BS_MOVD: begin
        // load destination byte (RMW base)
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd0;
            bus_addr <= str_dst;
        end
        else if (bus_ack) begin
            bus_req <= 0;
            bs_ddata <= bus_rdata[7:0];
            st <= S_BS_MOVB;
        end
    end
    S_BS_MOVB: begin
        // copy one bit, then handle byte boundaries per direction
        logic [7:0] nd;
        logic wrap_s, wrap_d;
        nd = bs_ddata;
        nd[bs_doff] = bs_sdata[bs_soff];
        bs_ddata <= nd;
        queue_reg_write(5'd28, str_src, 32'hffff_ffff);
        queue_reg_write(5'd27, str_dst, 32'hffff_ffff);
        wrap_s = subop[0] ? (bs_soff == 3'd0) : (bs_soff == 3'd7);
        wrap_d = subop[0] ? (bs_doff == 3'd0) : (bs_doff == 3'd7);
        bit_len <= bit_len - 1;
        if (!wrap_s) bs_soff <= subop[0] ? bs_soff - 1'd1 : bs_soff + 1'd1;
        if (!wrap_d) bs_doff <= subop[0] ? bs_doff - 1'd1 : bs_doff + 1'd1;
        if (wrap_d) begin
            bs_ph <= wrap_s ? 2'd1 : 2'd0;   // remember pending src reload
            st <= S_BS_MOVF;                 // write out dst byte
        end
        else if (wrap_s) begin
            if (bit_len == 1) st <= S_BS_MOVF;  // done: flush partial dst byte
            else begin bs_ph <= 2'd2; st <= S_BS_MOVS; end
        end
        else if (bit_len == 1) st <= S_BS_MOVF;  // final partial flush
        else st <= S_BS_MOVB;
        // final-bit bookkeeping: when the last copied bit did NOT wrap the
        // dst byte, S_BS_MOVF performs the flush write and ends; when it
        // wrapped, S_BS_MOVF writes and (bit_len==1) ends without reload
    end
    S_BS_MOVF: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd0;
            bus_addr <= str_dst;
            bus_wdata <= {24'b0, bs_ddata};
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            if (bit_len == 0) st <= S_NEXT;          // string done
            else begin
                // advance dst to the next byte and reload it (src too when
                // its boundary coincided — bs_ph 1 routes through MOVS)
                str_dst <= subop[0] ? str_dst - 1 : str_dst + 1;
                bs_doff <= subop[0] ? 3'd7 : 3'd0;
                if (bs_ph == 2'd1) st <= S_BS_MOVS;
                else               st <= S_BS_MOVD;
            end
        end
    end

    S_STR_NEXT: begin
        logic [31:0] stp;
        stp = cur_op[1] ? 32'd2 : 32'd1;
        // down variants (MOVCD*) decrement; up variants increment
        if (subop[0] && (subop[4:0]>=5'h08)) begin
            str_src <= str_src - stp; str_dst <= str_dst - stp;
        end
        else begin
            str_src <= str_src + stp; str_dst <= str_dst + stp;
        end
        str_cnt <= str_cnt - 1;
        if (str_cnt == 1) begin
            queue_reg_write(5'd28, str_src, 32'hffff_ffff);
            queue_reg_write(5'd27, str_dst, 32'hffff_ffff);
            st <= S_NEXT;
        end
        else st <= S_STR_RD;
    end

    // ------------------------------------------------------------------
    // LDTASK/STTASK task-block transfers. Phase 0 is TKCW, phases 1..4
    // are enabled L0SP..L3SP fields, and phases 5..35 are R0..R30.
    S_TASK_LD_NEXT: begin
        if (task_phase == 0) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
            bus_addr <= task_addr;
            st <= S_TASK_LD_ACK;
        end
        else if (task_phase <= 4) begin
            if (sycw[7 + task_phase]) begin
                bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                bus_addr <= task_addr;
                st <= S_TASK_LD_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else if (task_phase == 5 && !task_reloaded) begin
            // Stack fields loaded on prior cycles are now stable.
            queue_reg_write(5'd31, pick_stack(psw), 32'hffff_ffff);
            task_reloaded <= 1'b1;
        end
        else if (task_phase <= 35) begin
            if (task_mask[task_phase - 5]) begin
                bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
                bus_addr <= task_addr;
                st <= S_TASK_LD_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else st <= S_NEXT;
    end
    S_TASK_LD_ACK: if (bus_ack) begin
        bus_req <= 0;
        case (task_phase)
            0: tkcw <= bus_rdata;
            1: l0sp <= bus_rdata;
            2: l1sp <= bus_rdata;
            3: l2sp <= bus_rdata;
            4: l3sp <= bus_rdata;
            default: queue_reg_write(task_phase - 5, bus_rdata, 32'hffff_ffff);
        endcase
        task_addr <= task_addr + 4;
        task_phase <= task_phase + 1'd1;
        st <= S_TASK_LD_NEXT;
    end

    S_TASK_ST_NEXT: begin
        if (task_phase == 0) begin
            // v60SaveStack() after setting IS: r31 now names the interrupt
            // stack selected by write_psw() in the execute cycle.
            isp <= r[31];
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= task_addr; bus_wdata <= tkcw;
            st <= S_TASK_ST_ACK;
        end
        else if (task_phase <= 4) begin
            if (sycw[7 + task_phase]) begin
                bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
                bus_addr <= task_addr;
                case (task_phase)
                    1: bus_wdata <= l0sp; 2: bus_wdata <= l1sp;
                    3: bus_wdata <= l2sp; default: bus_wdata <= l3sp;
                endcase
                st <= S_TASK_ST_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else if (task_phase <= 35) begin
            if (task_mask[task_phase - 5]) begin
                bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
                bus_addr <= task_addr; bus_wdata <= rf_rdata_a;
                st <= S_TASK_ST_ACK;
            end
            else task_phase <= task_phase + 1'd1;
        end
        else st <= S_NEXT;
    end
    S_TASK_ST_ACK: if (bus_ack) begin
        bus_req <= 0; bus_we <= 0;
        task_addr <= task_addr + 4;
        task_phase <= task_phase + 1'd1;
        st <= S_TASK_ST_NEXT;
    end

    // ------------------------------------------------------------------
    // exception / interrupt entry (MAME v60_do_irq):
    //   switch to interrupt context, push old PSW, push PC, PC = vector
    S_EXC_PUSH1: begin
        // Synchronous exceptions preserve IS; IRQ/NMI force the interrupt
        // stack. CHLVL supplies a nonzero target execution level.
        logic [31:0] newpsw;
        newpsw = exc_pushval;
        newpsw[25:24] = exc_target_level;
        newpsw[18] = 0; newpsw[16] = 0; newpsw[27] = 0; newpsw[17] = 0; newpsw[29] = 0;
        if (exc_is_interrupt) newpsw[28] = 1;
        newpsw[31] = 1;
        write_psw(newpsw);
        // BRKV has a leading fault-PC word; ordinary trap-class frames begin
        // with code+size, while IRQ/NMI frames begin with old PSW.
        st <= exc_has_extra ? S_EXC_EXTRA
                            : exc_has_code ? S_EXC_CODE : S_EXC_PUSH2;
    end
    S_EXC_EXTRA: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= r[31] - 4;
            bus_wdata <= exc_extra;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_CODE;
        end
    end
    S_EXC_CODE: begin         // push code+size word (trap-class only)
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= r[31] - 4;
            bus_wdata <= exc_code;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_PUSH2;
        end
    end
    S_EXC_PUSH2: begin        // push old PSW
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= r[31] - 4;
            bus_wdata <= exc_pushval;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_JMP;   // reused as "push PC" state
        end
    end
    S_EXC_JMP: begin          // push return PC (A2: PC+len for TRAP)
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
            bus_addr <= r[31] - 4;
            bus_wdata <= exc_retpc;
        end
        else if (bus_ack) begin
            bus_req <= 0; bus_we <= 0;
            queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
            st <= S_EXC_VEC;
        end
    end
    S_EXC_VEC: begin
        if (!bus_req) begin
            bus_req <= 1; bus_we <= 0; bus_size <= 2'd2;
            bus_addr <= (sbr & ~32'hfff) + {22'b0, exc_vector, 2'b00};
        end
        else if (bus_ack) begin
            bus_req <= 0;
            pc <= bus_rdata;
            st <= S_FILL; st_after_fill <= S_DECODE;
        end
    end

    // PUSH/POP bus completion
    S_PUSH: if (bus_ack) begin
        bus_req <= 0; bus_we <= 0;
        st <= S_NEXT;
    end
    S_POP: if (bus_ack) begin
        bus_req <= 0;
        if (flag1) begin
            queue_reg_write(op1[4:0], bus_rdata, 32'hffff_ffff);
            st <= S_NEXT;
        end
        else begin
            op2 <= op1; flag2 <= 0;
            wb_val <= bus_rdata;
            st <= S_WB_MEM;
        end
        queue_reg_write(5'd31, r[31] + 4, 32'hffff_ffff);
    end

    S_HALT: begin
        // wake on interrupt
        if (nmi_seen || (!irq_n && psw_ie)) begin
            halted <= 0;
            st <= S_DECODE;
        end
    end

    default: st <= S_RESET;
    endcase

    // Port 1 is applied second so the final queued write retains the original
    // nonblocking-assignment priority when both ports address the same bit.
    for (int rf_wbit = 0; rf_wbit < 32; rf_wbit = rf_wbit + 1) begin
        if (rf_we0 && rf_wmask0[rf_wbit])
            r[rf_waddr0][rf_wbit] <= rf_wdata0[rf_wbit];
        if (rf_we1 && rf_wmask1[rf_wbit])
            r[rf_waddr1][rf_wbit] <= rf_wdata1[rf_wbit];
    end
end
end

// ---------------------------------------------------------------------------
// per-opcode dim helpers (operand sizes per MAME op12 handlers)
// ---------------------------------------------------------------------------
// F12 ops whose FIRST operand is an effective address, not a value
// (MAME F12DecodeFirstOperand(ReadAMAddress, ...)): MOVEA and IN
function automatic f12_op1_is_addr(input [7:0] op);
    case (op)
        8'h40, 8'h42, 8'h44,            // MOVEA.B/H/W
        8'h20, 8'h22, 8'h24,            // IN.B/H/W
        8'h49,                         // CALL target
        8'h01: f12_op1_is_addr = 1'b1; // LDTASK register-mask operand
        default: f12_op1_is_addr = 1'b0;
    endcase
endfunction

function automatic [1:0] f12_dim1(input [7:0] op);
    casez (op)
        8'h09, 8'h0a, 8'h0b, 8'h0c, 8'h0d, 8'h40, 8'h41, 8'h20, 8'h21,
        8'h38, 8'h39, 8'h50, 8'h51, 8'h80, 8'h81, 8'h88,
        8'h90, 8'h91, 8'h98, 8'ha0, 8'ha1, 8'ha8, 8'hb0, 8'hb1,
        8'hb8, 8'h49, 8'h4b, 8'h4d, 8'h4e, 8'h4f:
            f12_dim1 = 2'd0;   // CALL address and CHLVL/CHKA byte operands
        // NOTE: ROTH (8b) / ROTCH (9b) must NOT appear here — their op1 is
        // the rotate COUNT, a byte (MAME ReadAM dim 0); listing them in the
        // half group made `ROT.H #imm8, r6` decode one byte long and holo's
        // EEPROM write loop entered mid-instruction (found by real-ROM boot)
        8'h19, 8'h1b, 8'h1c, 8'h1d, 8'h42, 8'h43, 8'h3a, 8'h3b, 8'h22, 8'h23,
        8'h52, 8'h53, 8'h82, 8'h83, 8'h8a, 8'h92, 8'h93,
        8'h9a, 8'ha2, 8'ha3, 8'haa, 8'hb2, 8'hb3, 8'hba:
            f12_dim1 = 2'd1;
        // A7: MULX/MULUX/DIVX/DIVUX first operand is word (64-bit datapath)
        8'h86, 8'h96, 8'ha6, 8'hb6: f12_dim1 = 2'd2;
        8'ha9, 8'hab, 8'had, 8'hb9, 8'hbb, 8'hbd, 8'h89, 8'h8b, 8'h8d,
        8'h99, 8'h9b, 8'h9d: f12_dim1 = 2'd0;  // shift/rot counts are byte
        default: f12_dim1 = 2'd2;
    endcase
endfunction
function automatic [1:0] f12_dim2(input [7:0] op);
    casez (op)
        8'h09, 8'h19, 8'h29, 8'h38, 8'h39, 8'h41, 8'h50, 8'h51,
        8'h80, 8'h81, 8'h88, 8'h90, 8'h91, 8'h98, 8'ha0, 8'ha1,
        8'ha8, 8'hb0, 8'hb1, 8'hb8, 8'h89, 8'h99, 8'ha9, 8'hb9,
        8'h4b, 8'h4d, 8'h4e, 8'h4f: f12_dim2 = 2'd0;
        8'h0a, 8'h0b, 8'h1b, 8'h2b, 8'h3a, 8'h3b, 8'h43, 8'h52, 8'h53,
        8'h82, 8'h83, 8'h8a, 8'h92, 8'h93, 8'h9a, 8'ha2, 8'ha3, 8'haa,
        8'hb2, 8'hb3, 8'hba, 8'h8b, 8'h9b, 8'hab, 8'hbb: f12_dim2 = 2'd1;
        default: f12_dim2 = 2'd2;
    endcase
endfunction

// RMW-class F12 ops: exec reads current op2 (dest) value
function automatic f12_reads_dest(input [7:0] op);
    casez (op)
        8'h8?, 8'h9?, 8'hA?, 8'hB?,          // ADD/MUL/OR/ROT/ADDC/SUBC/AND/DIV/SUB/SHL/XOR/CMP/SHA + bit ops
        8'h5?: f12_reads_dest = 1;           // REM group
        default: f12_reads_dest = 0;
    endcase
endfunction

// ---------------------------------------------------------------------------
// EXEC task: implements per-opcode semantics
// ---------------------------------------------------------------------------
task automatic set_zs(input [31:0] v, input [1:0] d);
    f_z <= zer(v, d);
    f_s <= sgn(v, d);
endtask

task automatic wb_op2(input [31:0] v, input [1:0] d);
    // write result to op2 (register or memory)
    if (flag2) begin
        setreg(op2[4:0], v, d);
    end
    else begin
        wb_val <= v;
        st <= S_WB_MEM;
    end
endtask

// BAM decode plumbing: record the AM length into len1/len2, and route to
// the flow's next state after the base/offset are resolved
task bam_fill_len(input [4:0] l);
    if (bam_second) len2 <= l; else len1 <= l;
endtask

function automatic st_t bam_next();
    // Quartus 17's Verific front-end crashes on a case statement inside an
    // enum-returning function used directly by a nonblocking assignment.
    // The equivalent if/else form avoids that compiler bug.
    if (!bam_second) begin
        if (bam_flow == 2'd0)      bam_next = S_BAM_VAL;   // EXTBF*: read dword
        else if (bam_flow == 2'd2) bam_next = S_BS_SCH1;   // SCHBS address form
        else                       bam_next = S_BS_MOV1;   // MOVBS op1
    end
    else if (bam_flow == 2'd1) bam_next = S_BF_INS2;
    else                       bam_next = S_BS_MOV2;
endfunction

task automatic exec_op;
    logic [31:0] a, b, res;
    logic [32:0] wide;
    logic [1:0]  d2;
    d2 = f12_dim2(cur_op);
    a = op1;                       // source (value)
    b = flag2 ? dimext(rf_rdata_b, d2) : op2val; // dest current value (V60-1)
    // Every consuming opcode assigns these before use.  Defaults make that
    // fact explicit to synthesis and prevent task-local latch inference.
    res  = 32'b0;
    wide = 33'b0;

    case (cur_op)
    // ------------ moves ------------
    8'h09, 8'h1b, 8'h2d: begin      // MOVB/MOVH/MOVW
        set_zs(a, d2);              // MAME MOV sets no flags? (MOV doesn't set flags on V60) -- MOV sets none; revert
        f_z <= f_z; f_s <= f_s;     // undo: MOV does not affect flags
        wb_op2(a, d2);
    end
    8'h0a: wb_op2({{24{a[7]}},  a[7:0]} & 32'hffff, 2'd1);   // MOVSBH
    8'h0b: wb_op2({24'b0, a[7:0]}, 2'd1);                    // MOVZBH
    8'h0c: wb_op2({{24{a[7]}},  a[7:0]}, 2'd2);              // MOVSBW
    8'h0d: wb_op2({24'b0, a[7:0]}, 2'd2);                    // MOVZBW
    8'h1c: wb_op2({{16{a[15]}}, a[15:0]}, 2'd2);             // MOVSHW
    8'h1d: wb_op2({16'b0, a[15:0]}, 2'd2);                   // MOVZHW
    8'h19: wb_op2(a[7:0], 2'd0);                             // MOVTHB (truncate H->B)
    8'h29: wb_op2(a[7:0], 2'd0);                             // MOVTWB
    8'h2b: wb_op2(a[15:0], 2'd1);                            // MOVTWH
    8'h40, 8'h42, 8'h44: wb_op2(op1, 2'd2);                  // MOVEA: op1 decoded as addr in IF2? see note
    8'h2c: begin                                             // RVBYT: reverse bytes
        wb_op2({a[7:0], a[15:8], a[23:16], a[31:24]}, 2'd2);
    end
    8'h08: begin                                             // RVBIT
        logic [7:0] rv;
        for (int i=0;i<8;i++) rv[i] = a[7-i];
        wb_op2({24'b0, rv}, 2'd0);
    end
    8'h3f: wb_op2(a, 2'd2);                                  // MOVD (simplified 32-bit)

    // ------------ arith ------------
    8'h80, 8'h82, 8'h84: begin      // ADD
        wide = {1'b0, dimext(b,d2)} + {1'b0, dimext(a,d2)};
        res = wide[31:0];
        f_cy <= (d2==2'd0) ? (({1'b0,b[7:0]}+{1'b0,a[7:0]}) >> 8) != 0 :
                (d2==2'd1) ? (({1'b0,b[15:0]}+{1'b0,a[15:0]}) >> 16) != 0 :
                wide[32];
        f_ov <= (d2==2'd0) ? (~(b[7]^a[7]) & (b[7]^res[7])) :
                (d2==2'd1) ? (~(b[15]^a[15]) & (b[15]^res[15])) :
                             (~(b[31]^a[31]) & (b[31]^res[31]));
        set_zs(res, d2);
        wb_op2(res, d2);
    end
    8'h90, 8'h92, 8'h94: begin      // ADDC
        wide = {1'b0, dimext(b,d2)} + {1'b0, dimext(a,d2)} + {32'b0, f_cy};
        res = wide[31:0];
        f_cy <= (d2==2'd2) ? wide[32] :
                (d2==2'd1) ? res[16] : res[8];
        f_ov <= (d2==2'd0) ? (~(b[7]^a[7]) & (b[7]^res[7])) :
                (d2==2'd1) ? (~(b[15]^a[15]) & (b[15]^res[15])) :
                             (~(b[31]^a[31]) & (b[31]^res[31]));
        set_zs(res, d2);
        wb_op2(res, d2);
    end
    8'ha8, 8'haa, 8'hac,            // SUB
    8'hb8, 8'hba, 8'hbc: begin      // CMP (no writeback)
        res = dimext(b,d2) - dimext(a,d2);
        f_cy <= (dimext(b,d2) < dimext(a,d2));
        f_ov <= (d2==2'd0) ? ((b[7]^a[7]) & (b[7]^res[7])) :
                (d2==2'd1) ? ((b[15]^a[15]) & (b[15]^res[15])) :
                             ((b[31]^a[31]) & (b[31]^res[31]));
        set_zs(res, d2);
        if (cur_op[4]) begin
            // CMP: 0xb8/ba/bc -> no store
            st <= S_NEXT;
        end
        else wb_op2(res, d2);
    end
    8'h98, 8'h9a, 8'h9c: begin      // SUBC
        res = dimext(b,d2) - dimext(a,d2) - {31'b0, f_cy};
        f_cy <= (dimext(b,d2) < (dimext(a,d2) + {31'b0,f_cy}));
        f_ov <= ((b[31]^a[31]) & (b[31]^res[31]));
        set_zs(res, d2);
        wb_op2(res, d2);
    end
    8'h38, 8'h3a, 8'h3c: begin      // NOT
        res = ~dimext(a,d2);
        set_zs(res, d2); f_ov <= 0; f_cy <= 0;
        wb_op2(res, d2);
    end
    8'h39, 8'h3b, 8'h3d: begin      // NEG
        res = 32'd0 - dimext(a,d2);
        f_cy <= (dimext(a,d2) != 0);
        f_ov <= sgn(a,d2) & sgn(res,d2);
        set_zs(res, d2);
        wb_op2(res, d2);
    end
    8'ha0, 8'ha2, 8'ha4: begin res = b & a; set_zs(res,d2); f_ov<=0; wb_op2(res,d2); end // AND
    8'h88, 8'h8a, 8'h8c: begin res = b | a; set_zs(res,d2); f_ov<=0; wb_op2(res,d2); end // OR
    8'hb0, 8'hb2, 8'hb4: begin res = b ^ a; set_zs(res,d2); f_ov<=0; wb_op2(res,d2); end // XOR
    8'hf0, 8'hf1, 8'hf2, 8'hf3, 8'hf4, 8'hf5: begin
        // TEST single operand
        set_zs(op1, cur_op[2:1] == 2'b00 ? 2'd0 : cur_op[2:1]==2'b01 ? 2'd1 : 2'd2);
        f_ov <= 0; f_cy <= 0;
        total_len <= 5'd1 + len1;
        st <= S_NEXT;
    end

    // ------------ shifts/rotates: count in op1 (byte, signed) ------------
    8'ha9, 8'hab, 8'had: begin      // SHL: CY = last bit out, OV=0, Z/S set
        logic signed [7:0] cnt;
        cnt = a[7:0];
        res = shl_res(b, a[7:0], d2);
        if (cnt > 0)      f_cy <= shl_lastout(b, cnt, d2, 1'b1);
        else if (cnt < 0) f_cy <= shl_lastout(b, -cnt, d2, 1'b0);
        f_ov <= 0;
        set_zs(res, d2);
        wb_op2(res, d2);
    end
    8'hb9, 8'hbb, 8'hbd: begin      // SHA: CY last-out; OV=0 (arith)
        logic signed [7:0] cnt;
        cnt = a[7:0];
        res = sha_res(b, a[7:0], d2);
        if (cnt > 0)      f_cy <= shl_lastout(b, cnt, d2, 1'b1);
        else if (cnt < 0) f_cy <= shl_lastout(b, -cnt, d2, 1'b0);
        f_ov <= 0;
        set_zs(res, d2);
        wb_op2(res, d2);
    end
    8'h89, 8'h8b, 8'h8d: begin      // ROT: CY = bit rotated around
        logic signed [7:0] cnt;
        cnt = a[7:0];
        res = rot_res(b, a[7:0], d2);
        // MAME defines CY from the post-rotate wrap bit: LSB after a
        // positive (left) rotate, MSB after a negative (right) rotate.
        // A zero count explicitly clears CY.
        if (cnt > 0)      f_cy <= res[0];
        else if (cnt < 0) f_cy <= sgn(res, d2);
        else              f_cy <= 1'b0;
        f_ov <= 0;
        set_zs(res, d2);
        wb_op2(res, d2);
    end
    8'h99, 8'h9b, 8'h9d: begin      // ROTC: rotate through carry, iterative
        // MAME clears CY for a zero count; nonzero counts retain the final
        // shifted-out bit, so only bypass the iterative state for zero.
        if ($signed(a[7:0]) == 0) begin
            f_cy <= 1'b0;
            f_ov <= 1'b0;
            set_zs(b, d2);
            wb_op2(b, d2);
        end
        else begin
            rotc_cnt <= a[7:0];
            rotc_val <= dimext(b, d2);
            st <= S_ROTC;
        end
    end

    // ------------ bit ops (register or memory dest in op2) ------------
    8'h87, 8'h97, 8'ha7, 8'hb7: begin
        // TEST1/SET1/CLR1/NOT1: op1 = bit number, op2 = dest (RMW)
        // memory case handled as RMW via S_EA-provided address in op2
        if (flag2) begin
            logic [4:0] bi;
            bi = op1[4:0];
            f_z  <= ~rf_rdata_b[bi];
            f_cy <=  rf_rdata_b[bi];
            case (cur_op)
                8'h97: queue_reg_write(op2[4:0], 32'hffff_ffff, 32'h1 << bi);
                8'ha7: queue_reg_write(op2[4:0], 32'h0000_0000, 32'h1 << bi);
                8'hb7: queue_reg_write(op2[4:0], ~rf_rdata_b, 32'h1 << bi);
                default: ;
            endcase
            st <= S_NEXT;
        end
        else begin
            // memory bit op: byte RMW at addr + bit#/8, bit = bit# % 8
            op2 <= op2 + {29'b0, op1[4:3]};     // byte offset from bit number
            rmw_kind <= (cur_op == 8'h97) ? 3'd2 :   // SET1
                        (cur_op == 8'ha7) ? 3'd3 :   // CLR1
                        (cur_op == 8'hb7) ? 3'd4 :   // NOT1
                                            3'd5;    // TEST1
            rmw_dim  <= 2'd0;
            wb_val   <= {29'b0, op1[2:0]};      // bit within byte
            st <= S_RMW_RD;
        end
    end

    // ------------ multiply / divide (iterative) ------------
    8'h81, 8'h83, 8'h85, 8'h91, 8'h93, 8'h95: begin // MUL/MULU
        mdop <= dimext(a, d2);
        mdacc <= {32'b0, dimext(b, d2)};
        md_sign <= !cur_op[4] ? 1'b0 : 1'b0;
        mdcnt <= 6'd32;
        st <= S_MULDIV;
    end
    8'ha1, 8'ha3, 8'ha5, 8'hb1, 8'hb3, 8'hb5,       // DIV/DIVU
    8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55: begin // REM/REMU
        if (dimext(a, d2) == 0) begin
            // MAME: divide-by-zero leaves the destination unchanged, no trap
            st <= S_NEXT;
        end
        else begin
            // DIV/DIVU distinguished by bit4 (0xaX signed / 0xbX unsigned);
            // REM/REMU distinguished by bit0 (0x50/52/54 signed / 51/53/55 unsigned)
            logic is_signed, is_rem;
            logic [31:0] sa, sb, maga, magb;
            is_rem    = (cur_op[7:4] == 4'h5);
            is_signed = is_rem ? ~cur_op[0] : ~cur_op[4];
            // sign-extend operands to 32 bits per operand size
            sa = (d2==2'd0) ? {{24{a[7]}},a[7:0]} : (d2==2'd1) ? {{16{a[15]}},a[15:0]} : a;
            sb = (d2==2'd0) ? {{24{b[7]}},b[7:0]} : (d2==2'd1) ? {{16{b[15]}},b[15:0]} : b;
            maga = (is_signed && sa[31]) ? (~sa + 1'b1) : sa;
            magb = (is_signed && sb[31]) ? (~sb + 1'b1) : sb;
            mdop   <= maga;
            mdacc  <= {32'b0, magb};
            md_qsign <= is_signed & (sa[31] ^ sb[31]);
            md_rsign <= is_signed & sb[31];
            mdcnt  <= 6'd32;
            st <= S_MULDIV;
        end
    end
    8'h86, 8'h96: begin // MULX/MULUX: 32x32 -> 64 into reg pair (op2 = reg)
        logic [63:0] p;
        logic mul_signed;
        // Do not name this temporary "sgn": Quartus 17 treats block-local
        // declarations as task-wide and shadows the sgn() helper above.
        mul_signed = (cur_op == 8'h86);
        p = mul_signed ? $signed({{32{op1[31]}}, op1}) * $signed({{32{b[31]}}, b})
                       : {32'b0, op1} * {32'b0, b};
        if (flag2) begin
            queue_reg_write(op2[4:0], p[31:0], 32'hffff_ffff);
            queue_reg_write(op2[4:0] + 5'd1, p[63:32], 32'hffff_ffff);
        end
        f_z <= (p == 0); f_s <= p[63]; f_ov <= 0;
        st <= S_NEXT;
    end
    8'ha6, 8'hb6: begin // DIVX/DIVUX: (reg-pair 64) / op1 -> q in reg, r in reg+1
        if (op1 == 0) begin
            st <= S_NEXT;   // MAME: no zero-divide trap
        end
        else if (flag2) begin
            logic [63:0] num, mag_num;
            logic [31:0] mag_den;
            num = {rf_rdata_a, rf_rdata_b};
            if (cur_op == 8'ha6) begin
                mag_num = num[63] ? (~num + 1'b1) : num;
                mag_den = op1[31] ? (~op1 + 1'b1) : op1;
                xdiv_qneg <= num[63] ^ op1[31];
                xdiv_rneg <= num[63];
            end
            else begin
                mag_num = num;
                mag_den = op1;
                xdiv_qneg <= 1'b0;
                xdiv_rneg <= 1'b0;
            end
            xdiv_shift <= mag_num;
            xdiv_rem <= 0;
            xdiv_den <= mag_den;
            xdiv_cnt <= 0;
            xdiv_dst <= op2[4:0];
            xdiv_active <= 1'b1;
            st <= S_DIVX;
        end
        else st <= S_NEXT;
    end

    // ------------ XCH ------------
    8'h41, 8'h43, 8'h45: begin
        // both operands are addresses (simplified: register case only in exec;
        // memory-memory exchange via microstates TODO)
        if (flag1 && flag2) begin
            logic [31:0] t;
            t = rf_rdata_a;
            setreg(op1[4:0], rf_rdata_b, d2);
            setreg(op2[4:0], t, d2);
            st <= S_NEXT;
        end
        else begin
            // XCH with memory operand(s): read mem side, swap, write back.
            //   flag1: op1 is reg, op2 is addr (or vice versa); mem-mem uses
            //   xch_addr for the second location.
            if (flag1 ^ flag2) begin
                // one register, one memory
                xch_addr <= flag1 ? op2 : op1;      // memory address
                alu_r    <= flag1 ? rf_rdata_a : rf_rdata_b; // register value
                wb_val   <= {27'b0, flag1 ? op1[4:0] : op2[4:0]}; // reg number
                rmw_dim  <= d2;
                st <= S_XCH1;
            end
            else begin
                // mem-mem (rare): read op1, read op2, cross-write
                xch_addr <= op1;
                wb_val   <= op2;
                rmw_dim  <= d2;
                st <= S_XCH2;
            end
        end
    end

    // ------------ SETF: store condition truth ------------
    8'h47: wb_op2({31'b0, cond_true(op1[3:0])}, 2'd0);

    // ------------ CALL (0x49) — A6: push AP, AP=op2, push retPC, PC=op1 -----
    8'h49: begin
        // MAME opCALL: SP-=4; [SP]=AP; AP=op2; SP-=4; [SP]=retPC; PC=op1.
        bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
        bus_addr <= r[31] - 4;
        bus_wdata <= r[29];          // push AP (R29) first
        queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        queue_reg_write(5'd29, op2, 32'hffff_ffff); // AP (R29) = op2
        wb_val <= pc + 5'd2 + len1 + len2; // return PC, pushed in S_CALL1
        alu_r  <= op1;               // target
        st <= S_CALL1;
    end

    // ------------ PSW ops ------------
    8'h13, 8'h4a: begin   // UPDPSW: op1=value, op2=mask; width-limited
        logic [31:0] mask, val, lim;
        lim  = (cur_op == 8'h4a) ? 32'h0000_FFFF : 32'h00FF_FFFF;
        val  = op1 & lim;
        mask = (flag2 ? rf_rdata_b : op2val) & lim;
        write_psw((psw & ~mask) | (val & mask));
        st <= S_NEXT;
    end
    8'hf6, 8'hf7: begin   // GETPSW: WriteAM of PSW (reg or mem operand)
        total_len <= 5'd1 + len1;
        if (flag1) begin
            setreg(op1[4:0], psw, 2'd2);
            st <= S_NEXT;
        end
        else begin
            op2 <= op1; flag2 <= 0;
            rmw_kind <= 3'd6;   // width word via rmw_dim
            rmw_dim  <= 2'd2;
            wb_val <= psw;
            st <= S_WB_MEM;
        end
    end

    // ------------ TRAP: 3-word frame, vector 48+(n&0xF) (A2) ------------
    8'hf8, 8'hf9: begin
        // MAME opTRAP: vector = GETINTVECT(48 + (amout&0xF)); code+size word
        // = 0x3000 + 0x100*(amout&0xF); return PC = PC + amlength + 1.
        exc_vector   <= 8'd48 + {4'b0, op1[3:0]};
        // code = 0x3000 + 0x100*(n&0xF); word = (code<<16)|size(=4)
        exc_code     <= {4'h3, op1[3:0], 8'h00, 16'h0004};
        exc_pushval  <= psw;
        exc_retpc    <= pc + 5'd1 + len1;
        exc_has_code <= 1'b1;
        st <= S_EXC_PUSH1;
    end

    // ------------ short-format ops decoded via C_SHORT ------------
    8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5,   // DEC (RMW via addr in op1)
    8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd: begin // INC
        logic [1:0] d;
        logic inc;
        d = cur_op[2:1];
        inc = cur_op[3];
        if (flag1) begin
            res = dimext(rf_rdata_a, d) + (inc ? 32'd1 : 32'hffffffff);
            f_cy <= inc ? (dimext(rf_rdata_a,d)+1 >> (d==0?8:d==1?16:32)) != 0
                        : (dimext(rf_rdata_a,d) == 0);
            set_zs(res, d);
            setreg(op1[4:0], res, d);
            total_len <= 5'd1 + len1;
            st <= S_NEXT;
        end
        else begin
            // memory RMW (ga2 path): read at op1, inc/dec, write back
            op2 <= op1; flag2 <= 0;
            rmw_kind <= inc ? 3'd0 : 3'd1;
            rmw_dim  <= d;
            total_len <= 5'd1 + len1;
            st <= S_RMW_RD;
        end
    end
    8'hd6, 8'hd7: begin // JMP
        pc <= op1;
        st <= S_FILL; st_after_fill <= S_DECODE;
    end
    8'he8, 8'he9: begin // JSR
        bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
        bus_addr <= r[31] - 4;
        bus_wdata <= pc + 5'd1 + len1;
        queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        wb_val <= op1;
        st <= S_JSR1;
    end
    8'he2, 8'he3: begin // RET: adjustment in op1
        wb_val <= op1;
        bus_req <= 1; bus_we <= 0; bus_size <= 2'd2; bus_addr <= r[31];
        st <= S_RET1;
    end
    8'hea, 8'heb, 8'hfa, 8'hfb: begin // RETIU/RETIS
        xch_addr <= op1;   // frame-destroy adjustment (added to SP at the end)
        bus_req <= 1; bus_we <= 0; bus_size <= 2'd2; bus_addr <= r[31];
        st <= S_RETI1;
    end
    8'hee, 8'hef: begin // PUSH
        bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
        bus_addr <= r[31] - 4;
        bus_wdata <= op1;
        queue_reg_write(5'd31, r[31] - 4, 32'hffff_ffff);
        total_len <= 5'd1 + len1;
        st <= S_PUSH;
    end
    8'he6, 8'he7: begin // POP: op1 = dest addr/reg
        bus_req <= 1; bus_we <= 0; bus_size <= 2'd2; bus_addr <= r[31];
        total_len <= 5'd1 + len1;
        st <= S_POP;
    end
    8'hec, 8'hed: begin // PUSHM: op1 = mask
        total_len <= 5'd1 + len1;
        st <= S_PUSHM;
    end
    8'he4, 8'he5: begin // POPM
        total_len <= 5'd1 + len1;
        st <= S_POPM;
    end
    8'he0, 8'he1: begin // TASI
        total_len <= 5'd1 + len1;
        st <= S_TASI1;
    end
    8'hde, 8'hdf: begin // PREPARE: push FP (R30); FP=SP; SP -= imm
        bus_req <= 1; bus_we <= 1; bus_size <= 2'd2;
        bus_addr <= r[31] - 4;
        bus_wdata <= r[30];
        total_len <= 5'd1 + len1;
        st <= S_PREP1;
    end
    8'hfc, 8'hfd: begin // STTASK: save selected task state at TR
        task_mask <= op1;
        task_addr <= trr;
        task_phase <= 0;
        task_reloaded <= 0;
        total_len <= 5'd1 + len1;
        write_psw(psw | 32'h1000_0000);
        st <= S_TASK_ST_NEXT;
    end
    8'hfe, 8'hff: begin // CLRTLB: consume the complete AM operand; no MMU state
        total_len <= 5'd1 + len1;
        st <= S_NEXT;
    end

    // string groups (0x58/0x5A) now set up entirely in decode + S_STR_OP1/OP2
    // (A1); they never reach exec_op.

    // ------------ privileged moves ------------
    8'h01: begin // LDTASK: load selected task state from operand-2 pointer
        logic [31:0] task_pointer;
        task_pointer = flag2 ? rf_rdata_b : (op2val_v ? op2val : op2);
        task_mask <= flag1 ? rf_rdata_a : op1;
        task_addr <= task_pointer;
        task_phase <= 0;
        task_reloaded <= 0;
        trr <= task_pointer;
        write_psw(psw & ~32'h1000_0000);
        st <= S_TASK_LD_NEXT;
    end
    8'h02: begin // STPR: op1 = priv reg #, op2 = dest
        logic [31:0] v;
        case (op1[4:0])
            5'd0: v = isp;  5'd1: v = l0sp; 5'd2: v = l1sp;
            5'd3: v = l2sp; 5'd4: v = l3sp; 5'd5: v = sbr;
            5'd6: v = trr;  5'd7: v = sycw; 5'd8: v = tkcw;
            5'd9: v = pir;  5'd15: v = psw2;
            5'd16: v = atbr0; 5'd17: v = atlr0;
            5'd18: v = atbr1; 5'd19: v = atlr1;
            5'd20: v = atbr2; 5'd21: v = atlr2;
            5'd22: v = atbr3; 5'd23: v = atlr3;
            5'd24: v = trmode;
            5'd25: v = adtr0; 5'd26: v = adtr1;
            5'd27: v = adtmr0; 5'd28: v = adtmr1;
            default: v = 0;
        endcase
        if (op1 <= 32'd28) wb_op2(v, 2'd2);
        else begin
            exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
        end
    end
    8'h12: begin // LDPR: op1 = value, op2 = priv reg #
        case (op2[4:0])
            5'd0: isp <= op1;  5'd1: l0sp <= op1; 5'd2: l1sp <= op1;
            5'd3: l2sp <= op1; 5'd4: l3sp <= op1; 5'd5: sbr <= op1;
            5'd6: trr <= op1;  5'd7: sycw <= op1; 5'd8: tkcw <= op1;
            5'd9: pir <= op1;  5'd15: psw2 <= op1;
            5'd16: atbr0 <= op1; 5'd17: atlr0 <= op1;
            5'd18: atbr1 <= op1; 5'd19: atlr1 <= op1;
            5'd20: atbr2 <= op1; 5'd21: atlr2 <= op1;
            5'd22: atbr3 <= op1; 5'd23: atlr3 <= op1;
            5'd24: trmode <= op1;
            5'd25: adtr0 <= op1; 5'd26: adtr1 <= op1;
            5'd27: adtmr0 <= op1; 5'd28: adtmr1 <= op1;
            default: ;
        endcase
        if (op2 <= 32'd28) st <= S_NEXT;
        else begin
            exc_vector <= 8'd8; exc_pushval <= psw; st <= S_EXC_PUSH1;
        end
    end
    8'h4b: begin // CHLVL: level-specific synchronous exception
        logic [31:0] chlvl_data;
        chlvl_data = flag2 ? rf_rdata_b : (op2val_v ? op2val : op2);
        if (op1 > 32'd3) begin
            exc_vector <= 8'd8;
            exc_pushval <= psw;
            st <= S_EXC_PUSH1;
        end
        else begin
            exc_vector <= 8'd24 + op1[1:0];
            exc_code <= {8'h18 + op1[1:0], 8'h00, 16'h0008};
            exc_extra <= chlvl_data;
            exc_pushval <= psw;
            exc_retpc <= pc + 5'd2 + len1 + len2;
            exc_has_code <= 1'b1;
            exc_has_extra <= 1'b1;
            exc_target_level <= op1[1:0];
            exc_is_interrupt <= 1'b0;
            st <= S_EXC_PUSH1;
        end
    end
    8'h4d, 8'h4e, 8'h4f: begin // CHKA*: no MMU -> return address valid
        f_z <= 1; f_cy <= 0; f_s <= 0; st <= S_NEXT;
    end
    8'h20, 8'h22, 8'h24: begin  // IN — read io (mapped to bus, io space unused on S32)
        wb_op2(32'hffffffff, cur_op[2:1]);
    end
    8'h21, 8'h23, 8'h25: begin  // OUT — ignore
        st <= S_NEXT;
    end

    default: begin
        // synthesis translate_off
        $display("V60: exec fallthrough op %02x at %08x", cur_op, pc);
        // synthesis translate_on
        st <= S_NEXT;
    end
    endcase
endtask

// ---------------------------------------------------------------------------
// shift helpers (flags: CY = last bit out, Z/S from result)
// ---------------------------------------------------------------------------
function automatic shl_lastout(input [31:0] v, input [7:0] n, input [1:0] d, input left);
    logic [31:0] x;
    int w;
    x = dimext(v, d);
    w = (d==2'd0) ? 8 : (d==2'd1) ? 16 : 32;
    if (n == 0) shl_lastout = 1'b0;
    else if (left)  shl_lastout = (n <= w) ? x[w - n] : 1'b0;
    else            shl_lastout = (n <= 32) ? x[n - 1] : 1'b0;
endfunction

function automatic [31:0] shl_res(input [31:0] v, input [7:0] cnt, input [1:0] d);
    logic signed [7:0] c;
    logic [31:0] x;
    c = cnt;
    x = dimext(v, d);
    if (c >= 0) x = x << c;
    else        x = x >> (-c);
    shl_res = x;
endfunction
function automatic [31:0] sha_res(input [31:0] v, input [7:0] cnt, input [1:0] d);
    logic signed [7:0] c;
    logic signed [31:0] x;
    c = cnt;
    x = (d==2'd0) ? {{24{v[7]}},v[7:0]} : (d==2'd1) ? {{16{v[15]}},v[15:0]} : v;
    if (c >= 0) x = x <<< c;
    else        x = x >>> (-c);
    sha_res = x;
endfunction
function automatic [31:0] rot_res(input [31:0] v, input [7:0] cnt, input [1:0] d);
    logic signed [7:0] c;
    logic [31:0] x;
    logic [7:0] mag;
    logic [5:0] sh, w;
    logic [31:0] mask;
    c = cnt;
    x = dimext(v, d);
    mag = c[7] ? (8'h00 - cnt) : cnt;
    case (d)
        2'd0: begin w = 6'd8;  sh = {3'b0, mag[2:0]}; mask = 32'h0000_00ff; end
        2'd1: begin w = 6'd16; sh = {2'b0, mag[3:0]}; mask = 32'h0000_ffff; end
        default: begin w = 6'd32; sh = {1'b0, mag[4:0]}; mask = 32'hffff_ffff; end
    endcase
    if (sh == 0)     rot_res = x & mask;
    else if (!c[7])  rot_res = ((x << sh) | (x >> (w - sh))) & mask;
    else             rot_res = ((x >> sh) | (x << (w - sh))) & mask;
endfunction
function automatic [31:0] rotc_res(input [31:0] v, input [7:0] cnt, input [1:0] d);
    rotc_res = rot_res(v, cnt, d); // TODO exact rotate-through-carry
endfunction

// ---------------------------------------------------------------------------
// multiply/divide iterative engine
// ---------------------------------------------------------------------------
task automatic md_step;
    if (cur_op[5] == 1'b0 && (cur_op == 8'h81 || cur_op == 8'h83 || cur_op == 8'h85 ||
        cur_op == 8'h91 || cur_op == 8'h93 || cur_op == 8'h95)) begin
        // multiply: shift-add
        if (mdacc[0]) mdacc[63:32] <= mdacc[63:32] + mdop;
        mdacc <= {1'b0, (mdacc[0] ? mdacc[63:32] + mdop : mdacc[63:32]), mdacc[31:1]};
    end
    else begin
        // divide: non-restoring-ish simple restoring step
        logic [63:0] sh;
        sh = {mdacc[62:0], 1'b0};
        if (sh[63:32] >= mdop) begin
            sh[63:32] = sh[63:32] - mdop;
            sh[0] = 1'b1;
        end
        mdacc <= sh;
    end
endtask
task automatic md_finish;
    logic [1:0] d2;
    d2 = f12_dim2(cur_op);
    case (cur_op)
    8'h81, 8'h83, 8'h85, 8'h91, 8'h93, 8'h95: begin
        set_zs(mdacc[31:0], d2);
        f_ov <= (mdacc[63:32] != 0);
        wb_op2(mdacc[31:0], d2);
    end
    8'ha1, 8'ha3, 8'ha5, 8'hb1, 8'hb3, 8'hb5: begin // DIV: quotient (signed applied)
        logic [31:0] q;
        q = md_qsign ? (~mdacc[31:0] + 1'b1) : mdacc[31:0];
        set_zs(q, d2);
        f_ov <= 0;
        wb_op2(q, d2);
    end
    8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55: begin // REM: remainder (sign of dividend)
        logic [31:0] rem;
        rem = md_rsign ? (~mdacc[63:32] + 1'b1) : mdacc[63:32];
        set_zs(rem, d2);
        wb_op2(rem, d2);
    end
    default: ;
    endcase
endtask

endmodule
