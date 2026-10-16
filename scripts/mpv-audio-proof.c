/* Offline decoded-audio qualification only. PCM file output bypasses hardware.
 * argv: source, ff-index, output.pcm, start, end, sample-rate, range-mode, demuxer, [decoder], [mov-edit-list].
 * sample-filter mode decodes from zero and trims integer samples before output.
 * on_preloaded resolves container identity before decoders/output are created.
 */
#include <mpv/client.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const mpv_node *field(const mpv_node *node, const char *key) {
    if (node->format != MPV_FORMAT_NODE_MAP) return NULL;
    for (int i = 0; i < node->u.list->num; ++i)
        if (!strcmp(node->u.list->keys[i], key)) return &node->u.list->values[i];
    return NULL;
}
static int option(mpv_handle *m, const char *key, const char *value) {
    int rc = mpv_set_option_string(m, key, value);
    if (rc < 0) fprintf(stderr, "%s: %s\n", key, mpv_error_string(rc));
    return rc >= 0;
}
static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int select_audio(mpv_handle *m, int index, int64_t *selected) {
    mpv_node list = {0};
    if (mpv_get_property(m, "track-list", MPV_FORMAT_NODE, &list) < 0) return 0;
    int matches = 0;
    if (list.format == MPV_FORMAT_NODE_ARRAY) for (int i = 0; i < list.u.list->num; ++i) {
        const mpv_node *track = &list.u.list->values[i];
        const mpv_node *kind = field(track, "type"), *ff = field(track, "ff-index"), *id = field(track, "id");
        if (kind && kind->format == MPV_FORMAT_STRING && !strcmp(kind->u.string, "audio") &&
            ff && ff->format == MPV_FORMAT_INT64 && ff->u.int64 == index &&
            id && id->format == MPV_FORMAT_INT64 && id->u.int64 > 0) {
            *selected = id->u.int64; ++matches;
        }
    }
    mpv_free_node_contents(&list);
    if (matches != 1) return -1;
    return mpv_set_property(m, "aid", MPV_FORMAT_INT64, selected) >= 0;
}
int main(int argc, char **argv) {
    if (argc < 9 || argc > 11) return 2;
    const char *decoder = argc >= 10 ? argv[9] : "auto";
    const char *mov_edit_list = argc == 11 ? argv[10] : "default";
    if (strcmp(mov_edit_list, "default") && strcmp(mov_edit_list, "basic")) return 2;
    if (!strcmp(mov_edit_list, "basic") && strcmp(argv[8], "lavf")) return 2;
    if (strcmp(decoder, "auto") && strcmp(decoder, "aac") &&
        strcmp(decoder, "aac_fixed") && strcmp(decoder, "aac_at")) return 2;
    char decoder_list[32];
    snprintf(decoder_list, sizeof(decoder_list), "%s,-", decoder);
    int sample_filter = !strcmp(argv[7], "sample-filter");
    if ((!sample_filter && strcmp(argv[7], "timestamp")) ||
        (strcmp(argv[8], "auto") && strcmp(argv[8], "lavf"))) return 2;
    char filter[160] = {0};
    if (sample_filter && strcmp(argv[4], "natural")) {
        char *start_end = NULL, *stop_end = NULL;
        errno = 0;
        long long start = strtoll(argv[4], &start_end, 10);
        if (errno || !*argv[4] || *start_end || start < 0) return 2;
        errno = 0;
        long long stop = strtoll(argv[5], &stop_end, 10);
        if (errno || !*argv[5] || *stop_end || stop <= start) return 2;
        snprintf(filter, sizeof(filter), "lavfi=[atrim=start_sample=%lld:end_sample=%lld]", start, stop);
    }
    char *end = NULL; errno = 0;
    long index = strtol(argv[2], &end, 10);
    if (errno || !*argv[2] || *end || index < 0 || index > INT32_MAX) return 2;
    mpv_handle *m = mpv_create();
    if (!m) return 1;
    int ok = 0, rejected = 0, loaded = 0, hooked = 0, restarted = 0;
    int64_t selected = -1;
    if (!option(m, "config", "no") || !option(m, "terminal", "no") ||
        !option(m, "vo", "null") || !option(m, "vid", "no") ||
        !option(m, "ao", "pcm") || !option(m, "ao-pcm-file", argv[3]) ||
        !option(m, "ao-pcm-waveheader", "no") || !option(m, "audio-format", "float") ||
        !option(m, "audio-samplerate", argv[6]) || !option(m, "audio-channels", "auto") ||
        !option(m, "msg-level", "ad=debug,af=debug") ||
        !option(m, "volume", "100") || !option(m, "replaygain", "no") ||
        (strcmp(decoder, "auto") && !option(m, "ad", decoder_list)) ||
        (strcmp(argv[8], "auto") && !option(m, "demuxer", argv[8])) ||
        (!strcmp(mov_edit_list, "basic") &&
            !option(m, "demuxer-lavf-o", "advanced_editlist=0")) ||
        (*filter && !option(m, "af", filter)) ||
        (!sample_filter && strcmp(argv[4], "natural") &&
            (!option(m, "start", argv[4]) || !option(m, "end", argv[5]))) ||
        !option(m, "keep-open", "no") || !option(m, "idle", "yes") ||
        mpv_initialize(m) < 0 || mpv_hook_add(m, 1, "on_preloaded", 0) < 0) goto cleanup;
    mpv_request_log_messages(m, "debug");
    const char *command[] = {"loadfile", argv[1], NULL};
    if (mpv_command(m, command) < 0) goto cleanup;
    double deadline = now() + 15;
    while (now() < deadline) {
        mpv_event *event = mpv_wait_event(m, 0.05);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = event->data;
            fprintf(stderr, "[%s/%s] %s", log->prefix, log->level, log->text);
        } else if (event->event_id == MPV_EVENT_HOOK) {
            mpv_event_hook *hook = event->data;
            int selected_ok = select_audio(m, (int)index, &selected);
            rejected = selected_ok == -1;
            if (mpv_hook_continue(m, hook->id) < 0 || selected_ok != 1) goto cleanup;
            hooked++;
        } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
            int64_t aid = -1;
            if (mpv_get_property(m, "aid", MPV_FORMAT_INT64, &aid) < 0 || aid != selected) goto cleanup;
            loaded++;
        } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
            restarted++;
        } else if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *eof = event->data;
            ok = eof->reason == MPV_END_FILE_REASON_EOF && eof->error == 0 &&
                 hooked == 1 && loaded == 1 && restarted > 0;
            break;
        } else if (event->event_id == MPV_EVENT_SHUTDOWN) break;
    }
cleanup:
    mpv_terminate_destroy(m); /* flush/close PCM output before comparison */
    if (rejected) {
        printf("{\"rejected\":true,\"ffIndex\":%ld}\n", index);
        return 3;
    }
    if (ok) printf("{\"passed\":true,\"ffIndex\":%ld,\"audioTrackID\":%lld,\"movEditList\":\"%s\"}\n",
                   index, (long long)selected, mov_edit_list);
    else fprintf(stderr, "Audio decode/selection/EOF failed or timed out\n");
    return ok ? 0 : 1;
}
