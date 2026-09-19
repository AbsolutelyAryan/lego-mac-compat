#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "metal_renderer.h"
#include <mach/mach_time.h>
#include <new>
#include <string>

struct lp32_metal_renderer {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLBuffer> vertices;
    id<MTLTexture> target;
    id<MTLCommandBuffer> command;
    id<MTLRenderCommandEncoder> encoder;
    std::string device_name;
    bool wait;
    bool frame_open;
};

static double renderer_now_ms(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer /
           (double)tb.denom / 1e6;
}

static id<MTLRenderPipelineState> renderer_pipeline(id<MTLDevice> device,
                                                     id<MTLBuffer> *vertices)
{
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float2 p; }; struct O { float4 p [[position]]; };\n"
        "vertex O lp32_v(uint id [[vertex_id]], constant V *v [[buffer(0)]]) {"
        " O o; o.p=float4(v[id].p,0,1); return o; }\n"
        "fragment float4 lp32_f() { return float4(0.15,0.4,0.8,1); }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return nil;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"lp32_v"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"lp32_f"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    static const float data[] = {-0.8f, -0.8f, 0.0f, 0.8f, 0.8f, -0.8f};
    *vertices = [device newBufferWithBytes:data length:sizeof(data)
                                   options:MTLResourceStorageModeShared];
    return pipeline;
}

lp32_metal_renderer *lp32_metal_renderer_create(unsigned width, unsigned height,
                                                  bool wait_for_completion)
{
    @autoreleasepool {
        lp32_metal_renderer *renderer = new (std::nothrow) lp32_metal_renderer();
        if (!renderer) return NULL;
        renderer->device = MTLCreateSystemDefaultDevice();
        renderer->wait = wait_for_completion;
        if (!renderer->device) { delete renderer; return NULL; }
        renderer->queue = [renderer->device newCommandQueue];
        renderer->pipeline = renderer_pipeline(renderer->device, &renderer->vertices);
        MTLTextureDescriptor *texture =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                width:width height:height mipmapped:NO];
        texture.usage = MTLTextureUsageRenderTarget;
        renderer->target = [renderer->device newTextureWithDescriptor:texture];
        if (!renderer->queue || !renderer->pipeline || !renderer->vertices || !renderer->target) {
            delete renderer;
            return NULL;
        }
        renderer->device_name = [[renderer->device name] UTF8String];
        return renderer;
    }
}

void lp32_metal_renderer_destroy(lp32_metal_renderer *renderer)
{
    delete renderer;
}

const char *lp32_metal_renderer_device_name(const lp32_metal_renderer *renderer)
{
    return renderer ? renderer->device_name.c_str() : "(none)";
}

bool lp32_metal_renderer_begin_frame(lp32_metal_renderer *renderer)
{
    if (!renderer || renderer->frame_open) return false;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = renderer->target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    renderer->command = [renderer->queue commandBuffer];
    renderer->encoder = [renderer->command renderCommandEncoderWithDescriptor:pass];
    [renderer->encoder setRenderPipelineState:renderer->pipeline];
    [renderer->encoder setVertexBuffer:renderer->vertices offset:0 atIndex:0];
    renderer->frame_open = renderer->encoder != nil;
    return renderer->frame_open;
}

void lp32_metal_renderer_draw_triangle(lp32_metal_renderer *renderer)
{
    if (!renderer || !renderer->frame_open) return;
    [renderer->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

double lp32_metal_renderer_end_frame(lp32_metal_renderer *renderer)
{
    if (!renderer || !renderer->frame_open) return -1.0;
    double start = renderer_now_ms();
    [renderer->encoder endEncoding];
    [renderer->command commit];
    if (renderer->wait) [renderer->command waitUntilCompleted];
    renderer->frame_open = false;
    renderer->encoder = nil;
    renderer->command = nil;
    return renderer_now_ms() - start;
}
