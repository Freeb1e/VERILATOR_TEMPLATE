#pragma once

#include <cstdint>

#include "Vexample__Dpi.h"

extern bool load_bin_to_ram(const char* filename, uint8_t* ram_ptr, uint32_t max_size, uint32_t offset);
extern bool dump_ram_to_bin(const char* filename, const uint8_t* ram_ptr, uint32_t max_size, uint32_t start_offset, uint32_t write_len);

#define RAM_SIZE    (4 * 2048)

extern uint8_t sp_ram[RAM_SIZE]; // bramid = 0
