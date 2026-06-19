你需要帮我实现一个可综合的 SystemVerilog 可重构矩阵乘单元，目标是同时支持 Frodo 和 Scloud+ 两个算法，并且同时支持内积 AS 模式和外积 SA 模式。

这个设计不是单独实现两套乘法器，而是实现一个共享的可重构 TC/PE 阵列：

- Frodo 模式：16 个 TC 实现 16 个 heavy contributions/cycle。
- Scloud+ 模式：复用每个 TC 内部的 ADD_L / ADD_H 两颗加法器，将 16 个 TC 重构为 32 个 ternary accumulation slots/cycle。
- 内积模式支持：
  Frodo:   A(2×4) × S(4×2) -> C(2×2)
  Scloud+: A(2×4) × S(4×4) -> C(2×4)
- 外积模式支持：
  Frodo:   S(4×2) × A(2×2) -> C(4×2)
  Scloud+: S(4×2) × A(2×4) -> C(4×4)

请先实现清晰、可综合、可仿真的 RTL，不要优先追求极限优化。所有模块都要参数化位宽，并写对应 testbench。

============================================================
1. 全局约定
============================================================

使用 SystemVerilog。

建议参数：

parameter F_W  = 16;  // Frodo datapath width, 可统一 16 bit
parameter S_W  = 12;  // Scloud+ datapath width, mod 2^12
parameter ACC_W = 16; // 本地 C_acc 宽度，可以先统一 16 bit

模式定义：

typedef enum logic [0:0] {
    ALG_FRODO  = 1'b0,
    ALG_SCLOUD = 1'b1
} alg_mode_t;

typedef enum logic [0:0] {
    OP_INNER = 1'b0,  // AS / inner-product style
    OP_OUTER = 1'b1   // SA / outer-product style
} op_mode_t;

Scloud+ ternary 编码：

2'b00 -> 0
2'b01 -> +1
2'b10 -> -1
2'b11 -> 保留，仿真时可当 0 或 assert 不允许出现

Frodo 的 S 系数编码：

frodo_sign: 1 bit
frodo_mag : 4 bit, 表示 |S| 的 magnitude

注意：Frodo 模式下 TC 内部不要处理 sign。TC 内部只计算 A × |S| 的无符号结果 prod_abs，sign 只作为 tag 送入后级 reduction block。

============================================================
2. 禁止使用 DSP / 乘法器
============================================================

本设计应使用 shift + mux + add 实现，不允许写通用乘法表达式。

不要写：

prod = A * mag;
acc  = acc + A * mag;

应写成：

a0 = mag[0] ? A        : 0;
a1 = mag[1] ? (A << 1) : 0;
a2 = mag[2] ? (A << 2) : 0;
a3 = mag[3] ? (A << 3) : 0;

add_l = a0 + a1;
add_h = a2 + a3;
prod_abs = add_l + add_h;

所有相关模块加属性：

(* use_dsp = "no" *)

特别是：

- tc_reconfig
- signed_pair_adder
- reduction_block
- reconfig_mul_core

综合后 DSP 使用应为 0。如果出现 DSP，请检查是否误写了 `*` 或 MAC 形式。

============================================================
3. 单个 TC 的功能
============================================================

实现模块：

module tc_reconfig #(
    parameter F_W = 16,
    parameter S_W = 12
)(
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
    output logic [S_W-1:0] chain_out_l,
    output logic [S_W-1:0] chain_out_h
);

每个 TC 内部有三类加法：

1. ADD_L
2. ADD_H
3. Tree_out = ADD_L + ADD_H

Frodo 模式下：

ADD_L = (mag[0] ? A      : 0) + (mag[1] ? A<<1 : 0)
ADD_H = (mag[2] ? A<<2   : 0) + (mag[3] ? A<<3 : 0)
frodo_prod_abs  = ADD_L + ADD_H
frodo_prod_sign = frodo_sign

Frodo 模式下 ADD_L / ADD_H / Tree_out 全部按无符号加法处理，cin=0，不处理 sign。

Scloud+ 模式下：

ADD_L 被重构成 lane L：
chain_out_l = chain_in_l + op(scloud_a_l, scloud_s_l)

ADD_H 被重构成 lane H：
chain_out_h = chain_in_h + op(scloud_a_h, scloud_s_h)

