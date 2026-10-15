/* Development-only host: no FFmpeg or MPV link dependencies of its own.
 * Each bridge is loaded locally in both orders. Native decoding runs on its
 * owning worker while MPV creates, seeks, plays, pauses and destroys players.
 * Dependency addresses identify the images actually supplying each API. */
#include "CNativeDecoder.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    AFCDecoder *(*open)(const char *, int, char *, size_t);
    void (*close)(AFCDecoder *);
    int (*video)(AFCDecoder *, int64_t, int64_t, int64_t, uint8_t *, size_t, char *, size_t);
    int (*audio)(AFCDecoder *, int64_t, int, int, float *, size_t, char *, size_t);
    const char *source;
    const char *output;
    atomic_int *stop;
    int passed;
    int iterations;
    double completed_at[10000];
} NativeWork;

static double uptime(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static void *symbol(void *handle, const char *name) {
    void *value = dlsym(handle, name);
    if (!value) { fprintf(stderr, "Missing %s: %s\n", name, dlerror()); exit(1); }
    return value;
}

static void *load(const char *path) {
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "Cannot load %s: %s\n", path, dlerror()); exit(1); }
    return handle;
}

static void json_string(FILE *stream, const char *value) {
    fputc('"', stream);
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        if (*p == '"' || *p == '\\') fprintf(stream, "\\%c", *p);
        else if (*p < 32) fprintf(stream, "\\u%04x", *p);
        else fputc(*p, stream);
    }
    fputc('"', stream);
}

static void bindings(FILE *stream, void *handle, const char *name) {
    int (*probe)(int, unsigned *, const void **) = symbol(handle, name);
    const char *libraries[] = {"avformat", "avcodec", "avutil", "swresample", "swscale"};
    fputc('[', stream);
    for (int i = 0; i < 5; ++i) {
        unsigned version = 0;
        const void *address = NULL;
        Dl_info info = {0};
        if (probe(i, &version, &address) || !address || !dladdr(address, &info) || !info.dli_fname) {
            fputs("Cannot identify dependency binding\n", stderr); exit(1);
        }
        if (i) fputc(',', stream);
        fprintf(stream, "{\"library\":\"%s\",\"version\":%u,\"image\":", libraries[i], version);
        json_string(stream, info.dli_fname);
        fputc('}', stream);
    }
    fputc(']', stream);
}

