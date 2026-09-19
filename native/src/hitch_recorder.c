#include "hitch_recorder.h"
#include "host_diagnostics.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <mach/mach_time.h>

/* Fixed storage; no allocation, driver queries, or file writes on a draw.
 * One render-thread producer, one log writer, and a small worker-event ring.
 * At most 128 reports per session, each with 32 preceding and 8 following
 * frames. A five-second cooldown prevents sustained low FPS flooding disk. */
enum { HISTORY = 32, AFTER = 8, TOP = 3, WORKERS = 16, REPORT_LIMIT = 128,
       SUMMARY_SAMPLES = 512, SUMMARY_QUEUE = 8, PROGRAM_PAIRS = 32768 };
struct event {
    const char *name;
    uint64_t start, ns;
    uint32_t caller, vp, fp, count;
    bool first_pair;
};
struct frame {
    uint64_t swap, end, work, flush, pace, present, thread_cpu;
    uint64_t count[HITCH_KIND_COUNT], ns[HITCH_KIND_COUNT];
    struct event top[TOP];
    unsigned new_pairs;
    bool active;
};
struct report {
    struct frame frames[HISTORY + AFTER + 1];
    struct event workers[WORKERS];
    unsigned count, worker_count;
    uint64_t trigger;
};
struct summary {
    uint64_t start, end, first_swap, last_swap;
    uint64_t present[SUMMARY_SAMPLES];
    uint64_t total_present, total_work, total_flush, total_pace, total_thread_cpu;
    uint64_t max_present, max_work, max_flush, max_pace, max_thread_cpu;
    uint64_t min_target, max_target;
    uint64_t count[HITCH_KIND_COUNT], ns[HITCH_KIND_COUNT];
    unsigned frames, samples, inactive, over_150, over_200, over_300, new_pairs;
};
int hitch_recorder_enabled;
static FILE *output;
static pthread_t render_thread, writer;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready = PTHREAD_COND_INITIALIZER;
static bool stopping, queued;
static struct report pending, queue;
static struct summary current_summary, summary_queue[SUMMARY_QUEUE];
static unsigned summary_head, summary_tail, summary_dropped;
static struct frame history[HISTORY], current;
static struct event workers[WORKERS];
static uint64_t seen_program_pairs[PROGRAM_PAIRS];
static unsigned history_count, history_next, worker_next, worker_count;
static unsigned following, reports, skipped;
static uint64_t previous_end, last_trigger, threshold_ns;
static uint64_t previous_thread_cpu;
static _Thread_local uint32_t vertex_program, fragment_program;
static _Thread_local struct hitch_scope *active_scope;
static _Thread_local uint64_t frame_generation;

static bool mark_first_program_pair(uint32_t vp, uint32_t fp)
{
    uint64_t pair = ((uint64_t)vp << 32) | fp;
    if (!pair) return false;
    unsigned slot = (unsigned)((pair * 11400714819323198485ULL) >> 49);
    for (unsigned probe = 0; probe < PROGRAM_PAIRS; ++probe) {
        uint64_t seen = seen_program_pairs[slot];
        if (seen == pair) return false;
        if (!seen) { seen_program_pairs[slot] = pair; return true; }
        slot = (slot + 1) % PROGRAM_PAIRS;
    }
    return false;
}

static mach_timebase_info_data_t hitch_timebase;
__attribute__((constructor)) static void initialize_hitch_clock(void)
{
    mach_timebase_info(&hitch_timebase);
}
uint64_t hitch_now(void)
{
    /* CLOCK_UPTIME_RAW uses this same clock. Rosetta's 1:1 timebase lets us
       avoid clock_gettime's dispatch/conversion on every timed import. */
    uint64_t ticks = mach_absolute_time();
    if (hitch_timebase.numer == hitch_timebase.denom) return ticks;
    return (uint64_t)((__uint128_t)ticks * hitch_timebase.numer / hitch_timebase.denom);
}