其中：

op(A,s):
    s = 00 -> 0
    s = 01 -> +A
    s = 10 -> -A = ~A + 1
    s = 11 -> 0 或 assert

实现时不要先单独生成 -A。应使用同一颗加法器的 carry-in 语义：

if s == 00:
    add_in1 = 0
    cin = 0
if s == 01:
    add_in1 = A
    cin = 0
if s == 10:
    add_in1 = ~A
    cin = 1

即：

chain_out = chain_in + add_in1 + cin

Scloud+ 模式下只保留低 S_W bit，等价于 mod 2^S_W。

注意：Scloud+ 模式下 Tree_out 不使用，ADD_L 和 ADD_H 的输出是两个不同的输出 lane，不能相加。

============================================================
4. signed_pair_adder：Frodo sign 规约的关键模块
============================================================

Frodo 的 sign 不在 TC 内部处理，而是在 reduction block 中处理。

实现模块：

module signed_pair_adder #(
    parameter W = 16
)(
    input  logic [W-1:0] p0,
    input  logic [W-1:0] p1,
    input  logic         sign0,
    input  logic         sign1,
    output logic [W-1:0] q
);

它计算：

q = (sign0 ? -p0 : p0) + (sign1 ? -p1 : p1) mod 2^W

但不要单独生成 -p0 / -p1，也不要单独使用全位宽 corr adder。

使用 pair-correction 方法：

x0 = sign0 ? ~p0 : p0
x1 = sign1 ? ~p1 : p1

pair_corr = sign0 + sign1

由于 sign0/sign1 只有 0/1，所以 pair_corr 只可能是 0,1,2，不能是 3。实现为：

pair_corr[0] = sign0 ^ sign1
pair_corr[1] = sign0 & sign1

也就是：

pair_corr = {sign0 & sign1, sign0 ^ sign1}

然后：

q = x0 + x1 + zero_extend(pair_corr)

示例 RTL 语义：

wire [W-1:0] x0 = p0 ^ {W{sign0}};
wire [W-1:0] x1 = p1 ^ {W{sign1}};
wire [1:0] pair_corr = {sign0 & sign1, sign0 ^ sign1};

