module FS_mul_test (
    input logic clk,
    input logic rst_n
);

    localparam int F_W = 16;
    localparam int S_W = 12;

    localparam logic ALG_FRODO  = 1'b0;
    localparam logic ALG_SCLOUD = 1'b1;
    localparam logic OP_INNER   = 1'b0;
    localparam logic OP_OUTER   = 1'b1;

    logic           alg_mode;
    logic [F_W-1:0] frodo_a;
    logic [3:0]     frodo_mag;
    logic           frodo_sign;
    logic [S_W-1:0] scloud_a_l;
    logic [S_W-1:0] scloud_a_h;
    logic [1:0]     scloud_s_l;
    logic [1:0]     scloud_s_h;
    logic [S_W-1:0] chain_in_l;
    logic [S_W-1:0] chain_in_h;
    logic [F_W-1:0] frodo_prod_abs;
    logic           frodo_prod_sign;
    logic [S_W-1:0] chain_out_l;
    logic [S_W-1:0] chain_out_h;
    logic           red_op_mode;
    logic [F_W-1:0] red_p0;
    logic [F_W-1:0] red_p1;
    logic [F_W-1:0] red_p2;
    logic [F_W-1:0] red_p3;
    logic           red_sign0;
    logic           red_sign1;
    logic           red_sign2;
    logic           red_sign3;
    logic [F_W-1:0] red_delta0;
    logic [F_W-1:0] red_delta1;
    logic           red_delta1_valid;
    logic           core_valid_in;
    logic           core_alg_mode;
    logic           core_op_mode;
    logic [F_W-1:0] core_a_tile [0:1][0:3];
    logic [3:0]     core_frodo_s_mag [0:3][0:3];
    logic           core_frodo_s_sign [0:3][0:3];
    logic [1:0]     core_scloud_s [0:3][0:3];
    logic [F_W-1:0] core_c_acc_in [0:3][0:3];
    logic           core_valid_out;
    logic [F_W-1:0] core_c_acc_out [0:3][0:3];
    logic [F_W-1:0] core_expected [0:3][0:3];
    logic [F_W-1:0] core_expected_d1 [0:3][0:3];
    logic [F_W-1:0] core_expected_d2 [0:3][0:3];
    logic [F_W-1:0] core_expected_d3 [0:3][0:3];
    logic           core_expect_valid;
    logic           core_expect_valid_d1;
    logic           core_expect_valid_d2;
    logic           core_expect_valid_d3;
    int             core_case_id;
    int unsigned    tb_rand_state;

    tc_reconfig #(
        .F_W(F_W),
        .S_W(S_W)
    ) u_tc (
        .clk(clk),
        .rst_n(rst_n),
        .alg_mode(alg_mode),
        .frodo_a(frodo_a),
        .frodo_mag(frodo_mag),
        .frodo_sign(frodo_sign),
        .scloud_a_l(scloud_a_l),
        .scloud_a_h(scloud_a_h),
        .scloud_s_l(scloud_s_l),
        .scloud_s_h(scloud_s_h),
        .chain_in_l(chain_in_l),
        .chain_in_h(chain_in_h),
        .frodo_prod_abs(frodo_prod_abs),
        .frodo_prod_sign(frodo_prod_sign),
        .chain_out_l(chain_out_l),
        .chain_out_h(chain_out_h)
    );

    reduction_block #(
        .W(F_W)
    ) u_reduction (
        .op_mode(red_op_mode),
        .p0(red_p0),
        .p1(red_p1),
        .p2(red_p2),
        .p3(red_p3),
        .sign0(red_sign0),
        .sign1(red_sign1),
        .sign2(red_sign2),
        .sign3(red_sign3),
        .delta0(red_delta0),
        .delta1(red_delta1),
        .delta1_valid(red_delta1_valid)
    );

    reconfig_mul_core #(
        .F_W(F_W),
        .S_W(S_W),
        .ACC_W(F_W)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(core_valid_in),
        .alg_mode(core_alg_mode),
        .op_mode(core_op_mode),
        .a_tile(core_a_tile),
        .frodo_s_mag(core_frodo_s_mag),
        .frodo_s_sign(core_frodo_s_sign),
        .scloud_s(core_scloud_s),
        .c_acc_in(core_c_acc_in),
        .valid_out(core_valid_out),
        .c_acc_out(core_c_acc_out)
    );

    function automatic logic [F_W-1:0] frodo_ref(
        input logic [F_W-1:0] a,
        input logic [3:0]     mag
    );
        logic [F_W-1:0] p0;
        logic [F_W-1:0] p1;
        logic [F_W-1:0] p2;
        logic [F_W-1:0] p3;
        begin
            p0 = mag[0] ? a        : '0;
            p1 = mag[1] ? (a << 1) : '0;
            p2 = mag[2] ? (a << 2) : '0;
            p3 = mag[3] ? (a << 3) : '0;
            frodo_ref = p0 + p1 + p2 + p3;
        end
    endfunction

    function automatic logic [S_W-1:0] scloud_ref(
        input logic [S_W-1:0] chain_in,
        input logic [S_W-1:0] a,
        input logic [1:0]     s
    );
        begin
            case (s)
                2'b00: scloud_ref = chain_in;
                2'b01: scloud_ref = chain_in + a;
                2'b10: scloud_ref = chain_in + ~a + {{(S_W-1){1'b0}}, 1'b1};
                default: scloud_ref = chain_in;
            endcase
        end
    endfunction

    function automatic logic [F_W-1:0] signed_term_ref(
        input logic [F_W-1:0] p,
        input logic           sign
    );
        begin
            signed_term_ref = sign ? (~p + {{(F_W-1){1'b0}}, 1'b1}) : p;
        end
    endfunction

    function automatic logic [F_W-1:0] pair_ref(
        input logic [F_W-1:0] p0,
        input logic [F_W-1:0] p1,
        input logic           sign0,
        input logic           sign1
    );
        begin
            pair_ref = signed_term_ref(p0, sign0) + signed_term_ref(p1, sign1);
        end
    endfunction

    function automatic logic [F_W-1:0] four_term_ref(
        input logic [F_W-1:0] p0,
        input logic [F_W-1:0] p1,
        input logic [F_W-1:0] p2,
        input logic [F_W-1:0] p3,
        input logic           sign0,
        input logic           sign1,
        input logic           sign2,
        input logic           sign3
    );
        begin
            four_term_ref = pair_ref(p0, p1, sign0, sign1) + pair_ref(p2, p3, sign2, sign3);
        end
    endfunction

    task automatic drive_frodo(
        input logic [F_W-1:0] a,
        input logic [3:0]     mag,
        input logic           sign
    );
        begin
            alg_mode     <= ALG_FRODO;
            frodo_a      <= a;
            frodo_mag    <= mag;
            frodo_sign   <= sign;
            scloud_a_l   <= '0;
            scloud_a_h   <= '0;
            scloud_s_l   <= 2'b00;
            scloud_s_h   <= 2'b00;
            chain_in_l   <= '0;
            chain_in_h   <= '0;
        end
    endtask

    task automatic check_frodo_outputs(
        input logic [F_W-1:0] a,
        input logic [3:0]     mag,
        input logic           sign
    );
        logic [F_W-1:0] expected;
        begin
            expected = frodo_ref(a, mag);
            if (frodo_prod_abs !== expected) begin
                $fatal(1, "Frodo prod mismatch: a=%h mag=%h got=%h expected=%h",
                       a, mag, frodo_prod_abs, expected);
            end
            if (frodo_prod_sign !== sign) begin
                $fatal(1, "Frodo sign mismatch: got=%b expected=%b",
                       frodo_prod_sign, sign);
            end
        end
    endtask

    task automatic drive_scloud(
        input logic [S_W-1:0] in_l,
        input logic [S_W-1:0] in_h,
        input logic [S_W-1:0] a_l,
        input logic [S_W-1:0] a_h,
        input logic [1:0]     s_l,
        input logic [1:0]     s_h
    );
        begin
            alg_mode     <= ALG_SCLOUD;
            frodo_a      <= '0;
            frodo_mag    <= '0;
            frodo_sign   <= 1'b0;
            scloud_a_l   <= a_l;
            scloud_a_h   <= a_h;
            scloud_s_l   <= s_l;
            scloud_s_h   <= s_h;
            chain_in_l   <= in_l;
            chain_in_h   <= in_h;
        end
    endtask

    task automatic check_scloud_outputs(
        input logic [S_W-1:0] in_l,
        input logic [S_W-1:0] in_h,
        input logic [S_W-1:0] a_l,
        input logic [S_W-1:0] a_h,
        input logic [1:0]     s_l,
        input logic [1:0]     s_h
    );
        logic [S_W-1:0] expected_l;
        logic [S_W-1:0] expected_h;
        begin
            expected_l = scloud_ref(in_l, a_l, s_l);
            expected_h = scloud_ref(in_h, a_h, s_h);
            if (chain_out_l !== expected_l) begin
                $fatal(1, "Scloud lane L mismatch: in=%h a=%h s=%b got=%h expected=%h",
                       in_l, a_l, s_l, chain_out_l, expected_l);
            end
            if (chain_out_h !== expected_h) begin
                $fatal(1, "Scloud lane H mismatch: in=%h a=%h s=%b got=%h expected=%h",
                       in_h, a_h, s_h, chain_out_h, expected_h);
            end
        end
    endtask

    task automatic drive_reduction(
        input logic           op_mode,
        input logic [F_W-1:0] p0,
        input logic [F_W-1:0] p1,
        input logic [F_W-1:0] p2,
        input logic [F_W-1:0] p3,
        input logic           sign0,
        input logic           sign1,
        input logic           sign2,
        input logic           sign3
    );
        begin
            red_op_mode <= op_mode;
            red_p0      <= p0;
            red_p1      <= p1;
            red_p2      <= p2;
            red_p3      <= p3;
            red_sign0   <= sign0;
            red_sign1   <= sign1;
            red_sign2   <= sign2;
            red_sign3   <= sign3;
        end
    endtask

    task automatic check_reduction_inner_outputs(
        input logic [F_W-1:0] p0,
        input logic [F_W-1:0] p1,
        input logic [F_W-1:0] p2,
        input logic [F_W-1:0] p3,
        input logic           sign0,
        input logic           sign1,
        input logic           sign2,
        input logic           sign3
    );
        logic [F_W-1:0] expected;
        begin
            expected = four_term_ref(p0, p1, p2, p3, sign0, sign1, sign2, sign3);
            if (red_delta0 !== expected) begin
                $fatal(1, "Reduction inner mismatch: got=%h expected=%h", red_delta0, expected);
            end
            if (red_delta1 !== '0) begin
                $fatal(1, "Reduction inner delta1 mismatch: got=%h expected=0", red_delta1);
            end
            if (red_delta1_valid !== 1'b0) begin
                $fatal(1, "Reduction inner valid mismatch: got=%b expected=0", red_delta1_valid);
            end
        end
    endtask

    task automatic check_reduction_outer_outputs(
        input logic [F_W-1:0] p0,
        input logic [F_W-1:0] p1,
        input logic [F_W-1:0] p2,
        input logic [F_W-1:0] p3,
        input logic           sign0,
        input logic           sign1,
        input logic           sign2,
        input logic           sign3
    );
        logic [F_W-1:0] expected0;
        logic [F_W-1:0] expected1;
        begin
            expected0 = pair_ref(p0, p1, sign0, sign1);
            expected1 = pair_ref(p2, p3, sign2, sign3);
            if (red_delta0 !== expected0) begin
                $fatal(1, "Reduction outer delta0 mismatch: got=%h expected=%h", red_delta0, expected0);
            end
            if (red_delta1 !== expected1) begin
                $fatal(1, "Reduction outer delta1 mismatch: got=%h expected=%h", red_delta1, expected1);
            end
            if (red_delta1_valid !== 1'b1) begin
                $fatal(1, "Reduction outer valid mismatch: got=%b expected=1", red_delta1_valid);
            end
        end
    endtask

    task automatic clear_core_inputs;
        int r;
        int c;
        begin
            core_valid_in <= 1'b0;
            core_alg_mode <= ALG_FRODO;
            core_op_mode  <= OP_INNER;
            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    core_a_tile[r][c] <= '0;
                end
            end
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    core_frodo_s_mag[r][c]  <= '0;
                    core_frodo_s_sign[r][c] <= 1'b0;
                    core_scloud_s[r][c]     <= 2'b00;
                    core_c_acc_in[r][c]     <= '0;
                    core_expected[r][c]     <= '0;
                    core_expected_d1[r][c]  <= '0;
                    core_expected_d2[r][c]  <= '0;
                    core_expected_d3[r][c]  <= '0;
                end
            end
            core_expect_valid <= 1'b0;
            core_expect_valid_d1 <= 1'b0;
            core_expect_valid_d2 <= 1'b0;
            core_expect_valid_d3 <= 1'b0;
            core_case_id      <= 0;
        end
    endtask

    function automatic logic [1:0] rand_scloud_coeff;
        int pick;
        begin
            pick = next_rand_range(2);
            case (pick)
                0: rand_scloud_coeff = 2'b00;
                1: rand_scloud_coeff = 2'b01;
                default: rand_scloud_coeff = 2'b10;
            endcase
        end
    endfunction

    function automatic int unsigned lcg_next(input int unsigned state);
        begin
            lcg_next = (state * 32'd1664525) + 32'd1013904223;
        end
    endfunction

    function automatic int unsigned next_rand_word;
        begin
            tb_rand_state = lcg_next(tb_rand_state);
            next_rand_word = tb_rand_state;
        end
    endfunction

    function automatic int next_rand_range(input int max_value);
        begin
            next_rand_range = int'(next_rand_word() % int'(max_value + 1));
        end
    endfunction

    function automatic int ternary_int(input logic [1:0] s);
        begin
            case (s)
                2'b01: ternary_int = 1;
                2'b10: ternary_int = -1;
                default: ternary_int = 0;
            endcase
        end
    endfunction

    function automatic logic [F_W-1:0] mask_frodo(input int value);
        begin
            mask_frodo = value[F_W-1:0];
        end
    endfunction

    function automatic logic [F_W-1:0] mask_scloud(input int value);
        begin
            mask_scloud = {{(F_W-S_W){1'b0}}, value[S_W-1:0]};
        end
    endfunction

    function automatic logic [F_W-1:0] rand_word_fw;
        int unsigned tmp;
        begin
            tmp = next_rand_word();
            rand_word_fw = tmp[F_W-1:0];
        end
    endfunction

    function automatic logic [F_W-1:0] rand_word_sw_ext;
        int unsigned tmp;
        begin
            tmp = next_rand_word();
            rand_word_sw_ext = {{(F_W-S_W){1'b0}}, tmp[S_W-1:0]};
        end
    endfunction

    function automatic logic [3:0] rand_nibble;
        int unsigned tmp;
        begin
            tmp = next_rand_word();
            rand_nibble = tmp[3:0];
        end
    endfunction

    function automatic logic rand_bit;
        int unsigned tmp;
        begin
            tmp = next_rand_word();
            rand_bit = tmp[0];
        end
    endfunction

    function automatic logic [3:0] low_nibble(input int value);
        begin
            low_nibble = value[3:0];
        end
    endfunction

    function automatic logic low_bit(input int value);
        begin
            low_bit = value[0];
        end
    endfunction

    task automatic randomize_core_inputs(input logic alg, input logic op);
        int r;
        int c;
        begin
            core_alg_mode <= alg;
            core_op_mode  <= op;
            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    if (alg == ALG_FRODO) begin
                        core_a_tile[r][c] <= rand_word_fw();
                    end else begin
                        core_a_tile[r][c] <= rand_word_sw_ext();
                    end
                end
            end
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    core_frodo_s_mag[r][c]  <= rand_nibble();
                    core_frodo_s_sign[r][c] <= rand_bit();
                    core_scloud_s[r][c]     <= rand_scloud_coeff();
                    if (alg == ALG_FRODO) begin
                        core_c_acc_in[r][c] <= rand_word_fw();
                    end else begin
                        core_c_acc_in[r][c] <= rand_word_sw_ext();
                    end
                end
            end
        end
    endtask

    task automatic drive_core_fixed(input logic alg, input logic op);
        int r;
        int c;
        begin
            core_alg_mode <= alg;
            core_op_mode  <= op;
            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    core_a_tile[r][c] <= mask_frodo(32'h00000010 + (r << 4) + c);
                end
            end
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    core_frodo_s_mag[r][c]  <= low_nibble(r + c);
                    core_frodo_s_sign[r][c] <= low_bit(r + c);
                    case ((r + c) % 3)
                        0: core_scloud_s[r][c] <= 2'b00;
                        1: core_scloud_s[r][c] <= 2'b01;
                        default: core_scloud_s[r][c] <= 2'b10;
                    endcase
                    core_c_acc_in[r][c] <= mask_frodo(32'h00000100 + (r << 4) + c);
                end
            end
        end
    endtask

    task automatic compute_core_expected;
        int r;
        int c;
        int t;
        int sum;
        int prod;
        begin
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    core_expected[r][c] = core_c_acc_in[r][c];
                end
            end

            if (core_alg_mode == ALG_FRODO && core_op_mode == OP_INNER) begin
                for (r = 0; r < 2; r = r + 1) begin
                    for (c = 0; c < 2; c = c + 1) begin
                        sum = {16'h0000, core_c_acc_in[r][c]};
                        for (t = 0; t < 4; t = t + 1) begin
                            prod = core_a_tile[r][t] * core_frodo_s_mag[t][c];
                            if (core_frodo_s_sign[t][c]) begin
                                sum = sum - prod;
                            end else begin
                                sum = sum + prod;
                            end
                        end
                        core_expected[r][c] = mask_frodo(sum);
                    end
                end
            end else if (core_alg_mode == ALG_FRODO && core_op_mode == OP_OUTER) begin
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 2; c = c + 1) begin
                        sum = {16'h0000, core_c_acc_in[r][c]};
                        for (t = 0; t < 2; t = t + 1) begin
                            prod = core_a_tile[t][c] * core_frodo_s_mag[r][t];
                            if (core_frodo_s_sign[r][t]) begin
                                sum = sum - prod;
                            end else begin
                                sum = sum + prod;
                            end
                        end
                        core_expected[r][c] = mask_frodo(sum);
                    end
                end
            end else if (core_alg_mode == ALG_SCLOUD && core_op_mode == OP_INNER) begin
                for (r = 0; r < 2; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        sum = {{(32-S_W){1'b0}}, core_c_acc_in[r][c][S_W-1:0]};
                        for (t = 0; t < 4; t = t + 1) begin
                            sum = sum + ternary_int(core_scloud_s[t][c]) * core_a_tile[r][t][S_W-1:0];
                        end
                        core_expected[r][c] = mask_scloud(sum);
                    end
                end
            end else begin
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        sum = {{(32-S_W){1'b0}}, core_c_acc_in[r][c][S_W-1:0]};
                        for (t = 0; t < 2; t = t + 1) begin
                            sum = sum + ternary_int(core_scloud_s[r][t]) * core_a_tile[t][c][S_W-1:0];
                        end
                        core_expected[r][c] = mask_scloud(sum);
                    end
                end
            end
        end
    endtask

    task automatic launch_core_case(input logic alg, input logic op, input logic random_case);
        begin
            core_valid_in <= 1'b1;
            if (random_case) begin
                randomize_core_inputs(alg, op);
            end else begin
                drive_core_fixed(alg, op);
            end
            core_alg_mode <= alg;
            core_op_mode  <= op;
        end
    endtask

    task automatic capture_core_expected;
        int r;
        int c;
        begin
            compute_core_expected();
            core_expect_valid_d3 <= core_expect_valid_d2;
            core_expect_valid_d2 <= core_expect_valid_d1;
            core_expect_valid_d1 <= core_expect_valid;
            core_expect_valid    <= core_valid_in;
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    core_expected_d3[r][c] <= core_expected_d2[r][c];
                    core_expected_d2[r][c] <= core_expected_d1[r][c];
                    core_expected_d1[r][c] <= core_expected[r][c];
                end
            end
        end
    endtask

    task automatic check_core_outputs;
        int r;
        int c;
        begin
            if (core_valid_out) begin
                if (!core_expect_valid_d2) begin
                    $fatal(1, "Unexpected core_valid_out at case %0d", core_case_id);
                end
                if (core_valid_out !== 1'b1) begin
                    $fatal(1, "Core valid_out mismatch at case %0d", core_case_id);
                end
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        if (core_c_acc_out[r][c] !== core_expected_d2[r][c]) begin
                            $fatal(1, "Core mismatch case=%0d r=%0d c=%0d got=%h expected=%h",
                                   core_case_id, r, c, core_c_acc_out[r][c], core_expected_d2[r][c]);
                        end
                    end
                end
                core_case_id <= core_case_id + 1;
            end else if (core_expect_valid_d2) begin
                $fatal(1, "Missing core_valid_out at case %0d", core_case_id);
            end
        end
    endtask

    localparam int CORE_FIXED_START  = 14;
    localparam int CORE_CASE_STRIDE  = 3;
    localparam int CORE_FIXED_CYCLES = 4 * CORE_CASE_STRIDE;
    localparam int CORE_RANDOM_START = CORE_FIXED_START + CORE_FIXED_CYCLES;
    localparam int CORE_RANDOM_COUNT = 4000;
    localparam int CORE_RANDOM_CYCLES = CORE_RANDOM_COUNT * CORE_CASE_STRIDE;
    localparam int CORE_STOP_STEP    = CORE_RANDOM_START + CORE_RANDOM_CYCLES;
    localparam int CORE_DONE_STEP    = CORE_STOP_STEP + 2;

    int test_step;

    task automatic launch_core_by_index(input int case_index, input logic random_case);
        logic alg;
        logic op;
        begin
            case (case_index & 3)
                0: begin
                    alg = ALG_FRODO;
                    op  = OP_INNER;
                end
                1: begin
                    alg = ALG_SCLOUD;
                    op  = OP_INNER;
                end
                2: begin
                    alg = ALG_FRODO;
                    op  = OP_OUTER;
                end
                default: begin
                    alg = ALG_SCLOUD;
                    op  = OP_OUTER;
                end
            endcase
            launch_core_case(alg, op, random_case);
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_step   <= 0;
            alg_mode    <= ALG_FRODO;
            frodo_a     <= '0;
            frodo_mag   <= '0;
            frodo_sign  <= 1'b0;
            scloud_a_l  <= '0;
            scloud_a_h  <= '0;
            scloud_s_l  <= 2'b00;
            scloud_s_h  <= 2'b00;
            chain_in_l  <= '0;
            chain_in_h  <= '0;
            red_op_mode <= OP_INNER;
            red_p0      <= '0;
            red_p1      <= '0;
            red_p2      <= '0;
            red_p3      <= '0;
            red_sign0   <= 1'b0;
            red_sign1   <= 1'b0;
            red_sign2   <= 1'b0;
            red_sign3   <= 1'b0;
            clear_core_inputs();
        end else begin
            check_core_outputs();
            capture_core_expected();

            case (test_step)
                0: drive_frodo(16'h0003, 4'b0101, 1'b0);
                1: begin
                    drive_frodo(16'h0003, 4'b0101, 1'b0);
                end
                2: begin
                    check_frodo_outputs(16'h0003, 4'b0101, 1'b0);
                    drive_frodo(16'h1234, 4'b1111, 1'b1);
                end
                3: begin
                    drive_frodo(16'h1234, 4'b1111, 1'b1);
                end
                4: begin
                    check_frodo_outputs(16'h1234, 4'b1111, 1'b1);
                    drive_frodo(16'hf100, 4'b1000, 1'b0);
                end
                5: begin
                    drive_frodo(16'hf100, 4'b1000, 1'b0);
                end
                6: begin
                    check_frodo_outputs(16'hf100, 4'b1000, 1'b0);
                    drive_scloud(12'h001, 12'h020, 12'h003, 12'h005, 2'b01, 2'b10);
                end
                7: begin
                    check_scloud_outputs(12'h001, 12'h020, 12'h003, 12'h005, 2'b01, 2'b10);
                    drive_scloud(12'h000, 12'hfff, 12'h123, 12'h001, 2'b00, 2'b01);
                end
                8: begin
                    check_scloud_outputs(12'h000, 12'hfff, 12'h123, 12'h001, 2'b00, 2'b01);
                    drive_scloud(12'h002, 12'h100, 12'h003, 12'h200, 2'b10, 2'b11);
                end
                9: begin
                    check_scloud_outputs(12'h002, 12'h100, 12'h003, 12'h200, 2'b10, 2'b11);
                    drive_reduction(OP_INNER, 16'h0001, 16'h0002, 16'h0003, 16'h0004,
                                    1'b0, 1'b1, 1'b0, 1'b1);
                end
                10: begin
                    check_reduction_inner_outputs(16'h0001, 16'h0002, 16'h0003, 16'h0004,
                                                  1'b0, 1'b1, 1'b0, 1'b1);
                    drive_reduction(OP_INNER, 16'h8000, 16'h0001, 16'h7fff, 16'h0002,
                                    1'b1, 1'b1, 1'b0, 1'b0);
                end
                11: begin
                    check_reduction_inner_outputs(16'h8000, 16'h0001, 16'h7fff, 16'h0002,
                                                  1'b1, 1'b1, 1'b0, 1'b0);
                    drive_reduction(OP_OUTER, 16'h0010, 16'h0003, 16'h0100, 16'h0001,
                                    1'b0, 1'b1, 1'b1, 1'b0);
                end
                12: begin
                    check_reduction_outer_outputs(16'h0010, 16'h0003, 16'h0100, 16'h0001,
                                                  1'b0, 1'b1, 1'b1, 1'b0);
                    drive_reduction(OP_OUTER, 16'hffff, 16'h0001, 16'h8000, 16'h8000,
                                    1'b1, 1'b1, 1'b1, 1'b1);
                end
                13: begin
                    check_reduction_outer_outputs(16'hffff, 16'h0001, 16'h8000, 16'h8000,
                                                  1'b1, 1'b1, 1'b1, 1'b1);
                    $display("tc_reconfig and reduction_block self-test passed");
                end
                default: begin
                    if (test_step >= CORE_FIXED_START && test_step < CORE_RANDOM_START) begin
                        if (((test_step - CORE_FIXED_START) % CORE_CASE_STRIDE) == 0) begin
                            launch_core_by_index((test_step - CORE_FIXED_START) / CORE_CASE_STRIDE, 1'b0);
                        end else begin
                            core_valid_in <= 1'b0;
                        end
                    end else if (test_step >= CORE_RANDOM_START && test_step < CORE_STOP_STEP) begin
                        if (((test_step - CORE_RANDOM_START) % CORE_CASE_STRIDE) == 0) begin
                            launch_core_by_index((test_step - CORE_RANDOM_START) / CORE_CASE_STRIDE, 1'b1);
                        end else begin
                            core_valid_in <= 1'b0;
                        end
                    end else if (test_step == CORE_STOP_STEP) begin
                        core_valid_in <= 1'b0;
                    end else if (test_step == CORE_DONE_STEP) begin
                        $display("reconfig_mul_core self-test passed: %0d cases", CORE_RANDOM_COUNT + 4);
                        $finish;
                    end
                end
            endcase

            test_step <= test_step + 1;
        end
    end

endmodule
