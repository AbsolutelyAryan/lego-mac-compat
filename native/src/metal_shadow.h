#ifndef LP32_METAL_SHADOW_H
#define LP32_METAL_SHADOW_H

#include <stdbool.h>
#include <stdint.h>

bool lp32_metal_shadow_enabled(void);
void lp32_metal_shadow_draw(void);
void lp32_metal_shadow_end_frame(uint64_t frame);

#endif