assign q = x0 + x1 + {{(W-2){1'b0}}, pair_corr};

注意：
- 这样可以避免末端再加一个完整的 corr adder。
- 综合器一般会将 pair_corr 优化到低位逻辑中。
- 仍然要加 (* use_dsp = "no" *)。

============================================================
5. reduction_block：兼容 Frodo 内积和外积
============================================================

实现模块：

module reduction_block #(
    parameter W = 16
)(
    input  logic op_mode,  // OP_INNER or OP_OUTER

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

功能：

先用两个 signed_pair_adder：

q0 = signed_pair_adder(p0,p1,sign0,sign1)
q1 = signed_pair_adder(p2,p3,sign2,sign3)

如果是内积 OP_INNER：

delta0 = q0 + q1
delta1 = 0
delta1_valid = 0

这对应一个输出元素的 4 个 TC 规约：

delta0 = ±P0 ±P1 ±P2 ±P3

如果是外积 OP_OUTER：

delta0 = q0
delta1 = q1
delta1_valid = 1

这表示一个 reduction block 被拆成两个 2->1 规约半块：

delta0 = ±P0 ±P1
delta1 = ±P2 ±P3

这个设计用于 Frodo 外积：

S(4×2) × A(2×2) -> C(4×2)

一个内积 reduction block 在外积模式下拆成两个输出，因此 4 个 block 可以产生 8 个外积 delta。

============================================================
6. 顶层 reconfig_mul_core 的输入输出
============================================================

实现一个 tile-level core，不要先接外部 RAM。外部 RAM/FSM 以后再做。

module reconfig_mul_core #(
    parameter F_W = 16,
    parameter S_W = 12,
    parameter ACC_W = 16
)(
    input  logic clk,
    input  logic rst_n,
    input  logic valid_in,

    input  logic alg_mode,
    input  logic op_mode,

    // 通用 A tile，最大 2×4
    input  logic [F_W-1:0] a_tile [0:1][0:3],

    // Frodo S encoding，最大 4×4，只按模式使用子块
    input  logic [3:0]     frodo_s_mag  [0:3][0:3],
    input  logic           frodo_s_sign [0:3][0:3],

    // Scloud+ S encoding，最大 4×4
    input  logic [1:0]     scloud_s [0:3][0:3],

    // C accumulator input，统一最大 4×4
    input  logic [ACC_W-1:0] c_acc_in [0:3][0:3],

    output logic valid_out,
    output logic [ACC_W-1:0] c_acc_out [0:3][0:3]
);

说明：

c_acc_in / c_acc_out 是本地累加器输入输出，不是外部 RAM。
当前 tile 计算完成后输出更新后的 c_acc_out。
没有被当前模式使用的位置应保持原值或输出 0，要求在代码里明确处理。

使用子块：

Frodo inner:
    使用 c_acc[0:1][0:1]
Scloud+ inner:
    使用 c_acc[0:1][0:3]
Frodo outer:
    使用 c_acc[0:3][0:1]
Scloud+ outer:
    使用 c_acc[0:3][0:3]

============================================================
7. Frodo inner 映射
============================================================

模式：

alg_mode = ALG_FRODO
op_mode  = OP_INNER

计算：

A(2×4) × S(4×2) -> C(2×2)

TC 索引：

TC[r][c][t]

r = 0,1
c = 0,1
t = 0,1,2,3

每个 TC：

frodo_a    = a_tile[r][t]
frodo_mag  = frodo_s_mag[t][c]
frodo_sign = frodo_s_sign[t][c]

TC 输出：

P_t = frodo_prod_abs
s_t = frodo_prod_sign

对每个输出 C[r][c]，收集四个 TC 的 P0..P3/sign0..sign3，送入一个 reduction_block，op_mode=OP_INNER：

delta = ±P0 ±P1 ±P2 ±P3

然后：

c_acc_out[r][c] = c_acc_in[r][c] + delta

只更新：

c_acc[0][0], c_acc[0][1], c_acc[1][0], c_acc[1][1]

其他 c_acc_out 保持 c_acc_in 或置 0，建议保持 c_acc_in。

============================================================
8. Scloud+ inner 映射
============================================================

模式：

alg_mode = ALG_SCLOUD
op_mode  = OP_INNER

计算：

A(2×4) × S(4×4) -> C(2×4)

输出有 8 个元素。

映射关系：

TC[r][0][t].ADD_L -> C[r][0]
TC[r][0][t].ADD_H -> C[r][1]

TC[r][1][t].ADD_L -> C[r][2]
TC[r][1][t].ADD_H -> C[r][3]

其中：

r = 0,1
cgrp = 0,1
t = 0,1,2,3

每条输出链：

C_old -> TC[t=0] -> TC[t=1] -> mid_reg -> TC[t=2] -> TC[t=3] -> C_new

初版可以先用组合链实现功能正确：

tmp0 = C_old + op0
tmp1 = tmp0  + op1
tmp2 = tmp1  + op2
C_new = tmp2 + op3

之后可以插入 mid_reg，把链切成两段：

Stage A:
    C_old -> TC0 -> TC1 -> mid_reg

Stage B:
    mid_reg -> TC2 -> TC3 -> C_new

如果直接做流水版本，需要 valid_pipe 对齐 alg_mode/op_mode 和索引。

Scloud+ inner 更新：

c_acc_out[r][0..3]

只更新 r=0,1 的 4 列，其余保持 c_acc_in。

注意：
- Scloud+ 模式不使用 external reduction_block。
- ADD_L 和 ADD_H 的输出是两个不同列，不能相加。
- 所有结果只保留 S_W bit。如果 c_acc 是 ACC_W=16，可以将结果 zero-extend 到 ACC_W。

============================================================
9. Frodo outer 映射
============================================================

模式：

alg_mode = ALG_FRODO
op_mode  = OP_OUTER

计算：

S(4×2) × A(2×2) -> C(4×2)

输出有 8 个元素。

这里仍然使用 16 个 TC，但索引语义变为：

TC[r][c][t]

r = 0,1,2,3
c = 0,1
t = 0,1

每个 TC：

frodo_a    = a_tile[t][c]
frodo_mag  = frodo_s_mag[r][t]
frodo_sign = frodo_s_sign[r][t]

每个输出 C[r][c] 只有两个 TC：

C[r][c] += S[r][0]*A[0][c] + S[r][1]*A[1][c]

由于每个输出只有两个 TC，reduction_block 使用 OP_OUTER 拆分能力：

一个 reduction_block 输入：
    p0/sign0, p1/sign1 -> delta0
    p2/sign2, p3/sign3 -> delta1

也就是说，一个 block 外积模式输出两个 delta。

4 个 reduction_block 总共输出 8 个 delta，对应：

C[0][0], C[0][1],
C[1][0], C[1][1],
C[2][0], C[2][1],
C[3][0], C[3][1]

实现时可以自己组织 block 映射，只要功能正确即可。

更新：

c_acc_out[r][c] = c_acc_in[r][c] + delta

r=0..3, c=0..1

其余列保持 c_acc_in。

============================================================
10. Scloud+ outer 映射
============================================================

模式：

alg_mode = ALG_SCLOUD
op_mode  = OP_OUTER

计算：

S(4×2) × A(2×4) -> C(4×4)

输出有 16 个元素。

这是 Frodo outer 的吞吐翻倍版本。

每个输出只有 2 项：

C[r][j] += S[r][0]*A[0][j] + S[r][1]*A[1][j]

TC 映射：

r = 0,1,2,3
cgrp = 0,1
t = 0,1

TC[r][cgrp][t].ADD_L -> C[r][2*cgrp]
TC[r][cgrp][t].ADD_H -> C[r][2*cgrp+1]

对于 cgrp=0：
    ADD_L -> C[r][0]
    ADD_H -> C[r][1]

对于 cgrp=1：
    ADD_L -> C[r][2]
    ADD_H -> C[r][3]

A 输入：

ADD_L 使用 A[t][2*cgrp]
ADD_H 使用 A[t][2*cgrp+1]

所以：

TC[r][0][t].ADD_L uses a_tile[t][0]
TC[r][0][t].ADD_H uses a_tile[t][1]
TC[r][1][t].ADD_L uses a_tile[t][2]
TC[r][1][t].ADD_H uses a_tile[t][3]

S 输入：

scloud_s[r][t]

每条链只有两个 TC：

C_old -> TC[t=0] -> TC[t=1] -> C_new

所以 Scloud+ outer 比 Scloud+ inner 更容易闭时序。

更新：

c_acc_out[0:3][0:3]

所有 4×4 输出都更新。

============================================================
11. C_acc 与取模
============================================================

Frodo：
- 按模 2^F_W 处理。
- 统一使用低 F_W bit。
- c_acc_out = c_acc_in + delta，截断到 ACC_W/F_W。

Scloud+：
- 按模 2^S_W 处理。
- TC chain_out 只保留低 S_W bit。
- 输出到 c_acc_out 时可 zero-extend 到 ACC_W。

如果 ACC_W=16，Scloud+ 的输出写：

c_acc_out = {{(ACC_W-S_W){1'b0}}, scloud_result[S_W-1:0]}

============================================================
12. 流水建议
============================================================

第一版可以先实现组合 tile_core + 输出寄存，保证功能正确。

之后实现 3~4 级流水。

推荐 Frodo 流水：

Stage 0:
    A/S 选择与广播
    TC 内部 ADD_L / ADD_H
    TC 内部 Tree_out = ADD_L + ADD_H
    输出 P_i/sign_i

Stage 1:
    signed_pair_adder
    q0 = ±P0 ±P1
    q1 = ±P2 ±P3

Stage 2:
    inner: delta = q0 + q1
    outer: delta0 = q0, delta1 = q1

Stage 3:
    C_acc update

推荐 Scloud+ inner 流水：

Stage 0:
    C_old -> TC0 -> TC1 -> mid_reg

Stage 1:
    mid_reg -> TC2 -> TC3 -> C_new

Stage 2:
    C_acc submit / 对齐

推荐 Scloud+ outer 流水：

Stage 0:
    C_old -> TC0 -> TC1 -> C_new

Stage 1/2:
    对齐提交

要求：
- valid_in / valid_out 需要正确对齐。
- alg_mode/op_mode 需要随流水寄存。
- 若第一版先做组合，也要在注释中预留流水切分点。

============================================================
13. 测试要求
============================================================

请写 testbench，至少测试以下四种模式：

1. Frodo inner
2. Scloud+ inner
3. Frodo outer
4. Scloud+ outer

每种模式做：
- 固定小样例测试
- 随机测试至少 1000 组

随机输入范围：

Frodo:
    a_tile: random F_W-bit unsigned
    frodo_mag: random 0..15
    frodo_sign: random 0/1

Scloud+:
    a_tile: random S_W-bit unsigned，放在 a_tile 的低 S_W bit
    scloud_s: random among 00,01,10
    c_acc_in: random S_W-bit

golden model 用 SystemVerilog task/function 或 testbench 内部计算。

Frodo golden:

inner:
    for r=0..1, c=0..1:
        sum = c_acc_in[r][c]
        for t=0..3:
            prod = a_tile[r][t] * frodo_s_mag[t][c]
            if frodo_s_sign[t][c] sum -= prod
            else                  sum += prod
        expected = sum mod 2^F_W

outer:
    for r=0..3, c=0..1:
        sum = c_acc_in[r][c]
        for t=0..1:
            prod = a_tile[t][c] * frodo_s_mag[r][t]
            if frodo_s_sign[r][t] sum -= prod
            else                  sum += prod
        expected = sum mod 2^F_W

注意：testbench 里可以用 `*` 算 golden model，但 RTL 里不要用 `*`。

Scloud+ golden:

ternary_value:
    00 -> 0
    01 -> +1
    10 -> -1

inner:
    for r=0..1, c=0..3:
        sum = c_acc_in[r][c][S_W-1:0]
        for t=0..3:
            if scloud_s[t][c] == +1: sum += a_tile[r][t][S_W-1:0]
            if scloud_s[t][c] == -1: sum -= a_tile[r][t][S_W-1:0]
        expected = sum mod 2^S_W

outer:
    for r=0..3, c=0..3:
        sum = c_acc_in[r][c][S_W-1:0]
        for t=0..1:
            if scloud_s[r][t] == +1: sum += a_tile[t][c][S_W-1:0]
            if scloud_s[r][t] == -1: sum -= a_tile[t][c][S_W-1:0]
        expected = sum mod 2^S_W

要求：
- 对未使用的 c_acc_out 位置，保持等于 c_acc_in。
- 每个模式都要 assert expected == actual。
- 如果 scloud_s == 2'b11，testbench 不生成；RTL 可 assert 或当 0。

============================================================
14. 文件组织
============================================================

请生成以下文件：

rtl/
  tc_reconfig.sv
  signed_pair_adder.sv
  reduction_block.sv
  reconfig_mul_core.sv
  reconfig_defs.sv

tb/
  tb_reconfig_mul_core.sv

sim/
  run_iverilog.sh 或 run_verilator.sh

如果 SystemVerilog unpacked array 对工具不友好，可以提供 flat vector 版本接口，或者在 top wrapper 里做 flatten/unflatten。优先保证 Vivado 可综合。

============================================================
15. 代码风格要求
============================================================

- 所有组合逻辑使用 always_comb 或 assign。
- 时序逻辑使用 always_ff。
- 模块参数化，避免硬编码。
- 不要使用 `*` 实现 RTL 乘法。
- 不要推断 DSP。
- 每个模块开头写清楚功能注释。
- 对关键映射写注释，尤其是：
  - Frodo inner TC mapping
  - Scloud+ inner ADD_L/H mapping
  - Frodo outer reduction_block splitting
  - Scloud+ outer A_L/A_H column mapping
- 保证代码可读性优先。
- 第一版以功能正确为主，时序优化可以通过注释标记 pipeline cut points。

============================================================
16. 最重要的设计原则
============================================================

1. TC 内部 ADD_L / ADD_H 是核心复用资源。
2. Frodo 模式下 ADD_L/H 只生成无符号 product slice，不处理 sign。
3. Frodo sign 由 reduction_block 使用 signed_pair_adder 处理。
4. reduction_block 使用 pair-correction，不要额外引入末端全位宽 corr adder。
5. Scloud+ 模式下 ADD_L/H 直接作为两条 12-bit ternary 累加 lane。
6. Scloud+ 不使用 Frodo 外部规约树。
7. 内积与外积使用同一套 TC，只改变输入 tile 映射和输出 tile 形状。
8. 不使用 DSP，不使用通用乘法器。