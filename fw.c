#include <stdint.h>

#define DATA ((volatile uint32_t *)0x10000000UL)

int main() {

    *DATA = 0xA5A5A5A5;
    *DATA = 0xB6B6B6B6;
    uint32_t x = *DATA;
    asm volatile("ebreak");
    while(1);
}