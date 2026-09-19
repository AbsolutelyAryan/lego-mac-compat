#import <Foundation/Foundation.h>
#include "metal_renderer.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, const char **argv)
{
    unsigned draws = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : 2000;
    @autoreleasepool {
        lp32_metal_renderer *renderer =
            lp32_metal_renderer_create(128, 128, true);
        if (!renderer) {
            fprintf(stderr, "metal-renderer-probe: create failed\n");
            return 2;
        }
        double total = 0.0;
        for (unsigned frame = 0; frame < 60; ++frame) {
            if (!lp32_metal_renderer_begin_frame(renderer)) return 3;
            for (unsigned draw = 0; draw < draws; ++draw)
                lp32_metal_renderer_draw_triangle(renderer);
            total += lp32_metal_renderer_end_frame(renderer);
        }
        printf("metal-renderer-probe: device=%s draws=%u frames=60 avg_frame_ms=%.4f\n",
               lp32_metal_renderer_device_name(renderer), draws, total / 60.0);
        lp32_metal_renderer_destroy(renderer);
    }
    return 0;
}
