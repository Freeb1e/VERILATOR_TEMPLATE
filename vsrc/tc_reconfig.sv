(* use_dsp = "no" *)
module tc_reconfig #(
    parameter int F_W = 16,
    parameter int S_W = 12
)(
    input  logic clk,
    input  logic rst_n,

    input  logic alg_mode,

    // Frodo inputs
    input  logic [F_W-1:0] frodo_a,
    input  logic [3:0]     frodo_mag,
    input  logic           frodo_sign,

    // Scloud+ inputs for two lanes
    input  logic [S_W-1:0] scloud_a_l,
    input  logic [S_W-1:0] scloud_a_h,
    input  logic [1:0]     scloud_s_l,
    input  logic [1:0]     scloud_s_h,
    input  logic [S_W-1:0] chain_in_l,
    input  logic [S_W-1:0] chain_in_h,

    // Frodo outputs
    output logic [F_W-1:0] frodo_prod_abs,
    output logic           frodo_prod_sign,

    // Scloud+ outputs
    /* verilator lint_off UNOPTFLAT */
    output logic [S_W-1:0] chain_out_l,
    output logic [S_W-1:0] chain_out_h
    /* verilator lint_on UNOPTFLAT */
);

    localparam logic ALG_FRODO  = 1'b0;
    localparam logic ALG_SCLOUD = 1'b1;

    logic [F_W-1:0] frodo_part0;
    logic [F_W-1:0] frodo_part1;
    logic [F_W-1:0] frodo_part2;
    logic [F_W-1:0] frodo_part3;
    logic [S_W-1:0] scloud_add_in_l;
    logic [S_W-1:0] scloud_add_in_h;
    logic           scloud_cin_l;
    logic           scloud_cin_h;

    logic [F_W-1:0] add_l_in0;
    logic [F_W-1:0] add_l_in1;
    logic           add_l_cin;
    logic [F_W-1:0] add_l_out;

    logic [F_W-1:0] add_h_in0;
    logic [F_W-1:0] add_h_in1;
    logic           add_h_cin;
    logic [F_W-1:0] add_h_out;

    logic [F_W-1:0] tree_out;
    logic [F_W-1:0] frodo_prod_abs_q;
    logic           frodo_prod_sign_q;

    always_comb begin
        frodo_part0 = frodo_mag[0] ? frodo_a        : '0;
        frodo_part1 = frodo_mag[1] ? (frodo_a << 1) : '0;
        frodo_part2 = frodo_mag[2] ? (frodo_a << 2) : '0;
        frodo_part3 = frodo_mag[3] ? (frodo_a << 3) : '0;
    end

    always_comb begin
        scloud_add_in_l = '0;
        scloud_cin_l    = 1'b0;

        case (scloud_s_l)
            2'b00: begin
                scloud_add_in_l = '0;
                scloud_cin_l    = 1'b0;
            end
            2'b01: begin
                scloud_add_in_l = scloud_a_l;
                scloud_cin_l    = 1'b0;
            end
            2'b10: begin
                scloud_add_in_l = ~scloud_a_l;
                scloud_cin_l    = 1'b1;
            end
            default: begin
                scloud_add_in_l = '0;
                scloud_cin_l    = 1'b0;
            end
        endcase
    end

    always_comb begin
        scloud_add_in_h = '0;
        scloud_cin_h    = 1'b0;

        case (scloud_s_h)
            2'b00: begin
                scloud_add_in_h = '0;
                scloud_cin_h    = 1'b0;
            end
            2'b01: begin
                scloud_add_in_h = scloud_a_h;
                scloud_cin_h    = 1'b0;
            end
            2'b10: begin
                scloud_add_in_h = ~scloud_a_h;
                scloud_cin_h    = 1'b1;
            end
            default: begin
                scloud_add_in_h = '0;
                scloud_cin_h    = 1'b0;
            end
        endcase
    end

    always_comb begin
        if (alg_mode == ALG_FRODO) begin
            add_l_in0 = frodo_part0;
            add_l_in1 = frodo_part1;
            add_l_cin = 1'b0;

            add_h_in0 = frodo_part2;
            add_h_in1 = frodo_part3;
            add_h_cin = 1'b0;
        end else begin
            add_l_in0 = {{(F_W-S_W){1'b0}}, chain_in_l};
            add_l_in1 = {{(F_W-S_W){1'b0}}, scloud_add_in_l};
            add_l_cin = scloud_cin_l;

            add_h_in0 = {{(F_W-S_W){1'b0}}, chain_in_h};
            add_h_in1 = {{(F_W-S_W){1'b0}}, scloud_add_in_h};
            add_h_cin = scloud_cin_h;
        end

        add_l_out = add_l_in0 + add_l_in1 + {{(F_W-1){1'b0}}, add_l_cin};
        add_h_out = add_h_in0 + add_h_in1 + {{(F_W-1){1'b0}}, add_h_cin};
        tree_out  = add_l_out + add_h_out;
    end

    always_comb begin
        frodo_prod_abs  = frodo_prod_abs_q;
        frodo_prod_sign = frodo_prod_sign_q;
        chain_out_l     = chain_in_l;
        chain_out_h     = chain_in_h;

        if (alg_mode == ALG_SCLOUD) begin
            chain_out_l = add_l_out[S_W-1:0];
            chain_out_h = add_h_out[S_W-1:0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frodo_prod_abs_q  <= '0;
            frodo_prod_sign_q <= 1'b0;
        end else if (alg_mode == ALG_FRODO) begin
            frodo_prod_abs_q  <= tree_out;
            frodo_prod_sign_q <= frodo_sign;
        end else begin
            frodo_prod_abs_q  <= frodo_prod_abs_q;
            frodo_prod_sign_q <= frodo_prod_sign_q;
        end
    end

endmodule
