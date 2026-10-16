#ifndef AFC_MPV_SOURCE_BRIDGE_H
#define AFC_MPV_SOURCE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Development-only, single serial caller API. No libmpv types cross this ABI.
 * No wakeup callback is installed: poll calls mpv_wait_event(..., 0) at most
 * max_raw_events times and copies all returned values. Keep polling regularly.
 * create/close and screenshot may synchronously enter libmpv; close joins its
 * worker threads. All playback commands and track resolution are asynchronous.
 * One source per handle. open accepts an absolute local regular file, container
 * ff-index values (-1 disables that media type), and starts paused. At least
 * one media type must be enabled. OPENED means explicit track selection finished
 * and asynchronous vid/aid reads verified both selected IDs (or disabled state).
 * Request IDs must be nonzero and unique among pending requests. Seek/pause are
 * valid only after OPENED. COMMAND_REPLY acknowledges execution, not decode
 * completion: PLAYBACK_RESTART is uncorrelated and can coalesce across seeks.
 * Track selection/playback failures are terminal; close then recreate. Poll
 * may still drain queued notifications/replies after failure; new commands
 * are rejected. Command-reply errors alone do not make the handle terminal.
 * Negative statuses are bridge errors below or unmodified libmpv error codes.
 * Returned strings are always NUL terminated and may be truncated.
 */
typedef struct afc_mpv_bridge afc_mpv_bridge;
enum { AFC_MPV_INVALID = -1000, AFC_MPV_STATE = -1001,
       AFC_MPV_BUSY = -1002, AFC_MPV_TRACK = -1003, AFC_MPV_BUFFER = -1004 };
typedef enum {
    AFC_MPV_OPENED = 1, AFC_MPV_COMMAND_REPLY, AFC_MPV_PLAYBACK_RESTART,
    AFC_MPV_POSITION, AFC_MPV_PAUSE, AFC_MPV_END_FILE, AFC_MPV_ERROR,
    AFC_MPV_SHUTDOWN
} afc_mpv_event_type;
typedef struct {
    afc_mpv_event_type type;
    uint64_t request_id;
    int status;
    double seconds;
    int paused;
    int64_t video_track_id;
    int64_t audio_track_id;
    int end_reason; /* libmpv end reason integer; EOF is zero. */
    char message[256];
} afc_mpv_event;
int afc_mpv_bridge_create(afc_mpv_bridge **out, char *error, size_t capacity);
int afc_mpv_bridge_open(afc_mpv_bridge *, const char *path, int video_ff_index,
                        int audio_ff_index, uint64_t request_id);
int afc_mpv_bridge_seek(afc_mpv_bridge *, double seconds, uint64_t request_id);
int afc_mpv_bridge_set_paused(afc_mpv_bridge *, int paused, uint64_t request_id);
/* Returns event count, or negative error; capacity and budget must be 1..1024.
 * An empty poll is normal. Zero-initialize nothing: every event is fully copied.
 */
int afc_mpv_bridge_poll(afc_mpv_bridge *, afc_mpv_event *events,
                        size_t capacity, size_t max_raw_events);
/* Cached observed time-pos; STATE until available, or after EOF/error/close.
 * Ordinary pending seeks retain the last observation. A command reply does not
 * imply that the cache has reached its target; callers must await restart and
 * compare the observed position when qualifying exact decode completion. */
int afc_mpv_bridge_position(afc_mpv_bridge *, double *seconds);
/* Qualification only: tightly packed RGB24, maximum 4096x4096. On BUFFER,
 * width/height/required_bytes describe the required caller-owned allocation.
 * No pixel buffer or libmpv allocation escapes the call. */
int afc_mpv_bridge_screenshot_rgb(afc_mpv_bridge *, unsigned char *pixels,
    size_t capacity, int *width, int *height, size_t *required_bytes);
/* close is idempotent, discards pending events/replies; no callbacks can occur.
 * destroy(&handle) also sets handle to NULL and is safe to repeat. */
void afc_mpv_bridge_close(afc_mpv_bridge *);
void afc_mpv_bridge_destroy(afc_mpv_bridge **);
#ifdef __cplusplus
}
#endif
#endif
