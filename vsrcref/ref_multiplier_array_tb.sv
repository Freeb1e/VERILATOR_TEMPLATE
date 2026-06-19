/* verilator lint_off STMTDLY */
/* verilator lint_off INFINITELOOP */
module ref_multiplier_array_tb;

    localparam int F_W   = 16;
    localparam int S_W   = 12;
    localparam int ACC_W = 16;

    localparam logic ALG_FRODO  = 1'b0;
    localparam logic ALG_SCLOUD = 1'b1;
    localparam logic OP_INNER   = 1'b0;
    localparam logic OP_OUTER   = 1'b1;

    logic clk;
    logic rst_n;
    logic valid_in;
    logic alg_mode;
    logic op_mode;
    logic valid_out;

    logic [F_W-1:0]   a_tile [0:1][0:3];
    logic [3:0]       frodo_s_mag [0:3][0:3];
    logic             frodo_s_sign [0:3][0:3];
    logic [1:0]       scloud_s [0:3][0:3];
    logic [ACC_W-1:0] c_acc_in [0:3][0:3];
    logic [ACC_W-1:0] c_acc_out [0:3][0:3];
    logic [ACC_W-1:0] expected [0:3][0:3];

    ref_multiplier_array_core #(
        .F_W(F_W),
        .S_W(S_W),
        .ACC_W(ACC_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .alg_mode(alg_mode),
        .op_mode(op_mode),
        .a_tile(a_tile),
        .frodo_s_mag(frodo_s_mag),
        .frodo_s_sign(frodo_s_sign),
        .scloud_s(scloud_s),
        .c_acc_in(c_acc_in),
        .valid_out(valid_out),
        .c_acc_out(c_acc_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic int ternary_int(input logic [1:0] s);
        begin
            case (s)
                2'b01: ternary_int = 1;
                2'b10: ternary_int = -1;
                default: ternary_int = 0;
            endcase
        end
    endfunction

    task automatic fill_inputs;
        int r;
        int c;
        begin
            for (r = 0; r < 2; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    a_tile[r][c] = F_W'(32'h00000010 + (r << 4) + c);
                end
            end

            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    frodo_s_mag[r][c]  = 4'((r + c + 1) & 15);
                    frodo_s_sign[r][c] = logic'((r + c) & 1);
                    case ((r + c) % 3)
                        0: scloud_s[r][c] = 2'b00;
                        1: scloud_s[r][c] = 2'b01;
                        default: scloud_s[r][c] = 2'b10;
                    endcase
                    c_acc_in[r][c] = ACC_W'(32'h00000100 + (r << 4) + c);
                end
            end
        end
    endtask

    task automatic compute_expected;
        int r;
        int c;
        int t;
        int sum;
        int prod;
        begin
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    expected[r][c] = c_acc_in[r][c];
                end
            end

            if (alg_mode == ALG_FRODO && op_mode == OP_INNER) begin
                for (r = 0; r < 2; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        sum = int'(c_acc_in[r][c]);
                        for (t = 0; t < 4; t = t + 1) begin
                            prod = a_tile[r][t] * frodo_s_mag[t][c];
                            sum = frodo_s_sign[t][c] ? (sum - prod) : (sum + prod);
                        end
                        expected[r][c] = sum[F_W-1:0];
                    end
                end
            end else if (alg_mode == ALG_FRODO && op_mode == OP_OUTER) begin
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        sum = int'(c_acc_in[r][c]);
                        for (t = 0; t < 2; t = t + 1) begin
                            prod = a_tile[t][c] * frodo_s_mag[r][t];
                            sum = frodo_s_sign[r][t] ? (sum - prod) : (sum + prod);
                        end
                        expected[r][c] = sum[F_W-1:0];
                    end
                end
            end else if (alg_mode == ALG_SCLOUD && op_mode == OP_INNER) begin
                for (r = 0; r < 2; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        sum = int'(c_acc_in[r][c][S_W-1:0]);
                        for (t = 0; t < 4; t = t + 1) begin
                            sum = sum + ternary_int(scloud_s[t][c]) * a_tile[r][t][S_W-1:0];
                        end
                        expected[r][c] = {{(ACC_W-S_W){1'b0}}, sum[S_W-1:0]};
                    end
                end
            end else begin
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        sum = int'(c_acc_in[r][c][S_W-1:0]);
                        for (t = 0; t < 2; t = t + 1) begin
                            sum = sum + ternary_int(scloud_s[r][t]) * a_tile[t][c][S_W-1:0];
                        end
                        expected[r][c] = {{(ACC_W-S_W){1'b0}}, sum[S_W-1:0]};
                    end
                end
            end
        end
    endtask

    task automatic prepare_case(input logic alg, input logic op);
        begin
            alg_mode = alg;
            op_mode = op;
            compute_expected();
            valid_in = 1'b1;
        end
    endtask

    task automatic check_case(input logic alg, input logic op);
        int r;
        int c;
        begin
            valid_in = 1'b0;

            if (valid_out !== 1'b1) begin
                $fatal(1, "valid_out mismatch");
            end

            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    if (c_acc_out[r][c] !== expected[r][c]) begin
                        $fatal(1, "case alg=%0b op=%0b r=%0d c=%0d got=%h expected=%h",
                               alg, op, r, c, c_acc_out[r][c], expected[r][c]);
                    end
                end
            end
        end
    endtask

    initial begin
        rst_n    = 1'b0;
        valid_in = 1'b0;
        alg_mode = ALG_FRODO;
        op_mode  = OP_INNER;
        fill_inputs();

        #21;
        rst_n = 1'b1;

        prepare_case(ALG_FRODO, OP_INNER);
        #30;
        check_case(ALG_FRODO, OP_INNER);

        #10;
        prepare_case(ALG_SCLOUD, OP_INNER);
        #30;
        check_case(ALG_SCLOUD, OP_INNER);

        #10;
        prepare_case(ALG_FRODO, OP_OUTER);
        #30;
        check_case(ALG_FRODO, OP_OUTER);

        #10;
        prepare_case(ALG_SCLOUD, OP_OUTER);
        #30;
        check_case(ALG_SCLOUD, OP_OUTER);

        $display("ref_multiplier_array_core self-test passed");
        $finish;
    end

endmodule
/* verilator lint_on INFINITELOOP */
/* verilator lint_on STMTDLY */
