#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Cocoa/Cocoa.h>
#import <mach/mach_time.h>

static double now_seconds(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer /
           (double)tb.denom / 1e9;
}

static int run_present_probe(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 128, 128)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered defer:NO];
    MTKView *view = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)
                                             device:device];
    view.paused = YES;
    view.enableSetNeedsDisplay = NO;
    [window setContentView:view];
    [window orderFrontRegardless];
    [application nextEventMatchingMask:NSEventMaskAny
                              untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                 inMode:NSDefaultRunLoopMode dequeue:YES];

    const unsigned iterations = 120;
    unsigned presented = 0;
    double encode_total = 0.0;
    double complete_total = 0.0;
    for (unsigned i = 0; i < iterations; ++i) {
        id<CAMetalDrawable> drawable = [view currentDrawable];
        if (!drawable) continue;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = [drawable texture];
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.10, 0.02, 0.18, 1.0);
        double encode_start = now_seconds();
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder =
            [command renderCommandEncoderWithDescriptor:pass];
        [encoder endEncoding];
        [command presentDrawable:drawable];
        [command commit];
        double encode_end = now_seconds();
        [command waitUntilCompleted];
        double complete_end = now_seconds();
        encode_total += encode_end - encode_start;
        complete_total += complete_end - encode_end;
        ++presented;
    }
    fprintf(stdout,
            "metal-present-probe: device=%s presented=%u/%u "
            "encode_avg_ms=%.4f completion_avg_ms=%.4f\n",
            [[device name] UTF8String], presented, iterations,
            presented ? encode_total * 1000.0 / presented : 0.0,
            presented ? complete_total * 1000.0 / presented : 0.0);
    [window orderOut:nil];
    [window close];
    return presented == iterations ? 0 : 5;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "metal-probe: no Metal device\n");
            return 2;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) {
            fprintf(stderr, "metal-probe: command queue creation failed\n");
            return 3;
        }
        if (argc > 1 && strcmp(argv[1], "--present") == 0)
            return run_present_probe(device, queue);

        MTLTextureDescriptor *texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                width:128
                                                               height:128
                                                            mipmapped:NO];
        texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [device newTextureWithDescriptor:texture_descriptor];
        if (!target) {
            fprintf(stderr, "metal-probe: render target creation failed\n");
            return 4;
        }

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.10, 0.15, 1.0);

        const unsigned iterations = 120;
        double encode_total = 0.0;
        double complete_total = 0.0;
        for (unsigned i = 0; i < iterations; ++i) {
            double encode_start = now_seconds();
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLRenderCommandEncoder> encoder =
                [command renderCommandEncoderWithDescriptor:pass];
            [encoder endEncoding];
            [command commit];
            double encode_end = now_seconds();
            [command waitUntilCompleted];
            double complete_end = now_seconds();
            encode_total += encode_end - encode_start;
            complete_total += complete_end - encode_end;
        }

        fprintf(stdout,
                "metal-probe: device=%s low_power=%s iterations=%u "
                "encode_avg_ms=%.4f completion_avg_ms=%.4f\n",
                [[device name] UTF8String], [device isLowPower] ? "yes" : "no",
                iterations, encode_total * 1000.0 / iterations,
                complete_total * 1000.0 / iterations);
    }
    return 0;
}
