/* libmpv source player for the Source viewer. Derived from the asynchronous
 * development bridge (scripts/mpv-source-bridge.c): explicit ff-index track
 * resolution and verification, correlated command replies, bounded copied
 * events. Video goes through the software render API instead of a null VO.
 * No libmpv type crosses this ABI. */
#include "CNativeDecoder.h"

#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <libavformat/avformat.h>
#include <Libmpv/mpv/client.h>
#include <Libmpv/mpv/render.h>

enum { NEW, OPENING, READY, FAILED, CLOSED };
enum { LOAD = 1, TRACKS, VIDEO, AUDIO, VERIFY_VIDEO, VERIFY_AUDIO, COMMAND };
typedef struct { uint64_t wire, caller; int kind; } pending;
struct AFCSourcePlayer {
    mpv_handle *mpv;
    mpv_render_context *render;
    atomic_int frame_pending;
    int state, video_index, audio_index, external_audio, selection_left, has_position, paused, eof;
    int64_t vid, aid;
    uint64_t sequence, open_request;
    double position;
    pending requests[64];
};

static void copy_text(char *out, size_t n, const char *text) {
    if (out && n) snprintf(out, n, "%s", text ? text : "");
}
static const mpv_node *field(const mpv_node *n, const char *key) {
    if (!n || n->format != MPV_FORMAT_NODE_MAP || !n->u.list) return NULL;
    for (int i = 0; i < n->u.list->num; i++)
        if (!strcmp(n->u.list->keys[i], key)) return &n->u.list->values[i];
    return NULL;
}
static pending *reserve(AFCSourcePlayer *p, uint64_t caller, int kind) {
    if (caller) for (size_t i = 0; i < 64; i++)
        if (p->requests[i].wire && p->requests[i].caller == caller) return NULL;
    for (size_t i = 0; i < 64; i++) if (!p->requests[i].wire) {
        /* Never reuse a wire ID, including after immediate submission errors. */
        if (p->sequence == UINT64_MAX) return NULL;
        p->requests[i] = (pending){++p->sequence, caller, kind};
        return &p->requests[i];
    }
    return NULL;
}
static int submit(AFCSourcePlayer *p, uint64_t caller, int kind, const char **args) {
    pending *r = reserve(p, caller, kind);
    if (!r) return AFC_SOURCE_BUSY;
    int rc = mpv_command_async(p->mpv, r->wire, args);
    if (rc < 0) memset(r, 0, sizeof(*r));
    return rc;
}
static void fail(AFCSourcePlayer *p, AFCSourceEvent *out, int rc, const char *what) {
    out->request_id = p->state == OPENING ? p->open_request : 0;
    p->state = FAILED; p->has_position = 0;
    out->type = AFC_SOURCE_ERROR; out->status = rc;
    copy_text(out->message, sizeof(out->message), what);
}
/* Runs on an mpv thread: only flags the render queue, never calls back into Swift. */
static void render_update(void *context) {
    atomic_store(&((AFCSourcePlayer *)context)->frame_pending, 1);
}

