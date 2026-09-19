#ifndef LP32_METAL_RENDERER_H
#define LP32_METAL_RENDERER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lp32_metal_renderer lp32_metal_renderer;

lp32_metal_renderer *lp32_metal_renderer_create(unsigned width, unsigned height,
                                                  bool wait_for_completion);
void lp32_metal_renderer_destroy(lp32_metal_renderer *renderer);
const char *lp32_metal_renderer_device_name(const lp32_metal_renderer *renderer);
bool lp32_metal_renderer_begin_frame(lp32_metal_renderer *renderer);
void lp32_metal_renderer_draw_triangle(lp32_metal_renderer *renderer);
double lp32_metal_renderer_end_frame(lp32_metal_renderer *renderer);

#ifdef __cplusplus
}
#endif

#endif
