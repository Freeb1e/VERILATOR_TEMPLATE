// Reference-style 32-multiplier array.
//
// This version keeps the datapath intentionally close to the paper-style
// "multiplier array + adder tree" structure:
//   - 32 small 16x4 shift-add multiplier cells
//   - 8 configurable adder trees
//   - inner mode: each tree reduces 4 products into one C element
//   - outer mode: each tree reduces two product pairs into two C elements
//
// The same array is used for Frodo and Scloud+.  Scloud+ ternary coefficients
// are encoded as magnitude/sign values and the final result is truncated to
// S_W bits.
(* use_dsp = "no" *)
module ref_mul_cell #(
    parameter int W = 16
)(
    input  logic         clk,
    input  logic         rst_n,
    input  logic [W-1:0] a,
    input  logic [3:0]   mag,
    input  logic         sign,
    output logic [W-1:0] signed_prod
);

    logic [W-1:0] part0;
    logic [W-1:0] part1;
    logic [W-1:0] part2;
    logic [W-1:0] part3;
    logic [W-1:0] sum_l;
    logic [W-1:0] sum_h;
    logic [W-1:0] prod_abs;
    logic [W-1:0] a_q;
    logic [3:0]   mag_q;
    logic         sign_q;
    logic [W-1:0] prod_abs_q;
    logic         prod_sign_q;

    always_comb begin
        part0 = mag_q[0] ? a_q        : '0;
        part1 = mag_q[1] ? (a_q << 1) : '0;
        part2 = mag_q[2] ? (a_q << 2) : '0;
        part3 = mag_q[3] ? (a_q << 3) : '0;

        sum_l    = part0 + part1;
        sum_h    = part2 + part3;
        prod_abs = sum_l + sum_h;

        signed_prod = prod_sign_q ? (~prod_abs_q + {{(W-1){1'b0}}, 1'b1}) : prod_abs_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_q         <= '0;
            mag_q       <= '0;
            sign_q      <= 1'b0;
            prod_abs_q  <= '0;
            prod_sign_q <= 1'b0;
        end else begin
            a_q         <= a;
            mag_q       <= mag;
            sign_q      <= sign;
            prod_abs_q  <= prod_abs;
            prod_sign_q <= sign_q;
        end
    end

endmodule

(* use_dsp = "no" *)
module ref_adder_tree #(
    parameter int W = 16
)(
    input  logic         op_mode,
    input  logic [W-1:0] p0,
    input  logic [W-1:0] p1,
    input  logic [W-1:0] p2,
    input  logic [W-1:0] p3,
    input  logic [W-1:0] addend0,
    input  logic [W-1:0] addend1,
    output logic [W-1:0] out0,
    output logic [W-1:0] out1
);

    localparam logic OP_INNER = 1'b0;

    logic [W-1:0] pair0;
    logic [W-1:0] pair1;
    logic [W-1:0] sum4;

    always_comb begin
        pair0 = p0 + p1;
        pair1 = p2 + p3;
        sum4  = pair0 + pair1;

        if (op_mode == OP_INNER) begin
            out0 = addend0 + sum4;
            out1 = '0;
        end else begin
            out0 = addend0 + pair0;
            out1 = addend1 + pair1;
        end
    end

endmodule

(* use_dsp = "no" *)
module ref_multiplier_array_core #(
    parameter int F_W   = 16,
    parameter int S_W   = 12,
    parameter int ACC_W = 16
)(
    input  logic clk,
    input  logic rst_n,
    input  logic valid_in,

    input  logic alg_mode,
    input  logic op_mode,

    input  logic [F_W-1:0] a_tile [0:1][0:3],

    input  logic [3:0]     frodo_s_mag  [0:3][0:3],
    input  logic           frodo_s_sign [0:3][0:3],

    input  logic [1:0]     scloud_s [0:3][0:3],

    input  logic [ACC_W-1:0] c_acc_in [0:3][0:3],

    output logic valid_out,
    output logic [ACC_W-1:0] c_acc_out [0:3][0:3]
);

    localparam logic ALG_FRODO  = 1'b0;
    localparam logic ALG_SCLOUD = 1'b1;
    localparam logic OP_INNER   = 1'b0;

    logic [F_W-1:0] mul_a [0:31];
    logic [3:0]     mul_mag [0:31];
    logic           mul_sign [0:31];
    logic [F_W-1:0] mul_prod [0:31];

    logic [F_W-1:0] tree_addend0 [0:7];
    logic [F_W-1:0] tree_addend1 [0:7];
    logic [F_W-1:0] tree_addend0_d1 [0:7];
    logic [F_W-1:0] tree_addend1_d1 [0:7];
    logic [F_W-1:0] tree_addend0_d2 [0:7];
    logic [F_W-1:0] tree_addend1_d2 [0:7];
    logic [F_W-1:0] tree_out0 [0:7];
    logic [F_W-1:0] tree_out1 [0:7];
    logic [ACC_W-1:0] c_acc_in_d1 [0:3][0:3];
    logic [ACC_W-1:0] c_acc_in_d2 [0:3][0:3];
    logic             valid_d1;
    logic             valid_d2;
    logic             alg_mode_d1;
    logic             alg_mode_d2;
    logic             op_mode_d1;
    logic             op_mode_d2;

    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_mul
            ref_mul_cell #(
                .W(F_W)
            ) u_mul (
                .clk(clk),
                .rst_n(rst_n),
                .a(mul_a[gi]),
                .mag(mul_mag[gi]),
                .sign(mul_sign[gi]),
                .signed_prod(mul_prod[gi])
            );
        end
    endgenerate

    genvar gt;
    generate
        for (gt = 0; gt < 8; gt = gt + 1) begin : gen_tree
            ref_adder_tree #(
                .W(F_W)
            ) u_tree (
                .op_mode(op_mode_d2),
                .p0(mul_prod[(gt << 2) + 0]),
                .p1(mul_prod[(gt << 2) + 1]),
                .p2(mul_prod[(gt << 2) + 2]),
                .p3(mul_prod[(gt << 2) + 3]),
                .addend0(tree_addend0_d2[gt]),
                .addend1(tree_addend1_d2[gt]),
                .out0(tree_out0[gt]),
                .out1(tree_out1[gt])
            );
        end
    endgenerate

    function automatic int idx_inner(
        input int r,
        input int c,
        input int t
    );
        begin
            idx_inner = ((r << 2) + c) << 2;
            idx_inner = idx_inner + t;
        end
    endfunction

    function automatic int tree_inner(
        input int r,
        input int c
    );
        begin
            tree_inner = (r << 2) + c;
        end
    endfunction

    function automatic int tree_outer(
        input int r,
        input int cgrp
    );
        begin
            tree_outer = (r << 1) + cgrp;
        end
    endfunction

    function automatic logic [3:0] scloud_mag(
        input logic [1:0] s
    );
        begin
            scloud_mag = (s == 2'b01 || s == 2'b10) ? 4'd1 : 4'd0;
        end
    endfunction

    function automatic logic scloud_sign(
        input logic [1:0] s
    );
        begin
            scloud_sign = (s == 2'b10);
        end
    endfunction

    function automatic logic [ACC_W-1:0] mask_result(
        input logic [F_W-1:0] value
    );
        begin
            if (alg_mode_d2 == ALG_SCLOUD) begin
                mask_result = {{(ACC_W-S_W){1'b0}}, value[S_W-1:0]};
            end else begin
                mask_result = value[ACC_W-1:0];
            end
        end
    endfunction

    function automatic logic [F_W-1:0] addend_value(
        input int r,
        input int c
    );
        begin
            if (alg_mode == ALG_SCLOUD) begin
                addend_value = {{(F_W-S_W){1'b0}}, c_acc_in[r][c][S_W-1:0]};
            end else begin
                addend_value = c_acc_in[r][c][F_W-1:0];
            end
        end
    endfunction

    always_comb begin
        int i;
        int r;
        int c;
        int cgrp;
        int t;
        int idx;
        int tree_idx;

        for (i = 0; i < 32; i = i + 1) begin
            mul_a[i]    = '0;
            mul_mag[i]  = '0;
            mul_sign[i] = 1'b0;
        end

        for (i = 0; i < 8; i = i + 1) begin
            tree_addend0[i] = '0;
            tree_addend1[i] = '0;
        end

        if (op_mode == OP_INNER) begin
            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    tree_addend0[tree_inner(r, c)] = addend_value(r, c);
                    for (t = 0; t < 4; t = t + 1) begin
                        idx = idx_inner(r, c, t);
                        if (alg_mode == ALG_FRODO) begin
                            mul_a[idx]    = a_tile[r][t];
                            mul_mag[idx]  = frodo_s_mag[t][c];
                            mul_sign[idx] = frodo_s_sign[t][c];
                        end else begin
                            mul_a[idx]    = {{(F_W-S_W){1'b0}}, a_tile[r][t][S_W-1:0]};
                            mul_mag[idx]  = scloud_mag(scloud_s[t][c]);
                            mul_sign[idx] = scloud_sign(scloud_s[t][c]);
                        end
                    end
                end
            end
        end else begin
            for (r = 0; r < 4; r = r + 1) begin
                for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                    tree_idx = tree_outer(r, cgrp);
                    c = cgrp << 1;
                    tree_addend0[tree_idx] = addend_value(r, c);
                    tree_addend1[tree_idx] = addend_value(r, c + 1);

                    for (t = 0; t < 2; t = t + 1) begin
                        idx = (tree_idx << 2) + t;
                        if (alg_mode == ALG_FRODO) begin
                            mul_a[idx]    = a_tile[t][c];
                            mul_mag[idx]  = frodo_s_mag[r][t];
                            mul_sign[idx] = frodo_s_sign[r][t];
                        end else begin
                            mul_a[idx]    = {{(F_W-S_W){1'b0}}, a_tile[t][c][S_W-1:0]};
                            mul_mag[idx]  = scloud_mag(scloud_s[r][t]);
                            mul_sign[idx] = scloud_sign(scloud_s[r][t]);
                        end

                        idx = (tree_idx << 2) + 2 + t;
                        if (alg_mode == ALG_FRODO) begin
                            mul_a[idx]    = a_tile[t][c + 1];
                            mul_mag[idx]  = frodo_s_mag[r][t];
                            mul_sign[idx] = frodo_s_sign[r][t];
                        end else begin
                            mul_a[idx]    = {{(F_W-S_W){1'b0}}, a_tile[t][c + 1][S_W-1:0]};
                            mul_mag[idx]  = scloud_mag(scloud_s[r][t]);
                            mul_sign[idx] = scloud_sign(scloud_s[r][t]);
                        end
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        int r;
        int c;
        int cgrp;
        int tree_idx;

        if (!rst_n) begin
            valid_out <= 1'b0;
            valid_d1  <= 1'b0;
            valid_d2  <= 1'b0;
            alg_mode_d1 <= ALG_FRODO;
            alg_mode_d2 <= ALG_FRODO;
            op_mode_d1  <= OP_INNER;
            op_mode_d2  <= OP_INNER;
            for (tree_idx = 0; tree_idx < 8; tree_idx = tree_idx + 1) begin
                tree_addend0_d1[tree_idx] <= '0;
                tree_addend1_d1[tree_idx] <= '0;
                tree_addend0_d2[tree_idx] <= '0;
                tree_addend1_d2[tree_idx] <= '0;
            end
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    c_acc_out[r][c] <= '0;
                    c_acc_in_d1[r][c] <= '0;
                    c_acc_in_d2[r][c] <= '0;
                end
            end
        end else begin
            valid_d1  <= valid_in;
            valid_d2  <= valid_d1;
            valid_out <= valid_d2;
            alg_mode_d1 <= alg_mode;
            alg_mode_d2 <= alg_mode_d1;
            op_mode_d1  <= op_mode;
            op_mode_d2  <= op_mode_d1;

            for (tree_idx = 0; tree_idx < 8; tree_idx = tree_idx + 1) begin
                tree_addend0_d1[tree_idx] <= tree_addend0[tree_idx];
                tree_addend1_d1[tree_idx] <= tree_addend1[tree_idx];
                tree_addend0_d2[tree_idx] <= tree_addend0_d1[tree_idx];
                tree_addend1_d2[tree_idx] <= tree_addend1_d1[tree_idx];
            end

            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    c_acc_in_d1[r][c] <= c_acc_in[r][c];
                    c_acc_in_d2[r][c] <= c_acc_in_d1[r][c];
                end
            end

            if (valid_d2) begin
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        c_acc_out[r][c] <= c_acc_in_d2[r][c];
                    end
                end

                if (op_mode_d2 == OP_INNER) begin
                    for (r = 0; r < 2; r = r + 1) begin
                        for (c = 0; c < 4; c = c + 1) begin
                            c_acc_out[r][c] <= mask_result(tree_out0[tree_inner(r, c)]);
                        end
                    end
                end else begin
                    for (r = 0; r < 4; r = r + 1) begin
                        for (cgrp = 0; cgrp < 2; cgrp = cgrp + 1) begin
                            tree_idx = tree_outer(r, cgrp);
                            c_acc_out[r][cgrp << 1]       <= mask_result(tree_out0[tree_idx]);
                            c_acc_out[r][(cgrp << 1) + 1] <= mask_result(tree_out1[tree_idx]);
                        end
                    end
                end
            end
        end
    end

endmodule
