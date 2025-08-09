#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unicorn/unicorn.h>


// --------------------- constants ---------------------
#define RAM_BASE        0x80000000UL
#define RAM_SIZE        (2 * 1024UL * 1024UL) // 2MB RAM
#define GPIO_BASE       0x10000000UL
#define GPIO_SIZE       0x1000
#define EBREAK_MC       0x00100073
#define DEBUG


typedef enum { M_IDLE = 0, M_RD, M_WR } req_mode_t;

// ---------------- globals shared with SV --------------
static volatile int req_addr, req_wdata;
static volatile req_mode_t req_write = M_IDLE; // 1=write, 0=read
static volatile unsigned char req_valid = 0;
static volatile unsigned char g_halted = 0;
static volatile int file_size = 0;


static uint8_t fw_buf[RAM_SIZE];  // host-side buffer
static uc_engine *uc;

// --------------------- forward helpers ---------------------
static void die(uc_err err, const char* msg) {
    fprintf(stderr, "%s:%s", msg, uc_strerror(err));
    exit(1);
}

// --------------------- MMIO hooks ---------------------
// in the dp-c example, both hooks are implemented in 
// SystemVerilog as automatic tasks.
// Note: the hook function signatures must match what Unicorn expects.
//When the callback's prototype is wrong, Unicorn silently ignores the hook.

static bool hook_mmio_write_unmapped(uc_engine *uc, uc_mem_type type,
    uint64_t addr, int size, int64_t value, void *user)
{
    (void)user;
    (void)value;
    (void)size;
    (void)type;

    uint64_t end = GPIO_BASE + GPIO_SIZE - 1;
    if (addr < GPIO_BASE || addr > end) return false;
    if (size != 1 && size != 2 && size != 4) return false;
    req_addr  = (int)addr;
    req_wdata = (int)value;
    req_write = M_WR;
    req_valid = 1;
    printf("[TLM GPIO] write = 0x%08X\n", (unsigned)req_wdata);
    printf("[HOOK-W] addr=%08" PRIx64 " size=%d val=%08x\n",
        addr, size, (unsigned)req_wdata);
    fflush(stdout);
    uc_emu_stop(uc);
    return true; // handled; keep running
}


// READ: two-phase — stop to let SV fetch data, then return it
static bool hook_mmio_read_unmapped(uc_engine *uc, uc_mem_type type,
    uint64_t addr, int size, int64_t value, void *user) {


        (void)user;
        (void)value;
        (void)size;
        (void)type;
    
    uint64_t end = GPIO_BASE + GPIO_SIZE - 1;
    if (addr < GPIO_BASE || addr > end) return false;
    if (size != 1 && size != 2 && size != 4) return false;
    req_addr  = (int)addr;
    req_write = M_RD;
    req_valid = 1;                // SV will call iss_set_read_data(data)
    uc_emu_stop(uc);              // stop so SV can supply data
    return true;
}


#ifdef DEBUG

static void dump_maps(uc_engine *uc) {
    uc_mem_region *regions;
    uint32_t count;
    // The uc_mem_regions() queries all of the memory regions we have previously
    // mapped into the emulated address space (via uc_mem_map() or uc_mem_map_ptr()).
    // It returns an array of uc_mem_region structs—one per mapped block—and tells us
    // how many entries there are.
    if (uc_mem_regions(uc, &regions, &count) == UC_ERR_OK) {
        for (uint32_t i = 0; i < count; i++) {
            printf("[MAP] 0x%08" PRIx64 " .. 0x%08" PRIx64 " perms=%c%c%c\n",
                   regions[i].begin, regions[i].end,
                   (regions[i].perms & UC_PROT_READ)?'R':'-',
                   (regions[i].perms & UC_PROT_WRITE)?'W':'-',
                   (regions[i].perms & UC_PROT_EXEC)?'X':'-');
        }
        uc_free(regions);
    }
}

#endif

// -----------------------------------------------------------------------------
// Load a flat binary into the RAM model
// -----------------------------------------------------------------------------
static void load_firmware(const char* path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if(!f) {
        perror("fopen");
        exit(1);
    }

    // directly dump the firmware file into the host process's virtual address 0x80000000
    *size = fread(fw_buf, 1, RAM_SIZE, f);
    fclose(f);
    if (*size == 0) {
        fprintf(stderr, "ERROR: firmware '%s' empty or unreadable\n", path);
        exit(1);
    }
    printf("Loaded %lu bytes into RAM at 0x%08lX\n", *size, (uintptr_t)RAM_BASE);
}