unsigned hitch_classify(const char *name)
{
    if (*name == '_') ++name;
    /* Steam RemoteStorage uses generated C++ vtable thunks rather than libc
     * file imports, so include these in I/O attribution too. */
    if (!strncmp(name, "lp32_steam_4_", 13)) return HITCH_IO;
    if (!strncmp(name, "glDraw", 6) &&
        (strstr(name, "Elements") || strstr(name, "Arrays"))) return HITCH_DRAW;
    if (strstr(name, "TexImage") || strstr(name, "TexSubImage") ||
        strstr(name, "BufferData") || strstr(name, "BufferSubData") ||
        strstr(name, "MapBuffer") || strstr(name, "UnmapBuffer") ||
        strstr(name, "GenerateMipmap")) return HITCH_UPLOAD;
    if (!strcmp(name, "cgCreateProgram") || !strcmp(name, "cgCompileProgram") ||
        !strcmp(name, "glProgramStringARB") || !strcmp(name, "glCompileShader") ||
        !strcmp(name, "glLinkProgram")) return HITCH_SHADER;
    if (!strcmp(name, "fread") || !strcmp(name, "fwrite") ||
        !strncmp(name, "read$", 5) || !strcmp(name, "read") ||
        !strncmp(name, "pread", 5) || !strncmp(name, "pwrite", 6) ||
        !strcmp(name, "write") || !strncmp(name, "write$", 6) ||
        !strcmp(name, "fopen") || !strcmp(name, "fclose")) return HITCH_IO;
    if (!strncmp(name, "pthread_mutex_lock", 18) ||
        !strncmp(name, "pthread_cond_wait", 17) ||
        !strncmp(name, "pthread_cond_timedwait", 22) ||
        !strcmp(name, "glFinish") || !strcmp(name, "glFlush") ||
        strstr(name, "WaitSync")) return HITCH_WAIT;
    if (!strncmp(name, "AUGraph", 7) || !strcmp(name, "NewAUGraph") ||
        !strcmp(name, "DisposeAUGraph") ||
        !strncmp(name, "AudioUnit", 9) || !strncmp(name, "AudioConverter", 14) ||
        !strncmp(name, "AudioFile", 9) || !strncmp(name, "ExtAudioFile", 12)) return HITCH_AUDIO;
    if (!strncmp(name, "gl", 2) || !strncmp(name, "CGL", 3)) return HITCH_GL_STATE;
    if (!strncmp(name, "objc_", 5)) return HITCH_OBJC;
    return HITCH_RUNTIME;
}