static void *decode(void *context) {
    NativeWork *work = context;
    char error[1024] = {0}, path[4096];
    AFCDecoder *video = work->open(work->source, 0, error, sizeof(error));
    AFCDecoder *audio = work->open(work->source, 2, error, sizeof(error));
    snprintf(path, sizeof(path), "%s/native.rgb", work->output);
    FILE *picture = fopen(path, "wb");
    snprintf(path, sizeof(path), "%s/native.f32", work->output);
    FILE *sound = fopen(path, "wb");
    uint8_t rgb[320 * 180 * 3];
    float samples[1024];
    uint8_t *reference_rgb = malloc(5 * sizeof(rgb));
    float reference_samples[5][1024];
    int frames[] = {0, 36, 6, 48, 12};
    work->passed = video && audio && picture && sound && reference_rgb;
    /* Always write the same first 120 outputs for independent-process byte
     * comparison. Continue through the MPV lifecycle so concurrency is real. */
    for (int i = 0; work->passed && (i < 120 || !atomic_load(work->stop)); ++i) {
        int frame = frames[i % 5];
        if (i >= 10000 || work->video(video, frame, 24, 1, rgb, sizeof(rgb), error, sizeof(error)) ||
            work->audio(audio, frame * 2000, 1024, 48000, samples, 1024, error, sizeof(error))) {
            work->passed = 0; break;
        }
        if (i < 5) {
            memcpy(reference_rgb + i * sizeof(rgb), rgb, sizeof(rgb));
            memcpy(reference_samples[i], samples, sizeof(samples));
        } else if (memcmp(reference_rgb + (i % 5) * sizeof(rgb), rgb, sizeof(rgb)) ||
                   memcmp(reference_samples[i % 5], samples, sizeof(samples))) {
            snprintf(error, sizeof(error), "Repeated native output changed at request %d", i);
            work->passed = 0; break;
        }
        if (i < 120 && (fwrite(rgb, 1, sizeof(rgb), picture) != sizeof(rgb) ||
            fwrite(samples, 1, sizeof(samples), sound) != sizeof(samples))) {
            work->passed = 0; break;
        }
        work->iterations = i + 1;
        work->completed_at[i] = uptime();
        struct timespec delay = {.tv_nsec = 1000000};
        nanosleep(&delay, NULL);
    }
    if (!work->passed) fprintf(stderr, "Native decoding failed: %s\n", error);
    work->close(video); work->close(audio);
    free(reference_rgb);
    if (picture && fclose(picture)) work->passed = 0;
    if (sound && fclose(sound)) work->passed = 0;
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 6 || (strcmp(argv[5], "native-only") && strcmp(argv[5], "mpv-first") && strcmp(argv[5], "native-first"))) {
        fputs("Usage: host MPV-DYLIB NATIVE-DYLIB SOURCE OUTPUT native-only|mpv-first|native-first\n", stderr); return 2;
    }
    int together = strcmp(argv[5], "native-only") != 0;
    void *mpv = NULL, *native = NULL;
    if (!strcmp(argv[5], "mpv-first")) mpv = load(argv[1]);
    native = load(argv[2]);
    if (together && !mpv) mpv = load(argv[1]);
    atomic_int stop = !together;
    NativeWork work = {.open = symbol(native, "afc_decoder_open"), .close = symbol(native, "afc_decoder_close"),
        .video = symbol(native, "afc_decoder_video"), .audio = symbol(native, "afc_decoder_audio"),
        .source = argv[3], .output = argv[4], .stop = &stop};
    char path[4096];
    snprintf(path, sizeof(path), "%s/bindings.json", argv[4]);
    FILE *report = fopen(path, "w");
    if (!report) return 1;
    fputs("{\"native\":", report); bindings(report, native, "afc_native_dependencies");
    int isolated = 1;
    if (mpv) {
        fputs(",\"mpv\":", report); bindings(report, mpv, "afc_mpv_dependencies");
        /* The local MPV image must not publish its bundled FFmpeg API. */
        isolated = dlsym(mpv, "avcodec_version") == NULL && dlsym(mpv, "mpv_create") == NULL;
    }
    pthread_t worker;
    if (pthread_create(&worker, NULL, decode, &work)) { fclose(report); return 1; }
    int mpv_result = 0;
    double mpv_start = 0, mpv_end = 0;
    if (mpv) {
        int (*source_main)(int, char **) = symbol(mpv, "afc_mpv_source_main");
        snprintf(path, sizeof(path), "%s/mpv", argv[4]);
        char *arguments[] = {"mpv-source-proof", argv[3], "0", "2", path, NULL};
        mpv_start = uptime();
        mpv_result = source_main(5, arguments);
        mpv_end = uptime();
        atomic_store(&stop, 1);
    }
    pthread_join(worker, NULL);
    int overlapping_completions = 0;
    for (int i = 0; i < work.iterations; ++i)
        if (work.completed_at[i] > mpv_start && work.completed_at[i] < mpv_end) ++overlapping_completions;
    int passed = work.passed && !mpv_result && isolated && (!together || overlapping_completions > 0);
    fprintf(report, ",\"nativeIterations\":%d,\"nativeCompletionsDuringMPV\":%d,\"hiddenAPIs\":%s,\"passed\":%s}\n",
        work.iterations, overlapping_completions, isolated ? "true" : "false", passed ? "true" : "false");
    if (fclose(report)) passed = 0;
    /* Each MPV instance has been destroyed and the native worker joined before
     * closing either bridge. This is not callback-unload qualification. */
    if (mpv) dlclose(mpv);
    dlclose(native);
    return passed ? 0 : 1;
}
