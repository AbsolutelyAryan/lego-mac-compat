#ifndef LP32_PERFORMANCE_HUD_H
#define LP32_PERFORMANCE_HUD_H

#include <stdint.h>

#ifdef __OBJC__
@class NSWindow;
void lp32_performance_hud_frame(NSWindow *window, uint64_t presented_ns,
                                uint64_t work_end_ns, uint64_t flush_end_ns,
                                uint64_t target_ns);
#endif

#endif
