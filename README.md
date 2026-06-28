# Verilator Template

一个轻量的 Verilator 仿真模板，包含：

- SystemVerilog 顶层示例
- C++ 仿真入口
- FST/VCD 波形切换
- DPI-C RAM 示例
- 64-bit / 128-bit RAM 封装
- 顶层模块初始化脚本

## 目录结构

```text
.
├── csrc/
│   ├── sim.cpp        # Verilator 仿真入口
│   ├── memory.cpp     # DPI-C RAM 实现与 bin load/dump helper
│   ├── memory.h
│   └── config.h       # 仿真时间、trace 开关
├── vsrc/
│   ├── example.sv     # 默认顶层模块
│   └── TEST_MEMORY.sv # 64-bit / 128-bit RAM 模板
├── init.sh            # 创建并切换顶层模块
├── makefile
└── README.md
```

## 依赖

需要本机已安装：

```bash
verilator
make
g++
gtkwave
```

其中 `gtkwave` 只在查看波形时需要。

## 快速开始

默认使用 FST 波形格式：

```bash
make
make run
```

运行后会生成：

```text
waveform.fst
```

查看 FST 波形：

```bash
make see
```

或者：

```bash
make seefst
```

## 使用 VCD 波形

如果需要 VCD：

```bash
make makevcd
make runvcd
```

运行后会生成：

```text
waveform.vcd
```

查看 VCD 波形：

```bash
make seevcd
```

FST 是默认格式，通常文件更小、GTKWave 加载更快；VCD 兼容性更好，但文件更大。

## 清理

```bash
make clean
```

会删除 Verilator 构建目录和波形文件。

## 创建自己的顶层模块

运行：

```bash
./init.sh
```

输入新的顶层模块名，例如：

```text
my_top
```

脚本会自动完成：

- 创建 `vsrc/my_top.sv`
- 更新 `makefile` 中的 `TOP_NAME`
- 更新 `csrc` 中 Verilator 生成类相关头文件引用，例如 `Vexample.h`
- 更新 `sim.cpp` 中的 DUT 类型，例如 `Vexample *dut`

新生成的顶层默认带有：

```systemverilog
input logic clk,
input logic rst_n
```

这是因为默认的 `sim.cpp` 会驱动 `dut->clk` 和 `dut->rst_n`。

## 仿真配置

配置文件在：

```text
csrc/config.h
```

当前包含：

```cpp
#define MAX_SIM_TIME 40
#define TRACE_ON
```

- `MAX_SIM_TIME` 控制仿真运行时间
- 定义 `TRACE_ON` 时会 dump 波形
- 注释掉 `TRACE_ON` 可以关闭波形 dump

## RAM 模板

RAM 模块在：

```text
vsrc/TEST_MEMORY.sv
```

### 64-bit RAM

模块名：

```systemverilog
block_ram_64bit
```

接口：

```systemverilog
input  logic        clk,
input  logic [31:0] raddr,
input  logic [31:0] waddr,
input  logic [63:0] wdata,
input  logic [7:0]  wmask,
input  logic        wen,
output logic [63:0] rdata
```

### 128-bit RAM

模块名：

```systemverilog
block_ram_128bit
```

它由两次 64-bit RAM 访问拼接而成：

- 低 64 位访问 `addr`
- 高 64 位访问 `addr + 8`
- 下一个 128-bit word 地址再加 `16`

也就是说，一个 128-bit word 的内存布局是：

```text
addr + 0  ~ addr + 7   -> rdata[63:0]
addr + 8  ~ addr + 15  -> rdata[127:64]
```

## C++ RAM helper

DPI-C RAM 实现在：

```text
csrc/memory.cpp
```

模板默认只保留一片 example RAM：

```cpp
extern uint8_t sp_ram[RAM_SIZE];
```

对应：

```text
BRAM_ID = 0
```

### 64-bit / byte-level bin 操作

```cpp
load_bin_to_ram(filename, sp_ram, RAM_SIZE, offset);
dump_ram_to_bin(filename, sp_ram, RAM_SIZE, start_offset, write_len);
```

### 128-bit bin 操作

```cpp
load_bin_to_ram_128bit(filename, sp_ram, RAM_SIZE, offset);
dump_ram_to_bin_128bit(filename, sp_ram, RAM_SIZE, start_offset, write_len);
```

128-bit helper 会按 128-bit word 处理文件：

1. 读取当前 16 字节
2. 前 8 字节写入低 64 位地址
3. 后 8 字节写入高 64 位地址
4. 地址加 16，处理下一个 word

`offset` 和 `start_offset` 需要 16 字节对齐。如果文件大小或 dump 长度不是 16 字节倍数，会给出 warning，并允许最后一个 128-bit word 是 partial。

## 常见问题

### 编译时报找不到 `Vxxx.h`

通常是 `makefile` 中的 `TOP_NAME` 和 `csrc/sim.cpp` / `csrc/memory.h` 里的 Verilator 生成头文件名字不一致。

推荐使用：

```bash
./init.sh
```

让脚本统一更新。

### 为什么默认用 FST？

FST 是压缩波形格式，文件通常比 VCD 小很多，GTKWave 也能直接打开。模板默认使用 FST，只有在 `makevcd` / `runvcd` 时使用 VCD。

### 为什么 `.gitignore` 忽略波形和 `obj_dir_*`？

这些都是构建或仿真产物，文件可能很大，不适合提交到 GitHub。源码、脚本和配置文件才应该提交。