int afc_source_create(AFCSourcePlayer **out, int audio_output, char *error, size_t capacity) {
    if (!out || (audio_output != 0 && audio_output != 1)) return AFC_SOURCE_INVALID;
    *out = NULL; copy_text(error, capacity, "");
    AFCSourcePlayer *p = calloc(1, sizeof(*p));
    if (!p) return MPV_ERROR_NOMEM;
    p->vid = p->aid = -1;
    p->mpv = mpv_create();
    int rc = p->mpv ? 0 : MPV_ERROR_NOMEM;
    /* Raw container timestamps: callers map them to asset time with the origin
     * from afc_source_media_origin, so asset zero never depends on MPV's rebase.
     * Exact seeks show the first frame at or after the target. */
    const char *options[][2] = {
        {"config","no"}, {"load-scripts","no"}, {"autoload-files","no"},
        {"audio-file-auto","no"}, {"sub-auto","no"}, {"demuxer","lavf"},
        {"vo","libmpv"}, {"ao", audio_output ? "coreaudio,null" : "null"}, {"hwdec","no"},
        {"pause","yes"}, {"keep-open","yes"}, {"idle","yes"}, {"terminal","no"},
        {"input-default-bindings","no"}, {"input-vo-keyboard","no"}, {"osd-level","0"},
        {"sid","no"}, {"hr-seek","yes"}, {"rebase-start-time","no"},
        {"audio-display","no"}, {"force-window","no"}
    };
    for (size_t i = 0; rc >= 0 && i < sizeof(options)/sizeof(options[0]); i++)
        rc = mpv_set_option_string(p->mpv, options[i][0], options[i][1]);
    if (rc >= 0) rc = mpv_initialize(p->mpv);
    if (rc >= 0) {
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_SW}, {MPV_RENDER_PARAM_INVALID, NULL}
        };
        rc = mpv_render_context_create(&p->render, p->mpv, params);
        if (rc >= 0) mpv_render_context_set_update_callback(p->render, render_update, p);
    }
    if (rc >= 0) rc = mpv_observe_property(p->mpv, 1, "time-pos", MPV_FORMAT_DOUBLE);
    if (rc >= 0) rc = mpv_observe_property(p->mpv, 2, "pause", MPV_FORMAT_FLAG);
    if (rc >= 0) rc = mpv_observe_property(p->mpv, 3, "eof-reached", MPV_FORMAT_FLAG);
    if (rc < 0) {
        copy_text(error, capacity, mpv_error_string(rc));
        afc_source_destroy(&p); return rc;
    }
    *out = p; return 0;
}

static int regular_file(const char *path) {
    struct stat st;
    return path && path[0] == '/' && !stat(path, &st) && S_ISREG(st.st_mode);
}

int afc_source_open(AFCSourcePlayer *p, const char *path, int video, int audio,
                    const char *external_audio, double audio_delay, uint64_t id) {
    if (!p || !regular_file(path) || !id || video < -1 || audio < -1 || (video == -1 && audio == -1) ||
        !isfinite(audio_delay) || (external_audio && (!regular_file(external_audio) || audio < 0)))
        return AFC_SOURCE_INVALID;
    if (p->state != NEW) return AFC_SOURCE_STATE;
    char delay[64]; snprintf(delay, sizeof(delay), "%.17g", audio_delay);
    int rc = mpv_set_property_string(p->mpv, "audio-delay", delay);
    if (rc >= 0 && external_audio) {
        /* change-list append takes the path as one item, so separators in it are inert. */
        const char *append[] = {"change-list", "audio-files", "append", external_audio, NULL};
        rc = mpv_command(p->mpv, append);
    }
    if (rc < 0) return rc;
    p->video_index = video; p->audio_index = audio; p->external_audio = external_audio != NULL;
    p->open_request = id;
    const char *args[] = {"loadfile", path, "replace", NULL};
    rc = submit(p, id, LOAD, args);
    if (rc >= 0) p->state = OPENING;
    return rc;
}

int afc_source_seek(AFCSourcePlayer *p, double seconds, uint64_t id) {
    if (!p || !id || !isfinite(seconds)) return AFC_SOURCE_INVALID;
    if (p->state != READY) return AFC_SOURCE_STATE;
    char value[64]; snprintf(value, sizeof(value), "%.17g", seconds);
    const char *args[] = {"seek", value, "absolute+exact", NULL};
    int rc = submit(p, id, COMMAND, args);
    if (rc >= 0) {
        /* Observations coalesce: a seek away and back may never change time-pos.
         * EOF alone makes the cache unavailable until a fresh observation. */
        if (p->eof) p->has_position = 0;
        p->eof = 0;
    }
    return rc;
}

int afc_source_set_paused(AFCSourcePlayer *p, int paused, uint64_t id) {
    if (!p || !id || (paused != 0 && paused != 1)) return AFC_SOURCE_INVALID;
    if (p->state != READY) return AFC_SOURCE_STATE;
    const char *args[] = {"set", "pause", paused ? "yes" : "no", NULL};
    return submit(p, id, COMMAND, args);
}

/* The selected video is always in the primary file; the audio is in the external
 * file when one was given (proxy picture with original sound). */