static void write_event(const char *label, const struct event *e)
{
    fprintf(output, "  %s name=%s start=%.3f ms=%.3f caller=%08x vp=%u fp=%u count=%u first_pair=%d\n",
            label, e->name, e->start / 1e9, e->ns / 1e6,
            e->caller, e->vp, e->fp, e->count, e->first_pair);
}
static void write_report(const struct report *r)
{
    fprintf(output, "hitch trigger=%llu frames=%u\n", (unsigned long long)r->trigger, r->count);
    for (unsigned i = 0; i < r->count; ++i) {
        const struct frame *f = &r->frames[i];
        fprintf(output, " frame=%llu end=%.3f active=%d present=%.3f work=%.3f flush=%.3f pace=%.3f thread_cpu=%.3f new_pairs=%u",
                (unsigned long long)f->swap, f->end / 1e9, f->active,
                f->present / 1e6, f->work / 1e6, f->flush / 1e6, f->pace / 1e6,
                f->thread_cpu / 1e6, f->new_pairs);
        static const char *names[] = {"unknown", "none", "draw", "upload", "shader", "io", "wait", "audio", "glstate", "objc", "runtime"};
        for (unsigned k = HITCH_DRAW; k < HITCH_KIND_COUNT; ++k)
            fprintf(output, " %s=%llu/%.3f", names[k], (unsigned long long)f->count[k], f->ns[k] / 1e6);
        fputc('\n', output);
        for (unsigned j = 0; j < TOP; ++j)
            if (f->top[j].name) write_event("call", &f->top[j]);
    }
    for (unsigned i = 0; i < r->worker_count; ++i) write_event("worker", &r->workers[i]);
    fflush(output);
}
static int compare_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}
static void write_summary(struct summary *s)
{
    qsort(s->present, s->samples, sizeof(s->present[0]), compare_u64);
    uint64_t p50 = s->samples ? s->present[(s->samples - 1) * 50 / 100] : 0;
    uint64_t p95 = s->samples ? s->present[(s->samples - 1) * 95 / 100] : 0;
    uint64_t p99 = s->samples ? s->present[(s->samples - 1) * 99 / 100] : 0;
    double n = s->frames ? s->frames : 1;
    fprintf(output, "summary start=%.3f end=%.3f swaps=%llu-%llu frames=%u inactive=%u samples=%u "
            "target_min=%.3f target_max=%.3f present_avg=%.3f p50=%.3f p95=%.3f p99=%.3f max=%.3f "
            "over_150=%u over_200=%u over_300=%u new_pairs=%u work_avg=%.3f work_max=%.3f "
            "flush_avg=%.3f flush_max=%.3f pace_avg=%.3f pace_max=%.3f "
            "thread_cpu_avg=%.3f thread_cpu_max=%.3f",
            s->start / 1e9, s->end / 1e9,
            (unsigned long long)s->first_swap, (unsigned long long)s->last_swap,
            s->frames, s->inactive, s->samples,
            s->min_target / 1e6, s->max_target / 1e6,
            s->total_present / n / 1e6, p50 / 1e6, p95 / 1e6, p99 / 1e6,
            s->max_present / 1e6, s->over_150, s->over_200, s->over_300,
            s->new_pairs,
            s->total_work / n / 1e6, s->max_work / 1e6,
            s->total_flush / n / 1e6, s->max_flush / 1e6,
            s->total_pace / n / 1e6, s->max_pace / 1e6,
            s->total_thread_cpu / n / 1e6, s->max_thread_cpu / 1e6);
    static const char *names[] = {"unknown", "none", "draw", "upload", "shader", "io", "wait", "audio", "glstate", "objc", "runtime"};
    for (unsigned k = HITCH_DRAW; k < HITCH_KIND_COUNT; ++k)
        fprintf(output, " %s=%llu/%.3f", names[k],
                (unsigned long long)s->count[k], s->ns[k] / 1e6);
    fputc('\n', output);
    fflush(output);
}
static void *write_loop(void *unused)
{
    (void)unused;
    struct report local;
    struct summary local_summary;
    for (;;) {
        pthread_mutex_lock(&mutex);
        while (!queued && summary_tail == summary_head && !stopping)
            pthread_cond_wait(&ready, &mutex);
        if (!queued && summary_tail == summary_head && stopping) {
            pthread_mutex_unlock(&mutex); break;
        }
        bool has_report = queued;
        if (has_report) { local = queue; queued = false; }
        else { local_summary = summary_queue[summary_tail++ % SUMMARY_QUEUE]; }
        pthread_mutex_unlock(&mutex);
        if (has_report) write_report(&local);
        else write_summary(&local_summary);
    }
    return NULL;
}
static void enqueue_summary(void)
{
    if (!current_summary.frames && !current_summary.inactive) return;
    pthread_mutex_lock(&mutex);
    if (summary_head - summary_tail < SUMMARY_QUEUE) {
        summary_queue[summary_head++ % SUMMARY_QUEUE] = current_summary;
        pthread_cond_signal(&ready);
    } else ++summary_dropped;
    pthread_mutex_unlock(&mutex);
    memset(&current_summary, 0, sizeof(current_summary));
}
static void accumulate_summary(uint64_t target_ns)
{
    struct summary *s = &current_summary;
    if (!s->start) s->start = current.end - current.present;
    s->end = current.end;
    if (!current.active || !current.present || !target_ns) {
        ++s->inactive;
    } else {
        if (!s->frames) s->first_swap = current.swap;
        s->last_swap = current.swap;
        ++s->frames;
        if (s->samples < SUMMARY_SAMPLES) s->present[s->samples++] = current.present;
        s->total_present += current.present;
        s->total_work += current.work;
        s->total_flush += current.flush;
        s->total_pace += current.pace;
        s->total_thread_cpu += current.thread_cpu;
        if (current.present > s->max_present) s->max_present = current.present;
        if (current.work > s->max_work) s->max_work = current.work;
        if (current.flush > s->max_flush) s->max_flush = current.flush;
        if (current.pace > s->max_pace) s->max_pace = current.pace;
        if (current.thread_cpu > s->max_thread_cpu)
            s->max_thread_cpu = current.thread_cpu;
        if (!s->min_target || target_ns < s->min_target) s->min_target = target_ns;
        if (target_ns > s->max_target) s->max_target = target_ns;
        if (current.present > target_ns * 3 / 2) ++s->over_150;
        if (current.present > target_ns * 2) ++s->over_200;
        if (current.present > target_ns * 3) ++s->over_300;
        s->new_pairs += current.new_pairs;
        for (unsigned k = HITCH_DRAW; k < HITCH_KIND_COUNT; ++k) {
            s->count[k] += current.count[k]; s->ns[k] += current.ns[k];
        }
    }
    if (s->end - s->start >= 1000000000ULL || s->samples == SUMMARY_SAMPLES)
        enqueue_summary();
}
static void enqueue(void)
{
    pthread_mutex_lock(&mutex);
    if (!queued) {
        pending.worker_count = 0;
        uint64_t oldest = pending.frames[0].end - pending.frames[0].present;
        uint64_t newest = pending.frames[pending.count - 1].end;
        for (unsigned i = 0; i < worker_count; ++i) {
            const struct event *e = &workers[(worker_next + WORKERS - worker_count + i) % WORKERS];
            if (e->start <= newest && e->start + e->ns >= oldest)
                pending.workers[pending.worker_count++] = *e;
        }
        queue = pending;
        queued = true;
        ++reports;
        pthread_cond_signal(&ready);
    } else ++skipped;
    pthread_mutex_unlock(&mutex);
    pending.count = 0;
}
int hitch_start(const char *path, double threshold_ms)
{
    if (output) { errno = EALREADY; return -1; }
    output = fopen(path, "wx");
    if (!output) return -1;
    fchmod(fileno(output), 0600);
    threshold_ns = (threshold_ms >= 1 && threshold_ms <= 10000) ?
        (uint64_t)(threshold_ms * 1e6) : 25000000;
    render_thread = pthread_self();
    fprintf(output, "hitch-recorder v3 pid=%ld wall=%lld monotonic=%.3f threshold_ms=%.3f history=%d after=%d limit=%d\n"
        "CPU wall timings except thread_cpu, which is render-thread CPU time between presentations; draw time can include driver compilation or waiting, not GPU execution time.\n"
        "Category values are call-count/exclusive-ms. Work includes untimed guest work and gateway overhead; flush excludes pacing.\n"
        "Nested imports are excluded from parent timings; calls spanning presentation are omitted.\n"
        "One-second summaries exclude inactive frames. over_N counts frames above N%% of the per-frame target; percentiles are sampled if above 512 frames/window.\n",
        (long)getpid(), (long long)time(NULL), hitch_now() / 1e9, threshold_ns / 1e6,
        HISTORY, AFTER, REPORT_LIMIT);
    char host[768]; lp32_host_description(host, sizeof(host));
    fprintf(output, "%s\n", host);
    fflush(output);
    int error = pthread_create(&writer, NULL, write_loop, NULL);
    if (error) { fclose(output); output = NULL; errno = error; return -1; }
    hitch_recorder_enabled = 1;
    return 0;
}
void hitch_stop(void)
{
    if (!hitch_recorder_enabled) return;
    /* Called after guest execution stops; preserve a partially collected hitch. */
    if (pending.count) enqueue();
    enqueue_summary();
    pthread_mutex_lock(&mutex);
    stopping = true;
    pthread_cond_signal(&ready);
    pthread_mutex_unlock(&mutex);
    pthread_join(writer, NULL);
    fprintf(output, "end reports=%u skipped=%u summaries_dropped=%u\n", reports, skipped, summary_dropped);
    fclose(output);
    hitch_recorder_enabled = 0;
}
void hitch_program(uint32_t target, uint32_t program)
{
    if (target == 0x8620) vertex_program = program;
    if (target == 0x8804) fragment_program = program;
}
void hitch_scope_begin(struct hitch_scope *scope, uint64_t now)
{
    *scope = (struct hitch_scope){now, 0, frame_generation, active_scope};
    active_scope = scope;
}
void hitch_scope_end(struct hitch_scope *scope, unsigned kind, const char *name,
                     uint32_t caller, uint64_t now, uint32_t count)
{
    uint64_t elapsed = now - scope->start;
    active_scope = scope->parent;
    if (active_scope) active_scope->children += elapsed;
    if (scope->generation != frame_generation) return;
    uint64_t exclusive = elapsed > scope->children ? elapsed - scope->children : 0;
    hitch_note(kind, name, caller, scope->start, scope->start + exclusive, count);
}
void hitch_note(unsigned kind, const char *name, uint32_t caller,
                uint64_t start, uint64_t end, uint32_t draw_count)
{
    if (!hitch_recorder_enabled || kind < HITCH_DRAW || kind >= HITCH_KIND_COUNT) return;
    uint64_t ns = end - start;
    struct event e = {name, start, ns, caller, vertex_program, fragment_program, draw_count, false};
    if (!pthread_equal(pthread_self(), render_thread)) {
        if (ns < 2000000 || kind == HITCH_WAIT) return;
        pthread_mutex_lock(&mutex);
        workers[worker_next++ % WORKERS] = e;
        if (worker_count < WORKERS) ++worker_count;
        pthread_mutex_unlock(&mutex);
        return;
    }
    if (kind == HITCH_DRAW) {
        e.first_pair = mark_first_program_pair(vertex_program, fragment_program);
        if (e.first_pair) ++current.new_pairs;
    }
    ++current.count[kind]; current.ns[kind] += ns;
    for (unsigned i = 0; i < TOP; ++i) {
        if (ns > current.top[i].ns) {
            for (unsigned j = TOP - 1; j > i; --j) current.top[j] = current.top[j - 1];
            current.top[i] = e; break;
        }
    }
}
void hitch_frame(uint64_t swap, uint64_t work_end, uint64_t flush_end,
                 uint64_t present_end, uint64_t target_ns, bool active)
{
    if (!hitch_recorder_enabled) return;
    ++frame_generation;
    current.swap = swap; current.end = present_end; current.active = active;
    current.present = previous_end ? present_end - previous_end : 0;
    current.work = previous_end ? work_end - previous_end : 0;
    current.flush = flush_end - work_end;
    current.pace = present_end - flush_end;
    struct timespec cpu_time;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu_time) == 0) {
        uint64_t now_cpu = (uint64_t)cpu_time.tv_sec * 1000000000ULL +
                           (uint64_t)cpu_time.tv_nsec;
        current.thread_cpu = previous_thread_cpu ?
            now_cpu - previous_thread_cpu : 0;
        previous_thread_cpu = now_cpu;
    }
    accumulate_summary(target_ns);
    uint64_t limit = target_ns * 3 / 2;
    if (limit < threshold_ns) limit = threshold_ns;
    if (pending.count) {
        pending.frames[pending.count++] = current;
        if (!--following) enqueue();
    } else if (active && history_count == HISTORY && current.present > limit &&
               (!last_trigger || present_end - last_trigger >= 5000000000ULL) && reports < REPORT_LIMIT) {
        pending.trigger = swap;
        for (unsigned i = 0; i < history_count; ++i)
            pending.frames[pending.count++] = history[(history_next + HISTORY - history_count + i) % HISTORY];
        pending.frames[pending.count++] = current;
        following = AFTER;
        last_trigger = present_end;
    }
    history[history_next++ % HISTORY] = current;
    if (history_count < HISTORY) ++history_count;
    previous_end = present_end;
    memset(&current, 0, sizeof(current));
}
