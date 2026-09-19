#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#include "metal_shadow.h"
#include <stdio.h>
#include <stdlib.h>

static bool shadow_enabled = false;
static bool shadow_initialized = false;
static bool shadow_failed = false;
static id<MTLCommandQueue> shadow_queue;
static id<MTLRenderPipelineState> shadow_pipeline;
static id<MTLBuffer> shadow_vertices;
static id<MTLTexture> shadow_target;
static id<MTLCommandBuffer> shadow_command;
static id<MTLRenderCommandEncoder> shadow_encoder;
static uint64_t shadow_draws;
static uint64_t shadow_frame_start;

static double shadow_now_ms(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer /
           (double)tb.denom / 1e6;
}

bool lp32_metal_shadow_enabled(void)
{
    static int value = -1;
    if (value < 0) {
        const char *option = getenv("LP32_METAL_SHADOW");
        value = option && option[0] && option[0] != '0';
        shadow_enabled = value != 0;
    }
    return shadow_enabled;
}

static bool shadow_init(void)
{
    if (shadow_initialized) return !shadow_failed;
    shadow_initialized = true;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { shadow_failed = true; return false; }
    shadow_queue = [device newCommandQueue];
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float2 p; }; struct O { float4 p [[position]]; };\n"
        "vertex O shadow_v(uint id [[vertex_id]], constant V *v [[buffer(0)]]) {"
        " O o; o.p=float4(v[id].p,0,1); return o; }\n"
        "fragment float4 shadow_f() { return float4(0.15,0.4,0.8,1); }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"shadow_v"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"shadow_f"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    shadow_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    static const float vertices[] = {-0.8f, -0.8f, 0.0f, 0.8f, 0.8f, -0.8f};
    shadow_vertices = [device newBufferWithBytes:vertices length:sizeof(vertices)
                                          options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *texture =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                            width:128 height:128 mipmapped:NO];
    texture.usage = MTLTextureUsageRenderTarget;
    shadow_target = [device newTextureWithDescriptor:texture];
    if (!shadow_queue || !library || !shadow_pipeline || !shadow_vertices || !shadow_target) {
        if (error) fprintf(stderr, "compat32: Metal shadow initialization failed: %s\n",
                           [[error localizedDescription] UTF8String]);
        shadow_failed = true;
        return false;
    }
    fprintf(stderr, "compat32: Metal shadow enabled device=%s wait=%s\n",
            [[device name] UTF8String], getenv("LP32_METAL_SHADOW_WAIT") ? "yes" : "no");
    return true;
}

void lp32_metal_shadow_draw(void)
{
    if (!lp32_metal_shadow_enabled() || shadow_failed || !shadow_init()) return;
    if (!shadow_encoder) {
        shadow_frame_start = (uint64_t)(shadow_now_ms() * 1000000.0);
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = shadow_target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        shadow_command = [shadow_queue commandBuffer];
        shadow_encoder = [shadow_command renderCommandEncoderWithDescriptor:pass];
        [shadow_encoder setRenderPipelineState:shadow_pipeline];
        [shadow_encoder setVertexBuffer:shadow_vertices offset:0 atIndex:0];
        shadow_draws = 0;
    }
    [shadow_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    ++shadow_draws;
}

void lp32_metal_shadow_end_frame(uint64_t frame)
{
    if (!shadow_encoder) return;
    [shadow_encoder endEncoding];
    [shadow_command commit];
    if (getenv("LP32_METAL_SHADOW_WAIT")) [shadow_command waitUntilCompleted];
    if (frame % 60 == 0) {
        double elapsed = shadow_now_ms() - (double)shadow_frame_start / 1000000.0;
        fprintf(stderr, "compat32: metal shadow frame=%llu draws=%llu encode_ms=%.3f wait=%s\n",
                (unsigned long long)frame, (unsigned long long)shadow_draws, elapsed,
                getenv("LP32_METAL_SHADOW_WAIT") ? "yes" : "no");
    }
    shadow_encoder = nil;
    shadow_command = nil;
}
