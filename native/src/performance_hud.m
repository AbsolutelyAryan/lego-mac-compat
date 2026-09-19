#import "performance_hud.h"
#import <AppKit/AppKit.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <stdlib.h>
#include <string.h>

/* AppKit is touched only on the game's main/render thread. The panel is a
 * child of the game window, does not activate, and never receives mouse or
 * keyboard input. No OpenGL state, GPU query, or per-frame disk I/O is used. */
enum { FRAME_SAMPLES = 128 };
static NSPanel *panel;
static NSTextField *label;
static uint64_t last_present, window_start, last_cpu_sample;
static uint64_t frame_times[FRAME_SAMPLES], work_total, flush_total;
static unsigned frame_count, sample_count, misses;
static double previous_cpu_seconds;
static int enabled = -1;

static int compare_times(const void *left, const void *right)
{
    uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

static void ensure_panel(NSWindow *window)
{
    if (!panel) {
        panel = [[NSPanel alloc]
            initWithContentRect:NSMakeRect(0, 0, 290, 106)
                      styleMask:NSWindowStyleMaskBorderless |
                                NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered defer:NO];
        [panel setReleasedWhenClosed:NO];
        [panel setOpaque:NO];
        [panel setBackgroundColor:[[NSColor blackColor] colorWithAlphaComponent:0.72]];
        [panel setHasShadow:NO];
        [panel setIgnoresMouseEvents:YES];
        [panel setHidesOnDeactivate:YES];
        [panel setCollectionBehavior:NSWindowCollectionBehaviorFullScreenAuxiliary];
        label = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 7, 270, 92)];
        [label setBordered:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setTextColor:[NSColor whiteColor]];
        NSFont *font = [NSFont fontWithName:@"Menlo" size:11];
        [label setFont:font ? font : [NSFont systemFontOfSize:11]];
        [label setStringValue:@"Collecting frame data…"];
        [[panel contentView] addSubview:label];
        [label release];
    }
    if ([panel parentWindow] != window) {
        NSWindow *parent = [panel parentWindow];
        if (parent) [parent removeChildWindow:panel];
        [window addChildWindow:panel ordered:NSWindowAbove];
    }
    NSRect frame = [window frame];
    NSRect hud = [panel frame];
    NSPoint origin = NSMakePoint(NSMinX(frame) + 12,
                                NSMaxY(frame) - hud.size.height - 12);
    if (!NSEqualPoints([panel frame].origin, origin))
        [panel setFrameOrigin:origin];
    [panel setLevel:[window level] + 1];
    if (![panel isVisible]) [panel orderFront:nil];
}

static double process_cpu_seconds(void)
{
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

static double process_ram_gib(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info,
                  &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / 1073741824.0;
}

void lp32_performance_hud_frame(NSWindow *window, uint64_t presented_ns,
                                uint64_t work_end_ns, uint64_t flush_end_ns,
                                uint64_t target_ns)
{
    if (enabled < 0) {
        const char *option = getenv("LP32_PERF_HUD");
        enabled = !option || strcmp(option, "0") != 0;
    }
    if (!enabled || !window || ![NSThread isMainThread]) return;
    if (![NSApp isActive]) {
        if (panel && [panel isVisible]) [panel orderOut:nil];
        last_present = window_start = 0;
        frame_count = sample_count = misses = 0;
        work_total = flush_total = 0;
        return;
    }
    ensure_panel(window);
    if (!window_start) window_start = presented_ns;
    if (last_present && presented_ns > last_present) {
        uint64_t interval = presented_ns - last_present;
        if (interval > 1000000000ULL) {
            window_start = presented_ns;
            frame_count = sample_count = misses = 0;
            work_total = flush_total = 0;
        } else {
            if (sample_count < FRAME_SAMPLES) frame_times[sample_count++] = interval;
            ++frame_count;
            work_total += work_end_ns > last_present ?
                work_end_ns - last_present : 0;
            flush_total += flush_end_ns > work_end_ns ?
                flush_end_ns - work_end_ns : 0;
            if (target_ns && interval > target_ns * 3 / 2) ++misses;
        }
    }
    last_present = presented_ns;
    if (presented_ns - window_start < 500000000ULL || !frame_count) return;

    uint64_t ordered[FRAME_SAMPLES];
    memcpy(ordered, frame_times, sample_count * sizeof(uint64_t));
    qsort(ordered, sample_count, sizeof(uint64_t), compare_times);
    uint64_t p95 = sample_count ? ordered[(sample_count - 1) * 95 / 100] : 0;
    double seconds = (presented_ns - window_start) / 1e9;
    double fps = frame_count / seconds;
    double cpu_seconds = process_cpu_seconds();
    double cpu_percent = last_cpu_sample && cpu_seconds >= previous_cpu_seconds ?
        (cpu_seconds - previous_cpu_seconds) /
        ((presented_ns - last_cpu_sample) / 1e9) * 100.0 : 0.0;
    previous_cpu_seconds = cpu_seconds;
    last_cpu_sample = presented_ns;
    double ram = process_ram_gib();
    double total_ram = [NSProcessInfo processInfo].physicalMemory / 1073741824.0;
    NSString *ram_text = ram >= 0 ?
        [NSString stringWithFormat:@"%.2f / %.0f GiB", ram, total_ram] : @"n/a";
    double target_fps = target_ns ? 1e9 / target_ns : 0;
    [label setStringValue:[NSString stringWithFormat:
        @"FPS %5.1f / %.0f   p95 %5.1f ms   drops %u\n"
         "CPU %5.0f%%   RAM %@\n"
         "Render CPU %.1f ms   GL flush %.1f ms\n"
         "GPU load/VRAM: n/a (unified)",
        fps, target_fps, p95 / 1e6, misses, cpu_percent, ram_text,
        work_total / frame_count / 1e6, flush_total / frame_count / 1e6]];
    window_start = presented_ns;
    frame_count = sample_count = misses = 0;
    work_total = flush_total = 0;
}