static int resolve_tracks(AFCSourcePlayer *p, const mpv_node *list) {
    int vc = 0, ac = 0;
    if (!list || list->format != MPV_FORMAT_NODE_ARRAY || !list->u.list) return AFC_SOURCE_TRACK;
    for (int i = 0; i < list->u.list->num; i++) {
        const mpv_node *track = &list->u.list->values[i];
        const mpv_node *type = field(track,"type"), *index = field(track,"ff-index"), *id = field(track,"id"),
            *external = field(track,"external");
        if (!type || type->format != MPV_FORMAT_STRING || !index || index->format != MPV_FORMAT_INT64 ||
            !id || id->format != MPV_FORMAT_INT64 || id->u.int64 <= 0) continue;
        int is_external = external && external->format == MPV_FORMAT_FLAG && external->u.flag;
        if (p->video_index >= 0 && !is_external && !strcmp(type->u.string,"video") && index->u.int64 == p->video_index) {
            p->vid = id->u.int64; vc++;
        }
        if (p->audio_index >= 0 && is_external == p->external_audio && !strcmp(type->u.string,"audio") &&
            index->u.int64 == p->audio_index) { p->aid = id->u.int64; ac++; }
    }
    if ((p->video_index >= 0 && vc != 1) || (p->audio_index >= 0 && ac != 1)) return AFC_SOURCE_TRACK;
    const char *names[] = {"vid", "aid"}; int64_t ids[] = {p->vid, p->aid};
    p->selection_left = 2;
    for (int i = 0; i < 2; i++) {
        char value[64];
        if (ids[i] < 0) strcpy(value,"no"); else snprintf(value,sizeof(value),"%lld",(long long)ids[i]);
        const char *args[] = {"set", names[i], value, NULL};
        int rc = submit(p,0,i ? AUDIO : VIDEO,args);
        if (rc < 0) return rc;
    }
    return 0;
}

