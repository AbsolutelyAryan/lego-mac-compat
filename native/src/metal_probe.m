#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>

static double now_seconds(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer /
           (double)tb.denom / 1e9;
}

int main(void)
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
