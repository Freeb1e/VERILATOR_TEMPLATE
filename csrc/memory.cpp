#include "memory.h"
#include <cstdint>
#include <cstdio>
#include "config.h"

uint8_t sp_ram[RAM_SIZE] = {0};

static uint8_t* get_ram_info(int bramid, uint32_t* size_out) {
    if (bramid == 0) {
        *size_out = RAM_SIZE;
        return sp_ram;
    }
    *size_out = 0;
    return nullptr;
}

extern "C" {

void pmem_read_32(int raddr, int bramid, int* rdata) {
    uint32_t max_size = 0;
    uint8_t* mem = get_ram_info(bramid, &max_size);
    uint32_t addr = ((uint32_t)raddr) & ~0x3u;  // 32-bit aligned
    if (mem == nullptr || (addr + 4 > max_size)) {
        *rdata = 0;
        return;
    }

    uint32_t val = 0;
    val |= (uint32_t)mem[addr + 0] << 0;
    val |= (uint32_t)mem[addr + 1] << 8;
    val |= (uint32_t)mem[addr + 2] << 16;
    val |= (uint32_t)mem[addr + 3] << 24;
    *rdata = (int)val;
}

void pmem_write_32(int waddr, int bramid, int wdata, char wmask) {
    uint32_t max_size = 0;
    uint8_t* mem = get_ram_info(bramid, &max_size);
    uint32_t addr = ((uint32_t)waddr) & ~0x3u;  // 32-bit aligned
    if (mem == nullptr || (addr + 4 > max_size)) {
        return;
    }

    uint32_t data = (uint32_t)wdata;
    uint8_t  mask = (uint8_t)wmask;
    for (int i = 0; i < 4; i++) {
        if ((mask >> i) & 1) {
            mem[addr + i] = (uint8_t)((data >> (i * 8)) & 0xFF);
        }
    }
}

}  // extern "C"

bool load_bin_to_ram(const char* filename, uint8_t* ram_ptr, uint32_t max_size, uint32_t offset) {
    FILE* fp = fopen(filename, "rb");
    if (fp == nullptr) {
        printf("[DPI Error] Cannot open file: %s\n", filename);
        return false;
    }
    fseek(fp, 0, SEEK_END);
    long file_size = ftell(fp);
    rewind(fp);

    if (offset >= max_size || offset + (uint32_t)file_size > max_size) {
        printf("[DPI Error] File %s (size %ld) + offset 0x%x exceeds RAM 0x%x\n",
               filename, file_size, offset, max_size);
        fclose(fp);
        return false;
    }

    size_t result = fread(ram_ptr + offset, 1, file_size, fp);
    fclose(fp);
    if (result != (size_t)file_size) {
        printf("[DPI Error] Reading %s failed\n", filename);
        return false;
    }
    printf("[DPI Info] Loaded %s @ offset 0x%x (size %ld bytes)\n", filename, offset, file_size);
    return true;
}

bool dump_ram_to_bin(const char* filename, const uint8_t* ram_ptr, uint32_t max_size,
                     uint32_t start_offset, uint32_t write_len) {
    if (start_offset >= max_size) {
        printf("[DPI Error] Dump offset 0x%x out of RAM 0x%x\n", start_offset, max_size);
        return false;
    }

    uint32_t actual_len = write_len;
    if (write_len == 0 || (start_offset + write_len > max_size)) {
        actual_len = max_size - start_offset;
    }

    FILE* fp = fopen(filename, "wb");
    if (fp == nullptr) {
        printf("[DPI Error] Cannot open %s for writing\n", filename);
        return false;
    }

    size_t written = fwrite(ram_ptr + start_offset, 1, actual_len, fp);
    fclose(fp);
    if (written != actual_len) {
        printf("[DPI Error] Wrote %zu / %u bytes to %s\n", written, actual_len, filename);
        return false;
    }
    printf("[DPI Info] Dumped %s (offset 0x%x, len 0x%x bytes)\n", filename, start_offset, actual_len);
    return true;
}