int afc_source_poll(AFCSourcePlayer *p, AFCSourceEvent *events, size_t capacity, size_t budget) {
    if (!p || !events || !capacity || capacity > 1024 || !budget || budget > 1024) return AFC_SOURCE_INVALID;
    if (!p->mpv || p->state == CLOSED) return AFC_SOURCE_STATE;
    size_t count = 0;
    for (size_t i = 0; i < budget && count < capacity; i++) {
        mpv_event *e = mpv_wait_event(p->mpv,0);
        if (e->event_id == MPV_EVENT_NONE) break;
        AFCSourceEvent out = {0};
        out.video_track_id = p->vid; out.audio_track_id = p->aid;
        if (e->event_id == MPV_EVENT_COMMAND_REPLY || e->event_id == MPV_EVENT_GET_PROPERTY_REPLY) {
            pending r = {0};
            for (size_t j = 0; j < 64; j++) if (p->requests[j].wire == e->reply_userdata) {
                r = p->requests[j]; memset(&p->requests[j],0,sizeof(r)); break;
            }
            if (r.kind == COMMAND) {
                out.type = AFC_SOURCE_COMMAND_REPLY; out.request_id = r.caller; out.status = e->error;
                if (e->error < 0) copy_text(out.message,sizeof(out.message),mpv_error_string(e->error));
            } else if (r.kind && p->state == OPENING) {
                int rc = e->error;
                if (rc >= 0 && r.kind == TRACKS) {
                    mpv_event_property *prop = e->data;
                    rc = prop && prop->format == MPV_FORMAT_NODE ? resolve_tracks(p,prop->data) : AFC_SOURCE_TRACK;
                }
                if (rc >= 0 && (r.kind == VIDEO || r.kind == AUDIO)) {
                    int video = r.kind == VIDEO;
                    pending *query = reserve(p,0,video ? VERIFY_VIDEO : VERIFY_AUDIO);
                    rc = query ? mpv_get_property_async(p->mpv,query->wire,
                        video ? "vid" : "aid",MPV_FORMAT_STRING) : AFC_SOURCE_BUSY;
                    if (rc < 0 && query) memset(query,0,sizeof(*query));
                }
                if (rc >= 0 && (r.kind == VERIFY_VIDEO || r.kind == VERIFY_AUDIO)) {
                    mpv_event_property *prop = e->data;
                    const char *actual = prop && prop->format == MPV_FORMAT_STRING && prop->data ?
                        *(char **)prop->data : NULL;
                    int64_t selected = r.kind == VERIFY_VIDEO ? p->vid : p->aid;
                    char expected[64];
                    if (selected < 0) strcpy(expected,"no");
                    else snprintf(expected,sizeof(expected),"%lld",(long long)selected);
                    if (!actual || strcmp(actual,expected)) rc = AFC_SOURCE_TRACK;
                }
                if (rc < 0) fail(p,&out,rc,"load or explicit source track selection/verification failed");
                else if ((r.kind == VERIFY_VIDEO || r.kind == VERIFY_AUDIO) && --p->selection_left == 0) {
                    p->state = READY; out.type = AFC_SOURCE_OPENED; out.request_id = p->open_request;
                    out.video_track_id = p->vid; out.audio_track_id = p->aid;
                }
            }
        } else if (e->event_id == MPV_EVENT_FILE_LOADED && p->state == OPENING) {
            pending *r = reserve(p,0,TRACKS);
            int rc = r ? mpv_get_property_async(p->mpv,r->wire,"track-list",MPV_FORMAT_NODE) : AFC_SOURCE_BUSY;
            if (rc < 0) { if (r) memset(r,0,sizeof(*r)); fail(p,&out,rc,"track-list query failed"); }
        } else if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *prop = e->data;
            if (prop && prop->data && e->reply_userdata == 1 && prop->format == MPV_FORMAT_DOUBLE) {
                double t = *(double *)prop->data;
                if (isfinite(t) && !p->eof && (p->state == OPENING || p->state == READY)) {
                    p->position = t; p->has_position = 1;
                    if (p->state == READY) { out.type = AFC_SOURCE_POSITION; out.seconds = t; }
                }
            } else if (prop && prop->data && e->reply_userdata == 2 && prop->format == MPV_FORMAT_FLAG) {
                p->paused = *(int *)prop->data; out.type = AFC_SOURCE_PAUSE; out.paused = p->paused;
            } else if (prop && prop->data && e->reply_userdata == 3 && prop->format == MPV_FORMAT_FLAG) {
                /* With keep-open the last frame stays and time-pos keeps its value. */
                p->eof = *(int *)prop->data;
                if (p->eof) { out.type = AFC_SOURCE_END_FILE; out.end_reason = MPV_END_FILE_REASON_EOF; }
            } else if (e->reply_userdata == 1) p->has_position = 0;
        } else if (e->event_id == MPV_EVENT_PLAYBACK_RESTART && p->state == READY) {
            out.type = AFC_SOURCE_PLAYBACK_RESTART;
        } else if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = e->data;
            out.type = AFC_SOURCE_END_FILE; p->has_position = 0; p->eof = 1;
            if (end) { out.end_reason = end->reason; out.status = end->error; }
            if (p->state == OPENING || out.status < 0) {
                int rc = out.status < 0 ? out.status : MPV_ERROR_LOADING_FAILED;
                fail(p,&out,rc,out.status < 0 ? mpv_error_string(out.status) : "source ended while opening");
            }
        } else if (e->event_id == MPV_EVENT_SHUTDOWN) {
            p->state = FAILED; p->has_position = 0; out.type = AFC_SOURCE_SHUTDOWN;
        } else if (e->event_id == MPV_EVENT_QUEUE_OVERFLOW) {
            fail(p,&out,MPV_ERROR_EVENT_QUEUE_FULL,"libmpv event queue overflow; recreate the player");
        }
        if (out.type) events[count++] = out;
    }
    return (int)count;
}

int afc_source_position(AFCSourcePlayer *p, double *seconds) {
    if (!p || !seconds) return AFC_SOURCE_INVALID;
    if (p->state != READY || !p->has_position) return AFC_SOURCE_STATE;
    *seconds = p->position; return 0;
}

