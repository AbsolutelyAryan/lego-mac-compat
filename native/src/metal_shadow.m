#include "metal_shadow.h"
#include "metal_renderer.h"
#include <stdio.h>
#include <stdlib.h>

static bool shadow_enabled;
static bool shadow_initialized;
static lp32_metal_renderer *shadow_renderer;
static uint64_t shadow_draws;

bool lp32_metal_shadow_enabled(void)
{
    static int value = -1;
    if (value < 0) {
        const char *shadow = getenv("LP32_METAL_SHADOW");
        const char *backend = getenv("LP32_METAL_BACKEND");
        value = (shadow && shadow[0] && shadow[0] != '0') ||
            (backend && backend[0] && backend[0] != '0');
        shadow_enabled = value != 0;
    }
    return shadow_enabled;
}

static bool shadow_init(void)
{
    if (shadow_initialized) return shadow_renderer != NULL;
    shadow_initialized = true;
    shadow_renderer = lp32_metal_renderer_create(
        128, 128, getenv("LP32_METAL_SHADOW_WAIT") != NULL);
    if (!shadow_renderer) {
        fprintf(stderr, "compat32: Metal backend initialization failed\n");
        return false;
    }
    fprintf(stderr, "compat32: Metal backend enabled device=%s mode=%s wait=%s\n",
            lp32_metal_renderer_device_name(shadow_renderer),
            getenv("LP32_METAL_BACKEND") ? "backend" : "shadow",
            getenv("LP32_METAL_SHADOW_WAIT") ? "yes" : "no");
    return true;
}

void lp32_metal_shadow_draw(void)
{
    if (!lp32_metal_shadow_enabled() || !shadow_init()) return;
    if (!shadow_draws && !lp32_metal_renderer_begin_frame(shadow_renderer)) return;
    lp32_metal_renderer_draw_triangle(shadow_renderer);
    ++shadow_draws;
}

void lp32_metal_shadow_end_frame(uint64_t frame)
{
    if (!shadow_draws || !shadow_renderer) return;
    double elapsed = lp32_metal_renderer_end_frame(shadow_renderer);
    if (frame % 60 == 0) {
        fprintf(stderr, "compat32: metal backend frame=%llu draws=%llu encode_ms=%.3f wait=%s\n",
                (unsigned long long)frame, (unsigned long long)shadow_draws,
                elapsed, getenv("LP32_METAL_SHADOW_WAIT") ? "yes" : "no");
    }
    shadow_draws = 0;
}
