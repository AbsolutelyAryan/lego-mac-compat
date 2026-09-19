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

static id<MTLRenderPipelineState> make_probe_pipeline(id<MTLDevice> device,
                                                       id<MTLBuffer> *vertices)
{
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float2 p; }; struct O { float4 p [[position]]; };\n"
        "vertex O probe_v(uint id [[vertex_id]], constant V *v [[buffer(0)]]) {"
        " O o; o.p=float4(v[id].p,0,1); return o; }\n"
        "fragment float4 probe_f() { return float4(0.2,0.5,0.9,1); }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) {
        fprintf(stderr, "metal-probe: shader compile failed: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"probe_v"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"probe_f"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor
                                                                                    error:&error];
    if (!pipeline) {
        fprintf(stderr, "metal-probe: pipeline creation failed: %s\n",
                [[error localizedDescription] UTF8String]);
        return nil;
    }
    static const float data[] = {-0.8f, -0.8f, 0.0f, 0.8f, 0.8f, -0.8f};
    *vertices = [device newBufferWithBytes:data length:sizeof(data)
                                   options:MTLResourceStorageModeShared];
    return pipeline;
}

static int run_stress_probe(id<MTLDevice> device, id<MTLCommandQueue> queue,
                            unsigned draws)
{
    id<MTLBuffer> vertices = nil;
    id<MTLRenderPipelineState> pipeline = make_probe_pipeline(device, &vertices);
    if (!pipeline || !vertices) return 6;
    MTLTextureDescriptor *texture_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                            width:128 height:128 mipmapped:NO];
    texture_descriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [device newTextureWithDescriptor:texture_descriptor];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    const unsigned frames = 60;
    double total = 0.0;
    for (unsigned frame = 0; frame < frames; ++frame) {
        double start = now_seconds();
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        [encoder setVertexBuffer:vertices offset:0 atIndex:0];
        for (unsigned draw = 0; draw < draws; ++draw)
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        total += now_seconds() - start;
    }
    fprintf(stdout, "metal-stress-probe: device=%s draws=%u frames=%u avg_frame_ms=%.4f\n",
            [[device name] UTF8String], draws, frames, total * 1000.0 / frames);
    return 0;
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
        if (argc > 1 && strcmp(argv[1], "--stress") == 0) {
            unsigned draws = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 10) : 2000;
            return run_stress_probe(device, queue, draws);
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
