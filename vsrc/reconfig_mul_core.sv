// Tile-level reconfigurable matrix multiplication core.
// The core shares one 16-TC array across Frodo and Scloud+ modes.
// Frodo TC tree outputs are registered inside each TC. This core aligns mode
// and C accumulator state by one cycle before reduction/write-back.
(* use_dsp = "no" *)
module reconfig_mul_core #(
    parameter int F_W   = 16,
    parameter int S_W   = 12,
    parameter int ACC_W = 16
)(
    input  logic clk,
    input  logic rst_n,
    input  logic valid_in,

    input  logic alg_mode,
    input  logic op_mode,

    // Common A tile, maximum shape is 2 rows by 4 columns.
    input  logic [F_W-1:0] a_tile [0:1][0:3],

    // Frodo S encoding, maximum shape is 4 by 4.
    input  logic [3:0]     frodo_s_mag  [0:3][0:3],
    input  logic           frodo_s_sign [0:3][0:3],

    // Scloud+ ternary S encoding, maximum shape is 4 by 4.
    input  logic [1:0]     scloud_s [0:3][0:3],

    // Local C accumulator tile, maximum shape is 4 by 4.
    input  logic [ACC_W-1:0] c_acc_in [0:3][0:3],

    output logic valid_out,
    output logic [ACC_W-1:0] c_acc_out [0:3][0:3]
);

    localparam logic ALG_FRODO  = 1'b0;
    localparam logic ALG_SCLOUD = 1'b1;
    localparam logic OP_INNER   = 1'b0;
    localparam logic OP_OUTER   = 1'b1;

    logic [F_W-1:0] tc_frodo_a [0:15];
    logic [3:0]     tc_frodo_mag [0:15];
    logic           tc_frodo_sign [0:15];
    logic [S_W-1:0] tc_scloud_a_l [0:15];
    logic [S_W-1:0] tc_scloud_a_h [0:15];
    logic [1:0]     tc_scloud_s_l [0:15];
    logic [1:0]     tc_scloud_s_h [0:15];
    logic [S_W-1:0] tc_chain_in_l [0:15];
    logic [S_W-1:0] tc_chain_in_h [0:15];
    logic [S_W-1:0] inner_chain_in_l [0:15];
    logic [S_W-1:0] inner_chain_in_h [0:15];
    logic [S_W-1:0] outer_chain_in_l [0:15];
    logic [S_W-1:0] outer_chain_in_h [0:15];
    logic [F_W-1:0] tc_frodo_prod_abs [0:15];
    logic           tc_frodo_prod_sign [0:15];
    // Some lint tools can report this forward-only TC chain as circular
    // because all lanes are collected in one unpacked array.
    /* verilator lint_off UNOPTFLAT */
    logic [S_W-1:0] tc_chain_out_l [0:15];
    logic [S_W-1:0] tc_chain_out_h [0:15];
    /* verilator lint_on UNOPTFLAT */

    logic           red_op_mode [0:3];
    logic [F_W-1:0] red_p0 [0:3];
    logic [F_W-1:0] red_p1 [0:3];
    logic [F_W-1:0] red_p2 [0:3];
    logic [F_W-1:0] red_p3 [0:3];
    logic           red_sign0 [0:3];
    logic           red_sign1 [0:3];
    logic           red_sign2 [0:3];
    logic           red_sign3 [0:3];
    logic [F_W-1:0] red_delta0 [0:3];
    logic [F_W-1:0] red_delta1 [0:3];
    logic           red_delta1_valid [0:3];

    logic [ACC_W-1:0] c_acc_next [0:3][0:3];
    logic             valid_d;
    logic             valid_d2;
    logic             alg_mode_d;
    logic             alg_mode_d2;
    logic             op_mode_d;
    logic             op_mode_d2;
    logic [ACC_W-1:0] c_acc_in_d [0:3][0:3];
    logic [ACC_W-1:0] c_acc_in_d2 [0:3][0:3];
    logic [ACC_W-1:0] c_acc_next_scloud_inner [0:3][0:3];
    logic [S_W-1:0]   scloud_inner_mid_l [0:1][0:1];
    logic [S_W-1:0]   scloud_inner_mid_h [0:1][0:1];

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_tc
            localparam int INNER_R    = gi / 8;
            localparam int INNER_CGRP = (gi % 8) / 4;
            localparam int INNER_T    = gi % 4;
            localparam int OUTER_R    = gi / 4;
            localparam int OUTER_CGRP = (gi % 4) / 2;
            localparam int OUTER_T    = gi % 2;

            if (INNER_T == 0) begin : gen_inner_chain_start
                assign inner_chain_in_l[gi] = c_acc_in_d[INNER_R][INNER_CGRP << 1][S_W-1:0];
                assign inner_chain_in_h[gi] = c_acc_in_d[INNER_R][(INNER_CGRP << 1) + 1][S_W-1:0];
            end else if (INNER_T == 2) begin : gen_inner_chain_mid
                assign inner_chain_in_l[gi] = scloud_inner_mid_l[INNER_R][INNER_CGRP];
                assign inner_chain_in_h[gi] = scloud_inner_mid_h[INNER_R][INNER_CGRP];
            end else begin : gen_inner_chain_next
                assign inner_chain_in_l[gi] = tc_chain_out_l[gi - 1];
                assign inner_chain_in_h[gi] = tc_chain_out_h[gi - 1];
            end

            if (OUTER_T == 0) begin : gen_outer_chain_start
                assign outer_chain_in_l[gi] = c_acc_in_d[OUTER_R][OUTER_CGRP << 1][S_W-1:0];
                assign outer_chain_in_h[gi] = c_acc_in_d[OUTER_R][(OUTER_CGRP << 1) + 1][S_W-1:0];
            end else begin : gen_outer_chain_next
                assign outer_chain_in_l[gi] = tc_chain_out_l[gi - 1];
                assign outer_chain_in_h[gi] = tc_chain_out_h[gi - 1];
            end

            assign tc_chain_in_l[gi] = (alg_mode == ALG_SCLOUD) ?
                                       ((op_mode == OP_INNER) ? inner_chain_in_l[gi] : outer_chain_in_l[gi]) :
                                       '0;
            assign tc_chain_in_h[gi] = (alg_mode == ALG_SCLOUD) ?
                                       ((op_mode == OP_INNER) ? inner_chain_in_h[gi] : outer_chain_in_h[gi]) :
                                       '0;

            tc_reconfig #(
                .F_W(F_W),
                .S_W(S_W)
            ) u_tc (
                .clk(clk),
                .rst_n(rst_n),
                .alg_mode(alg_mode),
                .frodo_a(tc_frodo_a[gi]),
                .frodo_mag(tc_frodo_mag[gi]),
                .frodo_sign(tc_frodo_sign[gi]),
                .scloud_a_l(tc_scloud_a_l[gi]),
                .scloud_a_h(tc_scloud_a_h[gi]),
                .scloud_s_l(tc_scloud_s_l[gi]),
                .scloud_s_h(tc_scloud_s_h[gi]),
                .chain_in_l(tc_chain_in_l[gi]),
                .chain_in_h(tc_chain_in_h[gi]),
                .frodo_prod_abs(tc_frodo_prod_abs[gi]),
                .frodo_prod_sign(tc_frodo_prod_sign[gi]),
                .chain_out_l(tc_chain_out_l[gi]),
                .chain_out_h(tc_chain_out_h[gi])
            );
        end
    endgenerate

    genvar gr;
    generate
        for (gr = 0; gr < 4; gr = gr + 1) begin : gen_reduction
            reduction_block #(
                .W(F_W)
            ) u_reduction (
                .op_mode(red_op_mode[gr]),
                .p0(red_p0[gr]),
                .p1(red_p1[gr]),
                .p2(red_p2[gr]),
                .p3(red_p3[gr]),
                .sign0(red_sign0[gr]),
                .sign1(red_sign1[gr]),
                .sign2(red_sign2[gr]),
                .sign3(red_sign3[gr]),
                .delta0(red_delta0[gr]),
                .delta1(red_delta1[gr]),
                .delta1_valid(red_delta1_valid[gr])
            );
        end
    endgenerate

    function automatic int idx_inner(
        input int r,
        input int cgrp,
        input int t
    );
        begin
            idx_inner = (r << 3) + (cgrp << 2) + t;
        end
    endfunction

    function automatic int idx_outer(
        input int r,
        input int cgrp,
        input int t
    );
        begin
            idx_outer = (r << 2) + (cgrp << 1) + t;
        end
    endfunction

    always_comb begin
        int i;
        int r;
        int c;
        int cgrp;
        int t;
        int idx;
        int block_idx;

        for (i = 0; i < 16; i = i + 1) begin
            tc_frodo_a[i]     = '0;
            tc_frodo_mag[i]   = '0;
            tc_frodo_sign[i]  = 1'b0;
            tc_scloud_a_l[i]  = '0;
            tc_scloud_a_h[i]  = '0;
            tc_scloud_s_l[i]  = 2'b00;
            tc_scloud_s_h[i]  = 2'b00;
        end

        for (i = 0; i < 4; i = i + 1) begin
            red_op_mode[i] = op_mode_d;
            red_p0[i]     = '0;
            red_p1[i]     = '0;
            red_p2[i]     = '0;
            red_p3[i]     = '0;
            red_sign0[i]  = 1'b0;
            red_sign1[i]  = 1'b0;
            red_sign2[i]  = 1'b0;
            red_sign3[i]  = 1'b0;
        end

        for (r = 0; r < 4; r = r + 1) begin
            for (c = 0; c < 4; c = c + 1) begin
                c_acc_next[r][c] = c_acc_in_d[r][c];
                c_acc_next_scloud_inner[r][c] = c_acc_in_d2[r][c];
            end
        end

        if (alg_mode == ALG_FRODO && op_mode == OP_INNER) begin
            // Frodo inner mapping:
            // A rows 0..1, S columns 0..1, four TC products per C element.
            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 2; c = c + 1) begin
                    for (t = 0; t < 4; t = t + 1) begin
                        idx = idx_inner(r, c, t);
                        tc_frodo_a[idx]    = a_tile[r][t];
                        tc_frodo_mag[idx]  = frodo_s_mag[t][c];
                        tc_frodo_sign[idx] = frodo_s_sign[t][c];
                    end
                end
            end
        end else if (alg_mode == ALG_FRODO && op_mode == OP_OUTER) begin
            // Frodo outer mapping:
            // Each reduction block splits into two two-term outputs.
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 2; c = c + 1) begin
                    for (t = 0; t < 2; t = t + 1) begin
                        idx = idx_outer(r, c, t);
                        tc_frodo_a[idx]    = a_tile[t][c];
                        tc_frodo_mag[idx]  = frodo_s_mag[r][t];
                        tc_frodo_sign[idx] = frodo_s_sign[r][t];
                    end
                end
            end
        end else if (alg_mode == ALG_SCLOUD && op_mode == OP_INNER) begin
            // Scloud+ inner ADD_L/H mapping:
            // cgrp 0 lanes feed C columns 0 and 1; cgrp 1 lanes feed columns 2 and 3.
            // Pipeline cut candidate: after TC t=1 in each chain.
            for (r = 0; r < 2; r = r + 1) begin
                for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                    for (t = 0; t < 4; t = t + 1) begin
                        idx = idx_inner(r, cgrp, t);
                        tc_scloud_a_l[idx] = a_tile[r][t][S_W-1:0];
                        tc_scloud_a_h[idx] = a_tile[r][t][S_W-1:0];
                        tc_scloud_s_l[idx] = scloud_s[t][cgrp << 1];
                        tc_scloud_s_h[idx] = scloud_s[t][(cgrp << 1) + 1];
                    end
                end
            end
        end else begin
            // Scloud+ outer column mapping:
            // ADD_L uses A column 2*cgrp, ADD_H uses A column 2*cgrp+1.
            // Each output chain has only two TC stages.
            for (r = 0; r < 4; r = r + 1) begin
                for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                    for (t = 0; t < 2; t = t + 1) begin
                        idx = idx_outer(r, cgrp, t);
                        tc_scloud_a_l[idx] = a_tile[t][cgrp << 1][S_W-1:0];
                        tc_scloud_a_h[idx] = a_tile[t][(cgrp << 1) + 1][S_W-1:0];
                        tc_scloud_s_l[idx] = scloud_s[r][t];
                        tc_scloud_s_h[idx] = scloud_s[r][t];
                    end
                end
            end
        end

        if (alg_mode_d == ALG_FRODO && op_mode_d == OP_INNER) begin
            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 2; c = c + 1) begin
                    block_idx = (r << 1) + c;
                    red_op_mode[block_idx] = OP_INNER;
                    red_p0[block_idx]      = tc_frodo_prod_abs[idx_inner(r, c, 0)];
                    red_p1[block_idx]      = tc_frodo_prod_abs[idx_inner(r, c, 1)];
                    red_p2[block_idx]      = tc_frodo_prod_abs[idx_inner(r, c, 2)];
                    red_p3[block_idx]      = tc_frodo_prod_abs[idx_inner(r, c, 3)];
                    red_sign0[block_idx]   = tc_frodo_prod_sign[idx_inner(r, c, 0)];
                    red_sign1[block_idx]   = tc_frodo_prod_sign[idx_inner(r, c, 1)];
                    red_sign2[block_idx]   = tc_frodo_prod_sign[idx_inner(r, c, 2)];
                    red_sign3[block_idx]   = tc_frodo_prod_sign[idx_inner(r, c, 3)];
                    c_acc_next[r][c]       = c_acc_in_d[r][c] + red_delta0[block_idx];
                end
            end
        end else if (alg_mode_d == ALG_FRODO && op_mode_d == OP_OUTER) begin
            for (r = 0; r < 4; r = r + 1) begin
                red_op_mode[r] = OP_OUTER;
                red_p0[r]     = tc_frodo_prod_abs[idx_outer(r, 0, 0)];
                red_p1[r]     = tc_frodo_prod_abs[idx_outer(r, 0, 1)];
                red_p2[r]     = tc_frodo_prod_abs[idx_outer(r, 1, 0)];
                red_p3[r]     = tc_frodo_prod_abs[idx_outer(r, 1, 1)];
                red_sign0[r]  = tc_frodo_prod_sign[idx_outer(r, 0, 0)];
                red_sign1[r]  = tc_frodo_prod_sign[idx_outer(r, 0, 1)];
                red_sign2[r]  = tc_frodo_prod_sign[idx_outer(r, 1, 0)];
                red_sign3[r]  = tc_frodo_prod_sign[idx_outer(r, 1, 1)];

                c_acc_next[r][0] = c_acc_in_d[r][0] + red_delta0[r];
                c_acc_next[r][1] = c_acc_in_d[r][1] + red_delta1[r];
            end
        end else if (alg_mode_d == ALG_SCLOUD && op_mode_d == OP_INNER) begin
            // Scloud+ inner writes back one cycle later, after the mid-register
            // between TC1 and TC2.
        end else begin
            for (r = 0; r < 4; r = r + 1) begin
                for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                    c_acc_next[r][cgrp << 1]       = {{(ACC_W-S_W){1'b0}}, tc_chain_out_l[idx_outer(r, cgrp, 1)]};
                    c_acc_next[r][(cgrp << 1) + 1] = {{(ACC_W-S_W){1'b0}}, tc_chain_out_h[idx_outer(r, cgrp, 1)]};
                end
            end
        end

        if (alg_mode_d2 == ALG_SCLOUD && op_mode_d2 == OP_INNER) begin
            for (r = 0; r < 2; r = r + 1) begin
                for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                    c_acc_next_scloud_inner[r][cgrp << 1]       = {{(ACC_W-S_W){1'b0}}, tc_chain_out_l[idx_inner(r, cgrp, 3)]};
                    c_acc_next_scloud_inner[r][(cgrp << 1) + 1] = {{(ACC_W-S_W){1'b0}}, tc_chain_out_h[idx_inner(r, cgrp, 3)]};
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        int r;
        int c;
        int cgrp;

        if (!rst_n) begin
            valid_out  <= 1'b0;
            valid_d    <= 1'b0;
            valid_d2   <= 1'b0;
            alg_mode_d <= ALG_FRODO;
            alg_mode_d2 <= ALG_FRODO;
            op_mode_d  <= OP_INNER;
            op_mode_d2  <= OP_INNER;
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    c_acc_out[r][c]  <= '0;
                    c_acc_in_d[r][c] <= '0;
                    c_acc_in_d2[r][c] <= '0;
                end
            end
            for (r = 0; r < 2; r = r + 1) begin
                for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                    scloud_inner_mid_l[r][cgrp] <= '0;
                    scloud_inner_mid_h[r][cgrp] <= '0;
                end
            end
        end else begin
            valid_d    <= valid_in;
            valid_d2   <= valid_d;
            valid_out  <= valid_d2;
            alg_mode_d <= alg_mode;
            alg_mode_d2 <= alg_mode_d;
            op_mode_d  <= op_mode;
            op_mode_d2  <= op_mode_d;

            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    c_acc_in_d[r][c] <= c_acc_in[r][c];
                    c_acc_in_d2[r][c] <= c_acc_in_d[r][c];
                end
            end

            if (alg_mode == ALG_SCLOUD && op_mode == OP_INNER) begin
                for (r = 0; r < 2; r = r + 1) begin
                    for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                        scloud_inner_mid_l[r][cgrp] <= tc_chain_out_l[idx_inner(r, cgrp, 1)];
                        scloud_inner_mid_h[r][cgrp] <= tc_chain_out_h[idx_inner(r, cgrp, 1)];
                    end
                end
            end

            if (valid_d2) begin
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        if (alg_mode_d2 == ALG_SCLOUD && op_mode_d2 == OP_INNER) begin
                            c_acc_out[r][c] <= c_acc_next_scloud_inner[r][c];
                        end else begin
                            c_acc_out[r][c] <= c_acc_next[r][c];
                        end
                    end
                end
            end
        end
    end

endmodule
