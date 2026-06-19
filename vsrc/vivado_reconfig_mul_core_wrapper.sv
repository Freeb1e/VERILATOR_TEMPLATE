// Vivado-friendly top wrapper with a narrow register-style interface.
//
// This module is intended for FPGA synthesis/resource evaluation. It keeps
// external IO small by storing one tile in internal registers, then launching
// the reconfigurable core with start/done handshaking.
//
// 32-bit register map:
//   0x00..0x07 : a_tile[row][col], index = row*4 + col, low F_W bits used
//   0x10..0x1f : Frodo S, index = row*4 + col
//                wr_data[3:0] = magnitude, wr_data[4] = sign
//   0x20..0x2f : Scloud+ S, index = row*4 + col, wr_data[1:0] used
//   0x30..0x3f : C accumulator/result, index = row*4 + col, low ACC_W bits used
//
// Readback uses the same addresses. C registers are overwritten with
// c_acc_out when the core asserts valid_out.
(* use_dsp = "no" *)
module vivado_reconfig_mul_core_wrapper #(
    parameter int F_W   = 16,
    parameter int S_W   = 12,
    parameter int ACC_W = 16
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    output logic        busy,
    output logic        done,

    input  logic        alg_mode,
    input  logic        op_mode,

    input  logic        wr_en,
    input  logic [7:0]  wr_addr,
    input  logic [31:0] wr_data,

    input  logic [7:0]  rd_addr,
    output logic [31:0] rd_data
);

    localparam logic STATE_IDLE = 1'b0;
    localparam logic STATE_BUSY = 1'b1;

    logic state;
    logic core_valid_in;
    logic core_valid_out;

    logic [F_W-1:0]   a_tile [0:1][0:3];
    logic [3:0]       frodo_s_mag [0:3][0:3];
    logic             frodo_s_sign [0:3][0:3];
    logic [1:0]       scloud_s [0:3][0:3];
    logic [ACC_W-1:0] c_acc_reg [0:3][0:3];
    logic [ACC_W-1:0] c_acc_out [0:3][0:3];

    function automatic logic [F_W-1:0] wr_data_f;
        input logic [31:0] data;
        begin
            wr_data_f = data[F_W-1:0];
        end
    endfunction

    function automatic logic [ACC_W-1:0] wr_data_acc;
        input logic [31:0] data;
        begin
            wr_data_acc = data[ACC_W-1:0];
        end
    endfunction

    function automatic logic [31:0] zext_f;
        input logic [F_W-1:0] data;
        begin
            zext_f = {{(32-F_W){1'b0}}, data};
        end
    endfunction

    function automatic logic [31:0] zext_acc;
        input logic [ACC_W-1:0] data;
        begin
            zext_acc = {{(32-ACC_W){1'b0}}, data};
        end
    endfunction

    reconfig_mul_core #(
        .F_W(F_W),
        .S_W(S_W),
        .ACC_W(ACC_W)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(core_valid_in),
        .alg_mode(alg_mode),
        .op_mode(op_mode),
        .a_tile(a_tile),
        .frodo_s_mag(frodo_s_mag),
        .frodo_s_sign(frodo_s_sign),
        .scloud_s(scloud_s),
        .c_acc_in(c_acc_reg),
        .valid_out(core_valid_out),
        .c_acc_out(c_acc_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        int r;
        int c;
        int idx;

        if (!rst_n) begin
            state         <= STATE_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            core_valid_in <= 1'b0;

            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    a_tile[r][c] <= '0;
                end
            end

            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    frodo_s_mag[r][c]  <= '0;
                    frodo_s_sign[r][c] <= 1'b0;
                    scloud_s[r][c]     <= 2'b00;
                    c_acc_reg[r][c]    <= '0;
                end
            end
        end else begin
            done          <= 1'b0;
            core_valid_in <= 1'b0;

            if (wr_en && !busy) begin
                if (wr_addr >= 8'h00 && wr_addr <= 8'h07) begin
                    idx = wr_addr - 8'h00;
                    a_tile[idx >> 2][idx[1:0]] <= wr_data_f(wr_data);
                end else if (wr_addr >= 8'h10 && wr_addr <= 8'h1f) begin
                    idx = wr_addr - 8'h10;
                    frodo_s_mag[idx >> 2][idx[1:0]]  <= wr_data[3:0];
                    frodo_s_sign[idx >> 2][idx[1:0]] <= wr_data[4];
                end else if (wr_addr >= 8'h20 && wr_addr <= 8'h2f) begin
                    idx = wr_addr - 8'h20;
                    scloud_s[idx >> 2][idx[1:0]] <= wr_data[1:0];
                end else if (wr_addr >= 8'h30 && wr_addr <= 8'h3f) begin
                    idx = wr_addr - 8'h30;
                    c_acc_reg[idx >> 2][idx[1:0]] <= wr_data_acc(wr_data);
                end
            end

            case (state)
                STATE_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        state         <= STATE_BUSY;
                        busy          <= 1'b1;
                        core_valid_in <= 1'b1;
                    end
                end

                default: begin
                    busy <= 1'b1;
                    if (core_valid_out) begin
                        for (r = 0; r < 4; r = r + 1) begin
                            for (c = 0; c < 4; c = c + 1) begin
                                c_acc_reg[r][c] <= c_acc_out[r][c];
                            end
                        end
                        state <= STATE_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                    end
                end
            endcase
        end
    end

    always_comb begin
        int idx;

        rd_data = 32'h00000000;
        if (rd_addr >= 8'h00 && rd_addr <= 8'h07) begin
            idx = rd_addr - 8'h00;
            rd_data = zext_f(a_tile[idx >> 2][idx[1:0]]);
        end else if (rd_addr >= 8'h10 && rd_addr <= 8'h1f) begin
            idx = rd_addr - 8'h10;
            rd_data = {27'h0, frodo_s_sign[idx >> 2][idx[1:0]], frodo_s_mag[idx >> 2][idx[1:0]]};
        end else if (rd_addr >= 8'h20 && rd_addr <= 8'h2f) begin
            idx = rd_addr - 8'h20;
            rd_data = {30'h0, scloud_s[idx >> 2][idx[1:0]]};
        end else if (rd_addr >= 8'h30 && rd_addr <= 8'h3f) begin
            idx = rd_addr - 8'h30;
            rd_data = zext_acc(c_acc_reg[idx >> 2][idx[1:0]]);
        end
    end

endmodule