// --------------------- DPI functions ---------------------
void iss_init(const char *firmware_path) {

    uc_err err;
    size_t sz;

    // open uc
    err = uc_open(UC_ARCH_RISCV, UC_MODE_RISCV32, &uc);
    if(err && err != UC_ERR_OK) {
        die(err, "uc_open");
    }

    // map RAM only
    err = uc_mem_map(uc, RAM_BASE, RAM_SIZE, UC_PROT_ALL);
    if (err != UC_ERR_OK) die(err, "uc_mem_map RAM");

    // load firmware
    load_firmware(firmware_path, &sz);
    file_size = sz - 4;

    // copy firmware into Unicorn guest RAM
    // Note: we should link the firmware so that .text starts at 0x8000_0000, because:
    // In the ISS we map guest RAM at 0x8000_0000 and set PC = 0x8000_0000.
    // We then write the firmware image into Unicorn at guest address 0x8000_0000.
    // Therefore the ELF should be linked with VMA/LMA for code at that same address;
    // otherwise absolute addresses (e.g., branch targets, literal pools) won’t match
    // the location where the CPU fetches.
    err = uc_mem_write(uc, RAM_BASE, fw_buf, sz);
    if(err && err != UC_ERR_OK) {
        fprintf(stderr, "uc_mem_write: %s\n", uc_strerror(err));
        uc_close(uc);
        exit(1);
    }

    // install TLM hooks for GPIO
    uint64_t gpio_end = GPIO_BASE + GPIO_SIZE - 1;
    uc_hook h_wunmap, h_runmap;

    uc_hook_add(uc, &h_wunmap, UC_HOOK_MEM_WRITE_UNMAPPED,
        hook_mmio_write_unmapped, NULL, GPIO_BASE, gpio_end);
    
    // For read hooks on mapped memory, Unicorn expects the callback to fully supply
    // the read value iff we return true. Returning true while leaving *value unset
    // can lead to undefined engine behavior.
    uc_hook_add(uc, &h_runmap, UC_HOOK_MEM_READ_UNMAPPED,
        hook_mmio_read_unmapped,  NULL, GPIO_BASE, gpio_end);

    // set PC to RAM_BASE
    uint64_t pc = RAM_BASE;
    uc_reg_write(uc, UC_RISCV_REG_PC, (const void*)&pc);

    // set SP
    uint64_t sp = RAM_BASE + RAM_SIZE - 0x1000;
    uc_reg_write(uc, UC_RISCV_REG_SP, (const void*)&sp);

    #ifdef DEBUG
    // Read back to confirm
    uint64_t pc_rb=0, sp_rb=0;
    uc_reg_read(uc, UC_RISCV_REG_PC, &pc_rb);
    uc_reg_read(uc, UC_RISCV_REG_SP, &sp_rb);
    printf("[ISS] PC=0x%08llx SP=0x%08llx\n",
            (unsigned long long)pc_rb, (unsigned long long)sp_rb);
    #endif

    dump_maps(uc);
    printf("[ISS] init done\n");

}

void iss_ack_write_and_advance(void) {
    // clear the pending request
    req_valid = 0;
    req_write = M_IDLE;
}

void iss_step(void) {

    uint64_t pc_before=0, pc_after=0;
    uc_reg_read(uc, UC_RISCV_REG_PC, &pc_before);
    // run 1 instruction at a time
    uc_emu_start(uc, pc_before, 0, 0, 1);
    if(pc_before == file_size + RAM_BASE) {
        g_halted = 1;
    }
    // advance PC by 4
    pc_after = pc_before + 4;
    uc_reg_write(uc, UC_RISCV_REG_PC, &pc_after);
}

unsigned char iss_halted(void) {
    return g_halted ? 1 : 0;
}


// bridge between RTL GPIO module and the UC model
// signals set in the MMIO hooks are used to drive
// the GPIO RTL module signal toggling
void iss_get_req(int *addr, int *wdata, unsigned char *write) {

    *addr = req_addr;
    *wdata = req_wdata;
    *write = req_write;
}

void iss_set_read_data(int rdata) {
    req_write = M_IDLE;
    req_valid = 0;          // release/clear the pending transaction
    printf("[TLM GPIO] read -> 0x%08X\n", (unsigned)rdata);
}

void iss_finish() {

    uc_close(uc);
    printf("[ISS] finish\n");
}