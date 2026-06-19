(* use_dsp = "no" *)
module signed_pair_adder #(
    parameter int W = 16
)(
    input  logic [W-1:0] p0,
    input  logic [W-1:0] p1,
    input  logic         sign0,
    input  logic         sign1,
    output logic [W-1:0] q
);

    logic [W-1:0] x0;
    logic [W-1:0] x1;
    logic [1:0]   pair_corr;

    always_comb begin
        x0        = p0 ^ {W{sign0}};
        x1        = p1 ^ {W{sign1}};
        pair_corr = {sign0 & sign1, sign0 ^ sign1};
        q         = x0 + x1 + {{(W-2){1'b0}}, pair_corr};
    end

endmodule

(* use_dsp = "no" *)
module reduction_block #(
    parameter int W = 16
)(
    input  logic op_mode,

    input  logic [W-1:0] p0,
    input  logic [W-1:0] p1,
    input  logic [W-1:0] p2,
    input  logic [W-1:0] p3,

    input  logic sign0,
    input  logic sign1,
    input  logic sign2,
    input  logic sign3,

    output logic [W-1:0] delta0,
    output logic [W-1:0] delta1,
    output logic         delta1_valid
);

    localparam logic OP_INNER = 1'b0;
    localparam logic OP_OUTER = 1'b1;

    logic [W-1:0] tree2_q0;
    logic [W-1:0] tree2_q1;
    logic [W-1:0] tree3_q;

    signed_pair_adder #(
        .W(W)
    ) u_tree2_0 (
        .p0(p0),
        .p1(p1),
        .sign0(sign0),
        .sign1(sign1),
        .q(tree2_q0)
    );

    signed_pair_adder #(
        .W(W)
    ) u_tree2_1 (
        .p0(p2),
        .p1(p3),
        .sign0(sign2),
        .sign1(sign3),
        .q(tree2_q1)
    );

    assign tree3_q = tree2_q0 + tree2_q1;

    always_comb begin
        if (op_mode == OP_INNER) begin
            delta0       = tree3_q;
            delta1       = '0;
            delta1_valid = 1'b0;
        end else begin
            delta0       = tree2_q0;
            delta1       = tree2_q1;
            delta1_valid = 1'b1;
        end
    end

endmodule