int afc_source_time_pos(AFCSourcePlayer *p, double *seconds) {
    if (!p || !seconds) return AFC_SOURCE_INVALID;
    if (p->state != READY) return AFC_SOURCE_STATE;
    double t = 0;
    int rc = mpv_get_property(p->mpv, "time-pos", MPV_FORMAT_DOUBLE, &t);
    if (rc < 0) return rc;
    if (!isfinite(t)) return AFC_SOURCE_STATE;
    p->position = t; p->has_position = 1;
    *seconds = t; return 0;
}

int afc_source_video_size(AFCSourcePlayer *p, int *width, int *height) {
    if (!p || !width || !height) return AFC_SOURCE_INVALID;
    *width = *height = 0;
    if (p->state != READY || p->vid < 0) return AFC_SOURCE_STATE;
    int64_t w = 0, h = 0;
    int rc = mpv_get_property(p->mpv, "dwidth", MPV_FORMAT_INT64, &w);
    if (rc >= 0) rc = mpv_get_property(p->mpv, "dheight", MPV_FORMAT_INT64, &h);
    if (rc < 0) return rc;
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return AFC_SOURCE_STATE;
    *width = (int)w; *height = (int)h; return 0;
}

int afc_source_render(AFCSourcePlayer *p, int width, int height, uint8_t *bgr0, size_t stride, int force) {
    if (!p || !bgr0 || width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
        stride < (size_t)width * 4 || stride % 4) return AFC_SOURCE_INVALID;
    if (!p->render) return AFC_SOURCE_STATE;
    /* Nothing changed since the last update callback, unless a repaint is forced. */
    if (!atomic_exchange(&p->frame_pending, 0) && !force) return 0;
    uint64_t flags = mpv_render_context_update(p->render);
    if (!(flags & MPV_RENDER_UPDATE_FRAME) && !force) return 0;
    int size[2] = {width, height};
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size}, {MPV_RENDER_PARAM_SW_FORMAT, "bgr0"},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, bgr0},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    int rc = mpv_render_context_render(p->render, params);
    return rc < 0 ? rc : 1;
}

void afc_source_release_render(AFCSourcePlayer *p) {
    if (!p || !p->render) return;
    mpv_render_context_free(p->render);
    p->render = NULL;
}

void afc_source_close(AFCSourcePlayer *p) {
    if (!p || p->state == CLOSED) return;
    p->state = CLOSED; p->has_position = 0;
    /* The render context must be freed before its core. */
    afc_source_release_render(p);
    if (p->mpv) mpv_terminate_destroy(p->mpv);
    p->mpv = NULL; memset(p->requests,0,sizeof(p->requests));
}

void afc_source_destroy(AFCSourcePlayer **p) {
    if (!p || !*p) return;
    afc_source_close(*p); free(*p); *p = NULL;
}

int afc_source_media_origin(const char *path, int64_t *numerator, int64_t *denominator,
                            int *first_video_index, char *error, size_t capacity) {
    if (!regular_file(path) || !numerator || !denominator || !first_video_index) return AFC_SOURCE_INVALID;
    copy_text(error, capacity, "");
    *numerator = 0; *denominator = 1; *first_video_index = -1;
    AVFormatContext *format = NULL;
    int rc = avformat_open_input(&format, path, NULL, NULL);
    if (rc >= 0) rc = avformat_find_stream_info(format, NULL);
    if (rc < 0) {
        char text[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(rc, text, sizeof(text));
        copy_text(error, capacity, text);
        avformat_close_input(&format);
        return AFC_SOURCE_INVALID;
    }
    /* Asset zero is the earliest audio/video stream start, as in afc_probe_open. */
    int have = 0;
    for (unsigned i = 0; i < format->nb_streams; ++i) {
        AVStream *stream = format->streams[i];
        enum AVMediaType type = stream->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) continue;
        if (type == AVMEDIA_TYPE_VIDEO && (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        if (type == AVMEDIA_TYPE_VIDEO && *first_video_index < 0) *first_video_index = (int)i;
        int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
        int64_t num = start * stream->time_base.num, den = stream->time_base.den;
        if (den <= 0) continue;
        if (!have || (__int128)num * *denominator < (__int128)*numerator * den) {
            *numerator = num; *denominator = den; have = 1;
        }
    }
    avformat_close_input(&format);
    return have ? 0 : AFC_SOURCE_TRACK;
}
