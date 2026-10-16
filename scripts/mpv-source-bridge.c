/* Private development bridge. Export only afc_mpv_bridge_* from its dylib. */
#include "mpv-source-bridge.h"
#include <mpv/client.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

enum { NEW, OPENING, READY, FAILED, CLOSED };
enum { LOAD = 1, TRACKS, VIDEO, AUDIO, VERIFY_VIDEO, VERIFY_AUDIO, COMMAND };
typedef struct { uint64_t wire, caller; int kind; } pending;
struct afc_mpv_bridge {
    mpv_handle *mpv;
    int state, video_index, audio_index, selection_left, has_position, paused, eof;
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
static pending *reserve(afc_mpv_bridge *b, uint64_t caller, int kind) {
    if (caller) for (size_t i = 0; i < 64; i++)
        if (b->requests[i].wire && b->requests[i].caller == caller) return NULL;
    for (size_t i = 0; i < 64; i++) if (!b->requests[i].wire) {
        /* Never reuse a wire ID, including after immediate submission errors. */
        if (b->sequence == UINT64_MAX) return NULL;
        b->requests[i] = (pending){++b->sequence, caller, kind};
        return &b->requests[i];
    }
    return NULL;
}
static int submit(afc_mpv_bridge *b, uint64_t caller, int kind, const char **args) {
    pending *p = reserve(b, caller, kind);
    if (!p) return AFC_MPV_BUSY;
    int rc = mpv_command_async(b->mpv, p->wire, args);
    if (rc < 0) memset(p, 0, sizeof(*p));
    return rc;
}
static void fail(afc_mpv_bridge *b, afc_mpv_event *out, int rc, const char *what) {
    out->request_id = b->state == OPENING ? b->open_request : 0;
    b->state = FAILED; b->has_position = 0;
    out->type = AFC_MPV_ERROR; out->status = rc;
    copy_text(out->message, sizeof(out->message), what);
}
int afc_mpv_bridge_create(afc_mpv_bridge **out, char *error, size_t capacity) {
    if (!out) return AFC_MPV_INVALID;
    *out = NULL; copy_text(error, capacity, "");
    afc_mpv_bridge *b = calloc(1, sizeof(*b));
    if (!b) return MPV_ERROR_NOMEM;
    b->vid = b->aid = -1;
    b->mpv = mpv_create();
    int rc = b->mpv ? 0 : MPV_ERROR_NOMEM;
    const char *options[][2] = {
        {"config","no"}, {"load-scripts","no"}, {"autoload-files","no"},
        {"audio-file-auto","no"}, {"sub-auto","no"}, {"demuxer","lavf"},
        {"vo","null"}, {"ao","null"}, {"pause","yes"}, {"keep-open","yes"},
        {"idle","yes"}, {"terminal","no"}, {"input-default-bindings","no"},
        {"sid","no"}
    };
    for (size_t i = 0; rc >= 0 && i < sizeof(options)/sizeof(options[0]); i++)
        rc = mpv_set_option_string(b->mpv, options[i][0], options[i][1]);
    if (rc >= 0) rc = mpv_initialize(b->mpv);
    if (rc >= 0) rc = mpv_observe_property(b->mpv, 1, "time-pos", MPV_FORMAT_DOUBLE);
    if (rc >= 0) rc = mpv_observe_property(b->mpv, 2, "pause", MPV_FORMAT_FLAG);
    if (rc >= 0) rc = mpv_observe_property(b->mpv, 3, "eof-reached", MPV_FORMAT_FLAG);
    if (rc < 0) {
        copy_text(error, capacity, mpv_error_string(rc));
        afc_mpv_bridge_destroy(&b); return rc;
    }
    *out = b; return 0;
}
int afc_mpv_bridge_open(afc_mpv_bridge *b, const char *path, int video, int audio, uint64_t id) {
    struct stat st;
    if (!b || !path || !id || video < -1 || audio < -1 || (video == -1 && audio == -1) ||
        path[0] != '/' || stat(path, &st) || !S_ISREG(st.st_mode)) return AFC_MPV_INVALID;
    if (b->state != NEW) return AFC_MPV_STATE;
    b->video_index = video; b->audio_index = audio; b->open_request = id;
    const char *args[] = {"loadfile", path, "replace", NULL};
    int rc = submit(b, id, LOAD, args);
    if (rc >= 0) b->state = OPENING;
    return rc;
}
int afc_mpv_bridge_seek(afc_mpv_bridge *b, double seconds, uint64_t id) {
    if (!b || !id || !isfinite(seconds) || seconds < 0) return AFC_MPV_INVALID;
    if (b->state != READY) return AFC_MPV_STATE;
    char value[64]; snprintf(value, sizeof(value), "%.17g", seconds);
    const char *args[] = {"seek", value, "absolute+exact", NULL};
    int rc = submit(b, id, COMMAND, args);
    if (rc >= 0) {
        /* Observations coalesce: a seek away and back may never change time-pos.
         * Keep the last observed cache for ordinary seeks. EOF alone makes it
         * unavailable until a fresh observation during recovery. */
        if (b->eof) b->has_position = 0;
        b->eof = 0;
    }
    return rc;
}
int afc_mpv_bridge_set_paused(afc_mpv_bridge *b, int paused, uint64_t id) {
    if (!b || !id || (paused != 0 && paused != 1)) return AFC_MPV_INVALID;
    if (b->state != READY) return AFC_MPV_STATE;
    const char *args[] = {"set", "pause", paused ? "yes" : "no", NULL};
    return submit(b, id, COMMAND, args);
}
static int resolve_tracks(afc_mpv_bridge *b, const mpv_node *list) {
    int vc = 0, ac = 0;
    if (!list || list->format != MPV_FORMAT_NODE_ARRAY || !list->u.list) return AFC_MPV_TRACK;
    for (int i = 0; i < list->u.list->num; i++) {
        const mpv_node *track = &list->u.list->values[i];
        const mpv_node *type = field(track,"type"), *index = field(track,"ff-index"), *id = field(track,"id");
        if (!type || type->format != MPV_FORMAT_STRING || !index || index->format != MPV_FORMAT_INT64 ||
            !id || id->format != MPV_FORMAT_INT64 || id->u.int64 <= 0) continue;
        if (b->video_index >= 0 && !strcmp(type->u.string,"video") && index->u.int64 == b->video_index) { b->vid = id->u.int64; vc++; }
        if (b->audio_index >= 0 && !strcmp(type->u.string,"audio") && index->u.int64 == b->audio_index) { b->aid = id->u.int64; ac++; }
    }
    if ((b->video_index >= 0 && vc != 1) || (b->audio_index >= 0 && ac != 1)) return AFC_MPV_TRACK;
    const char *names[] = {"vid", "aid"}; int64_t ids[] = {b->vid,b->aid};
    b->selection_left = 2;
    for (int i = 0; i < 2; i++) {
        char value[64];
        if (ids[i] < 0) strcpy(value,"no"); else snprintf(value,sizeof(value),"%lld",(long long)ids[i]);
        const char *args[] = {"set", names[i], value, NULL};
        int rc = submit(b,0,i ? AUDIO : VIDEO,args);
        if (rc < 0) return rc;
    }
    return 0;
}
int afc_mpv_bridge_poll(afc_mpv_bridge *b, afc_mpv_event *events, size_t capacity, size_t budget) {
    if (!b || !events || !capacity || capacity > 1024 || !budget || budget > 1024) return AFC_MPV_INVALID;
    if (!b->mpv || b->state == CLOSED) return AFC_MPV_STATE;
    size_t count = 0;
    for (size_t i = 0; i < budget && count < capacity; i++) {
        mpv_event *e = mpv_wait_event(b->mpv,0);
        if (e->event_id == MPV_EVENT_NONE) break;
        afc_mpv_event out = {0};
        out.video_track_id = b->vid; out.audio_track_id = b->aid;
        if (e->event_id == MPV_EVENT_COMMAND_REPLY || e->event_id == MPV_EVENT_GET_PROPERTY_REPLY) {
            pending p = {0};
            for (size_t j = 0; j < 64; j++) if (b->requests[j].wire == e->reply_userdata) {
                p = b->requests[j]; memset(&b->requests[j],0,sizeof(p)); break;
            }
            if (p.kind == COMMAND) {
                out.type = AFC_MPV_COMMAND_REPLY; out.request_id = p.caller; out.status = e->error;
                if (e->error < 0) copy_text(out.message,sizeof(out.message),mpv_error_string(e->error));
            } else if (p.kind && b->state == OPENING) {
                int rc = e->error;
                if (rc >= 0 && p.kind == TRACKS) {
                    mpv_event_property *prop = e->data;
                    rc = prop && prop->format == MPV_FORMAT_NODE ? resolve_tracks(b,prop->data) : AFC_MPV_TRACK;
                }
                if (rc >= 0 && (p.kind == VIDEO || p.kind == AUDIO)) {
                    int video = p.kind == VIDEO;
                    pending *query = reserve(b,0,video ? VERIFY_VIDEO : VERIFY_AUDIO);
                    rc = query ? mpv_get_property_async(b->mpv,query->wire,
                        video ? "vid" : "aid",MPV_FORMAT_STRING) : AFC_MPV_BUSY;
                    if (rc < 0 && query) memset(query,0,sizeof(*query));
                }
                if (rc >= 0 && (p.kind == VERIFY_VIDEO || p.kind == VERIFY_AUDIO)) {
                    mpv_event_property *prop = e->data;
                    const char *actual = prop && prop->format == MPV_FORMAT_STRING && prop->data ?
                        *(char **)prop->data : NULL;
                    int64_t selected = p.kind == VERIFY_VIDEO ? b->vid : b->aid;
                    char expected[64];
                    if (selected < 0) strcpy(expected,"no");
                    else snprintf(expected,sizeof(expected),"%lld",(long long)selected);
                    if (!actual || strcmp(actual,expected)) rc = AFC_MPV_TRACK;
                }
                if (rc < 0) fail(b,&out,rc,"load or explicit source track selection/verification failed");
                else if ((p.kind == VERIFY_VIDEO || p.kind == VERIFY_AUDIO) && --b->selection_left == 0) {
                    b->state = READY; out.type = AFC_MPV_OPENED; out.request_id = b->open_request;
                    out.video_track_id = b->vid; out.audio_track_id = b->aid;
                }
            }
        } else if (e->event_id == MPV_EVENT_FILE_LOADED && b->state == OPENING) {
            pending *p = reserve(b,0,TRACKS);
            int rc = p ? mpv_get_property_async(b->mpv,p->wire,"track-list",MPV_FORMAT_NODE) : AFC_MPV_BUSY;
            if (rc < 0) { if (p) memset(p,0,sizeof(*p)); fail(b,&out,rc,"track-list query failed"); }
        } else if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *p = e->data;
            if (p && p->data && e->reply_userdata == 1 && p->format == MPV_FORMAT_DOUBLE) {
                double t = *(double *)p->data;
                if (isfinite(t) && !b->eof && (b->state == OPENING || b->state == READY)) {
                    b->position = t; b->has_position = 1;
                    if (b->state == READY) { out.type = AFC_MPV_POSITION; out.seconds = t; }
                }
            } else if (p && p->data && e->reply_userdata == 2 && p->format == MPV_FORMAT_FLAG) {
                b->paused = *(int *)p->data; out.type = AFC_MPV_PAUSE; out.paused = b->paused;
            } else if (p && p->data && e->reply_userdata == 3 && p->format == MPV_FORMAT_FLAG) {
                b->eof = *(int *)p->data;
                if (b->eof) {
                    out.type = AFC_MPV_END_FILE; out.end_reason = MPV_END_FILE_REASON_EOF; b->has_position = 0;
                }
            } else if (e->reply_userdata == 1) b->has_position = 0;
        } else if (e->event_id == MPV_EVENT_PLAYBACK_RESTART && b->state == READY) {
            out.type = AFC_MPV_PLAYBACK_RESTART;
        } else if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = e->data;
            out.type = AFC_MPV_END_FILE; b->has_position = 0; b->eof = 1;
            if (end) { out.end_reason = end->reason; out.status = end->error; }
            if (b->state == OPENING || out.status < 0) {
                int rc = out.status < 0 ? out.status : MPV_ERROR_LOADING_FAILED;
                fail(b,&out,rc,out.status < 0 ? mpv_error_string(out.status) : "source ended while opening");
            }
        } else if (e->event_id == MPV_EVENT_SHUTDOWN) {
            b->state = FAILED; b->has_position = 0; out.type = AFC_MPV_SHUTDOWN;
        } else if (e->event_id == MPV_EVENT_QUEUE_OVERFLOW) {
            fail(b,&out,MPV_ERROR_EVENT_QUEUE_FULL,"libmpv event queue overflow; recreate bridge");
        }
        if (out.type) events[count++] = out;
    }
    return (int)count;
}
int afc_mpv_bridge_position(afc_mpv_bridge *b, double *seconds) {
    if (!b || !seconds) return AFC_MPV_INVALID;
    if (b->state != READY || !b->has_position) return AFC_MPV_STATE;
    *seconds = b->position; return 0;
}
int afc_mpv_bridge_screenshot_rgb(afc_mpv_bridge *b, unsigned char *pixels, size_t capacity,
                                 int *width, int *height, size_t *required) {
    if (!b || !width || !height || !required || (!pixels && capacity)) return AFC_MPV_INVALID;
    *width = *height = 0; *required = 0;
    if (b->state != READY || b->vid < 0) return AFC_MPV_STATE;
    const char *args[] = {"screenshot-raw","video","bgr0",NULL}; mpv_node result = {0};
    int rc = mpv_command_ret(b->mpv,args,&result);
    if (rc < 0) return rc;
    const mpv_node *w=field(&result,"w"), *h=field(&result,"h"), *s=field(&result,"stride"),
                   *f=field(&result,"format"), *d=field(&result,"data");
    if (!w || w->format != MPV_FORMAT_INT64 || w->u.int64 <= 0 || w->u.int64 > 4096 ||
        !h || h->format != MPV_FORMAT_INT64 || h->u.int64 <= 0 || h->u.int64 > 4096 ||
        !s || s->format != MPV_FORMAT_INT64 || s->u.int64 < w->u.int64*4 ||
        !f || f->format != MPV_FORMAT_STRING || strcmp(f->u.string,"bgr0") ||
        !d || d->format != MPV_FORMAT_BYTE_ARRAY || !d->u.ba || !d->u.ba->data ||
        s->u.int64 > (int64_t)(d->u.ba->size / (size_t)h->u.int64)) rc = AFC_MPV_INVALID;
    else {
        *width = (int)w->u.int64; *height = (int)h->u.int64;
        *required = (size_t)*width * (size_t)*height * 3;
        if (capacity < *required || !pixels) rc = AFC_MPV_BUFFER;
        else for (int y=0; y<*height; y++) for (int x=0; x<*width; x++) {
            const unsigned char *in = (const unsigned char *)d->u.ba->data + (size_t)y*(size_t)s->u.int64 + (size_t)x*4;
            unsigned char *out = pixels + ((size_t)y*(size_t)*width+(size_t)x)*3;
            out[0]=in[2]; out[1]=in[1]; out[2]=in[0];
        }
    }
    mpv_free_node_contents(&result); return rc;
}
void afc_mpv_bridge_close(afc_mpv_bridge *b) {
    if (!b || b->state == CLOSED) return;
    b->state = CLOSED; b->has_position = 0;
    if (b->mpv) mpv_terminate_destroy(b->mpv);
    b->mpv = NULL; memset(b->requests,0,sizeof(b->requests));
}
void afc_mpv_bridge_destroy(afc_mpv_bridge **b) {
    if (!b || !*b) return;
    afc_mpv_bridge_close(*b); free(*b); *b = NULL;
}
