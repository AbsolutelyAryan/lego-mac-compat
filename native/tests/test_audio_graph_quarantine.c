/* Exercise the real lifecycle worker with host Stop/teardown intercepted. */
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
static OSStatus fake_stop(AUGraph);
static OSStatus forbidden_teardown(AUGraph);
#define AUGraphStop fake_stop
#define AUGraphUninitialize forbidden_teardown
#define AUGraphClose forbidden_teardown
#define DisposeAUGraph forbidden_teardown
#include "../src/audio_bridge.c"

static unsigned stops;
static OSStatus stop_status;
static pthread_t test_thread;
static struct audio_callback_context context;
static OSStatus fake_stop(AUGraph graph)
{
    assert(!pthread_equal(pthread_self(), test_thread));
    assert(context.in_use && context.muted && context.owner_graph == graph);
    ++stops;
    return stop_status;
}
static OSStatus forbidden_teardown(AUGraph graph)
{
    (void)graph;
    assert(!"native teardown must never run in quarantine");
    return -1;
}
uint32_t compat_runtime32_call(uint32_t f, const uint32_t *a, size_t n)
{ (void)f; (void)a; (void)n; abort(); }
int compat_runtime32_last_call_trapped(void) { return 0; }
uint32_t compat_runtime32_allocate(size_t n, int clear)
{ (void)n; (void)clear; abort(); }
uint32_t compat_runtime32_reallocate(uint32_t p, size_t n)
{ (void)p; (void)n; abort(); }
void compat_runtime32_deallocate(uint32_t p) { (void)p; abort(); }
const struct lp32_game_profile *lp32_profile(void)
{ static struct lp32_game_profile profile; return &profile; }

int main(void)
{
    setenv("LP32_QUARANTINE_AUDIO_GRAPHS", "1", 1);
    unsetenv("LP32_SYNC_AUDIO_TEARDOWN");
    unsetenv("LP32_NO_AUDIO_GRAPH_POOL");
    assert(quarantine_audio_graphs());
    assert(!synchronous_audio_teardown());
    assert(graph_pool_enabled());
    test_thread = pthread_self();
    AUGraph graph = (AUGraph)(uintptr_t)0x123400;
    pthread_mutex_init(&context.lock, NULL);
    context.in_use = true;
    context.muted = true;
    context.owner_graph = graph;
    audio_callbacks[0] = &context;
    audio_callback_count = 1;
    enqueue_graph_teardown(graph, kDeferredGraphUninitialize, NULL);
    enqueue_graph_teardown(graph, kDeferredGraphClose, NULL);
    drain_deferred_graph_work(graph, false);
    assert(stops == 2 && context.in_use);
    stop_status = -1;
    enqueue_graph_teardown(graph, kDeferredGraphDispose, NULL);
    drain_deferred_graph_work(graph, false);
    assert(stops == 3 && context.in_use); /* Failed Stop cannot free refcon. */
    stop_status = noErr;
    enqueue_graph_teardown(graph, kDeferredGraphDispose, NULL);
    drain_deferred_graph_work(graph, false);
    assert(stops == 4 && !context.in_use);
    puts("Audio graph quarantine PASS (async, pooled, safe callback retirement)");
    return 0;
}
