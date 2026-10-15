/* Development-only source libmpv lifecycle/seek proof.
 * Usage: mpv-source-proof <source-path> <video-ff-index|-1>
 *                         <audio-ff-index|-1> <output-directory>
 * The caller supplies a local >=3 second fixture and a fresh output directory.
 * vo=null + screenshot-raw captures decoded picture without requiring encoders;
 * ao=null does NOT qualify CoreAudio or live sync.
 * No timeline graph, proxy composition, app packaging or sandbox grant is tested.
 */
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <errno.h>
#include <math.h>

static FILE *report;
static const char *failure;
static void log_event(mpv_event *e) {
    if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
        mpv_event_log_message *log = e->data;
        fprintf(stderr, "[%s/%s] %s", log->prefix, log->level, log->text);
    }
}
static double clock_seconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void json_string(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { fputc('\\', f); fputc(c, f); }
        else if (c < 32) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}
static void json_node(FILE *f, const mpv_node *n) {
    switch (n->format) {
    case MPV_FORMAT_STRING: json_string(f, n->u.string); break;
    case MPV_FORMAT_FLAG: fputs(n->u.flag ? "true" : "false", f); break;
    case MPV_FORMAT_INT64: fprintf(f, "%lld", (long long)n->u.int64); break;
    case MPV_FORMAT_DOUBLE: fprintf(f, "%.17g", n->u.double_); break;
    case MPV_FORMAT_NODE_ARRAY: case MPV_FORMAT_NODE_MAP: {
        int map = n->format == MPV_FORMAT_NODE_MAP;
        fputc(map ? '{' : '[', f);
        for (int i = 0; i < n->u.list->num; i++) {
            if (i) fputc(',', f);
            if (map) { json_string(f, n->u.list->keys[i]); fputc(':', f); }
            json_node(f, &n->u.list->values[i]);
        }
        fputc(map ? '}' : ']', f); break;
    }
    default: fputs("null", f);
    }
}
/* Retain the runtime's interpretation of color/chroma metadata. Missing
 * optional diagnostics stay null; they never change the pixel verdict. */
