// Xilinx-style True Dual-Port (TDP) Block RAM wrapper, DPI-C backed.
//
// Port naming matches Vivado "Block Memory Generator" IP so this module can
// be swapped 1:1 with the generated `xpm_memory_tdpram` / `blk_mem_gen` IP:
//
//   .clka / .clkb   - port A / B clock
//   .ena  / .enb    - port A / B enable
//   .wea  / .web    - port A / B byte-wide write enable
//   .addra/ .addrb  - port A / B word address (NOT byte address)
//   .dina / .dinb   - port A / B write data
//   .douta/ .doutb  - port A / B read data (registered)
//
// Read behaviour follows the Vivado default "Write First" mode: on a write
// cycle, dout reflects the just-written value at that address. When the
// enable is low the read output is held.

// ============================================================
// 32-bit True Dual-Port BRAM
// Matches Vivado IP instantiation template exactly:
//   ram32_0 your_instance_name (
//     .clka(clka), .ena(ena), .wea(wea), .addra(addra), .dina(dina), .douta(douta),
//     .clkb(clkb), .enb(enb), .web(web), .addrb(addrb), .dinb(dinb), .doutb(doutb)
//   );
// ============================================================
module block_ram_32bit #(
    parameter int BRAM_ID    = 0,
    parameter int ADDR_WIDTH = 11   // 2^11 * 4B = 8KB by default
)(
    // Port A
    input  logic                    clka,
    input  logic                    ena,
    input  logic [3:0]              wea,    // byte-write enable [3:0]
    input  logic [ADDR_WIDTH-1:0]   addra,
    input  logic [31:0]             dina,
    output logic [31:0]             douta,
    // Port B
    input  logic                    clkb,
    input  logic                    enb,
    input  logic [3:0]              web,
    input  logic [ADDR_WIDTH-1:0]   addrb,
    input  logic [31:0]             dinb,
    output logic [31:0]             doutb
);

    import "DPI-C" function void pmem_read_32 (input int raddr, input int bramid, output int rdata);
    import "DPI-C" function void pmem_write_32(input int waddr, input int bramid, input  int wdata, input byte wmask);

    // Word address -> byte address (32-bit word == 4 bytes)
    logic [ADDR_WIDTH+1:0] byte_addra;
    logic [ADDR_WIDTH+1:0] byte_addrb;
    assign byte_addra = {addra, 2'b00};
    assign byte_addrb = {addrb, 2'b00};

    int rdata_a_temp;
    int rdata_b_temp;

    // Port A
    always @(posedge clka) begin
        if (ena) begin
            if (|wea) begin
                pmem_write_32(int'(byte_addra), BRAM_ID, int'(dina), byte'(wea));
            end
            pmem_read_32(int'(byte_addra), BRAM_ID, rdata_a_temp);
            douta <= rdata_a_temp[31:0];
        end
    end

    // Port B
    always @(posedge clkb) begin
        if (enb) begin
            if (|web) begin
                pmem_write_32(int'(byte_addrb), BRAM_ID, int'(dinb), byte'(web));
            end
            pmem_read_32(int'(byte_addrb), BRAM_ID, rdata_b_temp);
            doutb <= rdata_b_temp[31:0];
        end
    end

endmodule