static void json_property(FILE *f, mpv_handle *m, const char *name) {
    mpv_node value = {0};
    if (mpv_get_property(m, name, MPV_FORMAT_NODE, &value) >= 0) {
        json_node(f, &value);
        mpv_free_node_contents(&value);
    } else {
        fputs("null", f);
    }
}
static const mpv_node *field(const mpv_node *n, const char *key) {
    if (n->format != MPV_FORMAT_NODE_MAP) return NULL;
    for (int i = 0; i < n->u.list->num; i++)
        if (!strcmp(n->u.list->keys[i], key)) return &n->u.list->values[i];
    return NULL;
}
static int check(int rc, const char *what) {
    if (rc >= 0) return 1;
    fprintf(stderr, "%s: %s\n", what, mpv_error_string(rc)); failure = what; return 0;
}
static int command(mpv_handle *m, const char **args) {
    return check(mpv_command(m, args), args[0]);
}
static int drain(mpv_handle *m) {
    double end = clock_seconds() + 1;
    while (clock_seconds() < end) {
        mpv_event *e = mpv_wait_event(m, 0); log_event(e);
        if (e->event_id == MPV_EVENT_NONE) return 1;
    }
    failure = "event drain deadline exceeded"; return 0;
}
static int wait_event(mpv_handle *m, mpv_event_id expected) {
    double end = clock_seconds() + 10;
    while (clock_seconds() < end) {
        mpv_event *e = mpv_wait_event(m, 0.1);
        log_event(e);
        if (e->event_id == expected) return 1;
        if (e->event_id == MPV_EVENT_SHUTDOWN || e->event_id == MPV_EVENT_END_FILE) {
            failure = "unexpected playback termination"; return 0;
        }
    }
    failure = "event deadline exceeded"; return 0;
}
static void pump(mpv_handle *m, double seconds) {
    double end = clock_seconds() + seconds;
    while (clock_seconds() < end) log_event(mpv_wait_event(m, 0.01));
}
static int position(mpv_handle *m, double *value) {
    if (!check(mpv_get_property(m, "time-pos", MPV_FORMAT_DOUBLE, value), "time-pos")) return 0;
    if (!isfinite(*value)) { failure = "nonfinite time-pos"; return 0; }
    return 1;
}
static int resolve(mpv_handle *m, int video, int audio, int64_t *vid, int64_t *aid, const char *output, int cycle) {
    mpv_node list = {0};
    if (!check(mpv_get_property(m, "track-list", MPV_FORMAT_NODE, &list), "track-list")) return 0;
    char path[4096]; snprintf(path, sizeof(path), "%s/cycle-%d-tracks.json", output, cycle);
    FILE *f = fopen(path, "w");
    if (!f) { mpv_free_node_contents(&list); failure = "write track list"; return 0; }
    json_node(f, &list); fputc('\n', f); fclose(f);
    int vc = 0, ac = 0;
    if (list.format == MPV_FORMAT_NODE_ARRAY) for (int i = 0; i < list.u.list->num; i++) {
        const mpv_node *track = &list.u.list->values[i];
        const mpv_node *kind = field(track, "type"), *index = field(track, "ff-index"), *id = field(track, "id");
        if (!kind || kind->format != MPV_FORMAT_STRING || !index || index->format != MPV_FORMAT_INT64 || !id || id->format != MPV_FORMAT_INT64 || id->u.int64 <= 0) continue;
        if (video >= 0 && !strcmp(kind->u.string, "video") && index->u.int64 == video) { *vid = id->u.int64; vc++; }
        if (audio >= 0 && !strcmp(kind->u.string, "audio") && index->u.int64 == audio) { *aid = id->u.int64; ac++; }
    }
    mpv_free_node_contents(&list);
    if ((video >= 0 && vc != 1) || (audio >= 0 && ac != 1)) { failure = "missing or ambiguous container stream identity"; return 0; }
    return 1;
}
static int select_track(mpv_handle *m, const char *name, int64_t id) {
    char value[64]; if (id < 0) strcpy(value, "no"); else snprintf(value, sizeof(value), "%lld", (long long)id);
    return check(mpv_set_property_string(m, name, value), name);
}
static int verify_track(mpv_handle *m, const char *name, int64_t expected) {
    if (expected < 0) {
        char *value = mpv_get_property_string(m, name);
        int ok = value && !strcmp(value, "no"); mpv_free(value);
        if (!ok) failure = "disabled track unexpectedly selected";
        return ok;
    }
    int64_t actual = 0;
    if (!check(mpv_get_property(m, name, MPV_FORMAT_INT64, &actual), name)) return 0;
    if (actual != expected) { failure = "runtime selected track differs"; return 0; }
    return 1;
}
static int parse_index(const char *s, int *out) {
    char *end; errno = 0; long n = strtol(s, &end, 10);
    if (errno || *end || !*s || n < -1 || n > 2147483647) return 0;
    *out = (int)n; return 1;
}
static int capture_rgb(mpv_handle *m, const char *path) {
    mpv_node result = {0};
    const char *args[] = {"screenshot-raw", "video", "bgr0", NULL};
    if (!check(mpv_command_ret(m, args, &result), "screenshot-raw")) return 0;
    const mpv_node *w = field(&result, "w"), *h = field(&result, "h"), *stride = field(&result, "stride"), *format = field(&result, "format"), *data = field(&result, "data");
    int ok = w && w->format == MPV_FORMAT_INT64 && w->u.int64 > 0 && w->u.int64 <= 4096 &&
             h && h->format == MPV_FORMAT_INT64 && h->u.int64 > 0 && h->u.int64 <= 4096 &&
             stride && stride->format == MPV_FORMAT_INT64 && stride->u.int64 >= w->u.int64 * 4 &&
             format && format->format == MPV_FORMAT_STRING && !strcmp(format->u.string, "bgr0") &&
             data && data->format == MPV_FORMAT_BYTE_ARRAY && data->u.ba && data->u.ba->data &&
             stride->u.int64 <= (int64_t)(data->u.ba->size / h->u.int64);
    if (ok) {
        FILE *f = fopen(path, "wb");
        if (!f) ok = 0;
        else {
            for (int64_t y = 0; y < h->u.int64 && ok; y++) {
                const unsigned char *row = (const unsigned char *)data->u.ba->data + y * stride->u.int64;
                for (int64_t x = 0; x < w->u.int64; x++) {
                    unsigned char rgb[] = {row[x * 4 + 2], row[x * 4 + 1], row[x * 4]};
                    if (fwrite(rgb, 1, 3, f) != 3) { ok = 0; break; }
                }
            }
            if (fclose(f)) ok = 0;
        }
    }
    mpv_free_node_contents(&result);
    if (!ok) failure = "invalid or unwritable raw screenshot";
    return ok;
}
int main(int argc, char **argv) {
    int video, audio, passed = 1;
    if (argc != 5 || !parse_index(argv[2], &video) || !parse_index(argv[3], &audio) || (video < 0 && audio < 0)) {
        fprintf(stderr, "Usage: %s source video-ff-index|-1 audio-ff-index|-1 new-output-directory\n", argv[0]); return 2;
    }
    struct stat source_stat;
    if (argv[1][0] != '/' || argv[4][0] != '/' || strlen(argv[4]) > 3900 ||
        stat(argv[1], &source_stat) || !S_ISREG(source_stat.st_mode)) {
        fprintf(stderr, "Supply an absolute local source file and a new absolute output directory (path <=3900 bytes).\n"); return 2;
    }
    if (mkdir(argv[4], 0700) != 0) { perror("new output directory"); return 2; }
    char path[4096]; snprintf(path, sizeof(path), "%s/report.json", argv[4]);
    report = fopen(path, "w"); if (!report) { perror("report"); return 2; }
    fputs("{\"cycles\":[", report);
    for (int cycle = 0; cycle < 4 && passed; cycle++) {
        mpv_handle *m = mpv_create(); int64_t vid = -1, aid = -1;
        int capture_count = 0;
        if (cycle) fputc(',', report);
        fprintf(report, "{\"index\":%d", cycle);
        if (!m) { failure = "mpv_create"; passed = 0; goto finish_cycle; }
        /* Includes linked FFmpeg versions and the actual software screenshot
         * scaler, which are necessary to diagnose conversion differences. */
        mpv_request_log_messages(m, "v");
#define OPTION(key, value) if (!check(mpv_set_option_string(m, key, value), key)) { passed = 0; goto finish_cycle; }
        OPTION("config", "no"); OPTION("load-scripts", "no");
        OPTION("autoload-files", "no"); OPTION("audio-file-auto", "no"); OPTION("sub-auto", "no");
        OPTION("demuxer", "lavf"); OPTION("vo", "null");
        OPTION("ao", "null"); OPTION("pause", "yes");
        OPTION("keep-open", "yes"); OPTION("idle", "yes"); OPTION("terminal", "no");
        OPTION("input-default-bindings", "no"); OPTION("sid", "no");
        if (!check(mpv_initialize(m), "mpv_initialize")) { passed = 0; goto finish_cycle; }
        fputs(",\"mpvVersion\":", report); json_property(report, m, "mpv-version");
        fputs(",\"ffmpegVersion\":", report); json_property(report, m, "ffmpeg-version");
        const char *load[] = {"loadfile", argv[1], "replace", NULL};
        if (!command(m, load) || !wait_event(m, MPV_EVENT_FILE_LOADED) || !resolve(m, video, audio, &vid, &aid, argv[4], cycle)) { passed = 0; goto finish_cycle; }
        double duration = 0;
        if (!check(mpv_get_property(m, "duration", MPV_FORMAT_DOUBLE, &duration), "duration") || !isfinite(duration) || duration < 3) {
            failure = "fixture must have at least three seconds duration"; passed = 0; goto finish_cycle;
        }
        if (!select_track(m, "vid", vid) || !select_track(m, "aid", aid)) { passed = 0; goto finish_cycle; }
        pump(m, 0.15);
        if (!verify_track(m, "vid", vid) || !verify_track(m, "aid", aid)) { passed = 0; goto finish_cycle; }
        fprintf(report, ",\"videoTrackID\":%lld,\"audioTrackID\":%lld,\"captures\":[", (long long)vid, (long long)aid);
        capture_count = 1;
        double targets[] = {0, 1.5, 0.25, 2, 0.5};
        for (int op = 0; op < 5; op++) {
            char target[64]; snprintf(target, sizeof(target), "%.9f", targets[op]);
            if (!drain(m)) { passed = 0; break; }
            const char *seek[] = {"seek", target, "absolute+exact", NULL};
            if (!command(m, seek) || !wait_event(m, MPV_EVENT_PLAYBACK_RESTART)) { passed = 0; break; }
            double time = 0;
            if (!position(m, &time)) { passed = 0; break; }
            char filename[128]; snprintf(filename, sizeof(filename), "cycle-%d-seek-%d.rgb", cycle, op);
            snprintf(path, sizeof(path), "%s/%s", argv[4], filename);
            if (vid >= 0) {
                if (!capture_rgb(m, path)) { passed = 0; break; }
                struct stat st; if (stat(path, &st) || st.st_size == 0) { failure = "empty screenshot"; passed = 0; break; }
            }
            if (op) fputc(',', report);
            fprintf(report, "{\"targetSeconds\":%.9f,\"timePosition\":%.9f,\"file\":", targets[op], time);
            if (vid >= 0) json_string(report, filename); else fputs("null", report);
            fputs(",\"videoParameters\":", report); json_property(report, m, "video-params");
            fputs(",\"videoOutputParameters\":", report); json_property(report, m, "video-out-params");
            fputc('}', report);
        }
        fputc(']', report); capture_count = 0;
        if (passed) {
            double before, after, stable;
            int pause = 0;
            if (!position(m, &before) || !check(mpv_set_property(m, "pause", MPV_FORMAT_FLAG, &pause), "play")) { passed = 0; goto finish_cycle; }
            pump(m, 0.35); pause = 1;
            if (!check(mpv_set_property(m, "pause", MPV_FORMAT_FLAG, &pause), "pause")) { passed = 0; goto finish_cycle; }
            pump(m, 0.1);
            if (!position(m, &after)) { passed = 0; goto finish_cycle; }
            pump(m, 0.15);
            if (!position(m, &stable)) { passed = 0; goto finish_cycle; }
            fprintf(report, ",\"playStart\":%.9f,\"playEnd\":%.9f,\"pausedEnd\":%.9f", before, after, stable);
            if (after <= before + 0.05 || stable - after > 0.001 || after - stable > 0.001) { failure = "play advancement or pause stability failed"; passed = 0; }
        }
finish_cycle:
        if (capture_count) fputc(']', report);
        if (m) mpv_terminate_destroy(m);
        fputc('}', report); fflush(report);
    }
    fprintf(report, "],\"passed\":%s,\"audioOutput\":\"null\",\"failure\":", passed ? "true" : "false");
    if (failure) { json_string(report, failure); fprintf(stderr, "%s\n", failure); } else fputs("null", report);
    fputs("}\n", report); fclose(report);
    return passed ? 0 : 1;
}
