#ifndef C_NATIVE_DECODER_H
#define C_NATIVE_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Development-only, serialized decoder. Each instance owns one exact container
 * stream and must be used by only one caller at a time. Paths must be absolute
 * local regular files. Closing NULL is safe. Error text is optional.
 *
 * Video is progressive, square-pixel, untransformed SDR at an exact constant
 * rational rate. Audio is uncompressed integer/float PCM; conversion to float
 * preserves every source channel and does not resample or remix. Unsupported
 * timing, geometry, media kinds, and codec/rate combinations fail explicitly.
 * The first request qualifies all decoded timestamps with bounded memory; this
 * deliberate development check is not a playback startup-performance design.
 */
typedef struct AFCDecoder AFCDecoder;

AFCDecoder *afc_decoder_open(const char *path, int stream_index,
                             char *error, size_t error_size);
/** Qualify a single-frame PNG/JPEG pipe with one image stream. Animated images
 * and container video disguised as images fail. The decoded image is retained
 * once; timeline source trims have no bearing on subsequent extraction. */
AFCDecoder *afc_decoder_open_still(const char *path, int stream_index,
                                 char *error, size_t error_size);
/** Bicubic straight-alpha RGBA32 still extraction. Dimensions are 1...4096. */
int afc_decoder_scaled_still(AFCDecoder *decoder, int width, int height,
                            uint8_t *rgba, size_t rgba_size, char *error, size_t error_size);
void afc_decoder_close(AFCDecoder *decoder);
int afc_decoder_width(const AFCDecoder *decoder);
int afc_decoder_height(const AFCDecoder *decoder);
int afc_decoder_channels(const AFCDecoder *decoder);
int afc_decoder_sample_rate(const AFCDecoder *decoder);
/** Retained decoded AVFrame buffers plus allocated float conversion capacity.
 * Counts references conservatively; excludes codec/demuxer/scaler/resampler
 * internal memory, packets, transient decode allocations and caller output. */
size_t afc_decoder_retained_bytes(const AFCDecoder *decoder);
const char *afc_decoder_version(void);

/** Extract one exact source frame as tightly packed RGB24 at native dimensions.
 * rate_num/rate_den is frames per second. Buffer capacity must be at least
 * width * height * 3. Returns zero or a negative error; on error output may be
 * partially written and must not be consumed.
 */
int afc_decoder_video(AFCDecoder *decoder, int64_t source_frame,
                      int64_t rate_num, int64_t rate_den,
                      uint8_t *rgb, size_t rgb_size,
                      char *error, size_t error_size);

/** Bicubic spatial conversion of a qualified frame to a bounded RGB24 raster.
 * This is not color-management qualification. Source PAR/orientation rejects
 * apply identically to native-size extraction. Both dimensions are 1...4096.
 */
int afc_decoder_scaled_video(AFCDecoder *decoder, int width, int height, int64_t source_frame,
                      int64_t rate_num, int64_t rate_den,
                      uint8_t *rgb, size_t rgb_size,
                      char *error, size_t error_size);

/** Extract [start_sample, start_sample + sample_count) from the absolute source
 * sample grid. Capacity is in floats, not bytes: sample_count * source channels.
 * Requested rate must equal the source rate. EOF is an error rather than silent
 * padding; a zero-length request at EOF is valid. Returns zero or negative.
 */
int afc_decoder_audio(AFCDecoder *decoder, int64_t start_sample,
                      int sample_count, int sample_rate,
                      float *interleaved, size_t float_count,
                      char *error, size_t error_size);

/** Import probe: libavformat's view of a local file as the app's media model.
 * Every packet is demuxed once (bounded like AVFoundation import qualification)
 * so durations, offsets and frame cadence come from packet timing, never from
 * avg_frame_rate. Stream indices are FFmpeg's, which export maps by. */
typedef struct AFCProbe AFCProbe;

enum { AFC_PROBE_VIDEO = 0, AFC_PROBE_AUDIO = 1 };
/** Mono and stereo by channel count; 5.1 only when FFmpeg decodes L R C LFE Ls Rs. */
enum { AFC_PROBE_LAYOUT_UNKNOWN = 0, AFC_PROBE_LAYOUT_MONO, AFC_PROBE_LAYOUT_STEREO, AFC_PROBE_LAYOUT_SURROUND51 };

typedef struct {
    int index;                 /* container stream index */
    int kind;                  /* AFC_PROBE_VIDEO or AFC_PROBE_AUDIO */
    int time_base_num, time_base_den;
    int64_t start_pts;         /* first presentation timestamp */
    int64_t duration_pts;      /* presentation extent from start_pts */
    int64_t offset_num, offset_den; /* start relative to the earliest stream, in seconds */
    char codec[32];
    /* Video. frame_duration is the proven constant cadence in time-base ticks,
     * zero when packet timing does not prove one (or the scan budget ran out). */
    int width, height;
    int square_untransformed;
    int64_t frame_duration;
    /* Audio. sample_exact: every packet tiles the sample grid contiguously. */
    int channels, sample_rate, layout;
    int sample_exact;
} AFCProbeStream;

AFCProbe *afc_probe_open(const char *path, char *error, size_t error_size);
void afc_probe_close(AFCProbe *probe);
const char *afc_probe_format_name(const AFCProbe *probe);
int afc_probe_stream_count(const AFCProbe *probe);
int afc_probe_stream(const AFCProbe *probe, int position, AFCProbeStream *stream);
/** Asset duration: the latest stream end measured from the earliest stream start. */
int afc_probe_duration(const AFCProbe *probe, int64_t *numerator, int64_t *denominator);
/** First-frame embedded timecode as a frame count and its frame duration in
 * seconds (QuickTime tmcd rate, else the picture rate). Nonzero when absent. */
int afc_probe_timecode(const AFCProbe *probe, int64_t *frames, int64_t *frame_numerator, int64_t *frame_denominator);

/** Approximate timeline previews (thumbnails, waveforms) for any decodable
 * stream. Times are asset seconds, zero at the earliest stream start. */
typedef struct AFCPreview AFCPreview;
AFCPreview *afc_preview_open(const char *path, int stream_index, char *error, size_t error_size);
void afc_preview_close(AFCPreview *preview);
/** RGBA32 of the first frame at or after `seconds`, fitted within max_width x
 * max_height (1...4096) with display aspect; output dimensions are returned. */
int afc_preview_frame(AFCPreview *preview, double seconds, int max_width, int max_height,
                      uint8_t *rgba, size_t rgba_size, int *width, int *height, char *error, size_t error_size);
/** Absolute peaks (clamped to 1) of source channels in FFmpeg order, channel-major
 * `bins` values each, over [start, start + duration). */
int afc_preview_peaks(AFCPreview *preview, double start, double duration, int bins,
                      const int *channels, int channel_count, float *peaks, size_t peak_count,
                      char *error, size_t error_size);

/** libmpv Source viewer player; no libmpv type crosses this ABI.
 *
 * Two serial callers: a control caller for everything except render, and a
 * render caller for afc_source_render/afc_source_release_render only. The render
 * caller must never wait on the control caller. Release the render context on
 * the render caller before close/destroy, which may otherwise do it themselves.
 * No foreign callbacks are installed: keep polling events and rendering.
 *
 * open accepts absolute local regular files and container ff-index values (-1
 * disables that media type) and starts paused. With external_audio, audio is
 * that file's ff-index stream (proxy picture with original sound) and
 * audio_delay aligns it. OPENED means explicit track selection finished and
 * both selected IDs were read back. Timestamps are raw container time (no
 * start-time rebase). Exact seeks show the first frame at or after the target;
 * COMMAND_REPLY acknowledges execution and PLAYBACK_RESTART, which can coalesce,
 * follows decoding. Load/track failures are terminal: destroy and recreate.
 * Negative statuses are the errors below or unmodified libmpv error codes.
 */
typedef struct AFCSourcePlayer AFCSourcePlayer;
enum { AFC_SOURCE_INVALID = -1000, AFC_SOURCE_STATE = -1001,
       AFC_SOURCE_BUSY = -1002, AFC_SOURCE_TRACK = -1003 };
typedef enum {
    AFC_SOURCE_OPENED = 1, AFC_SOURCE_COMMAND_REPLY, AFC_SOURCE_PLAYBACK_RESTART,
    AFC_SOURCE_POSITION, AFC_SOURCE_PAUSE, AFC_SOURCE_END_FILE, AFC_SOURCE_ERROR,
    AFC_SOURCE_SHUTDOWN
} AFCSourceEventType;
typedef struct {
    AFCSourceEventType type;
    uint64_t request_id;
    int status;
    double seconds;
    int paused;
    int64_t video_track_id;
    int64_t audio_track_id;
    int end_reason; /* libmpv end reason; EOF is zero. */
    char message[256];
} AFCSourceEvent;
/** audio_output: 1 plays through CoreAudio, 0 decodes to a null output. */
int afc_source_create(AFCSourcePlayer **out, int audio_output, char *error, size_t capacity);
int afc_source_open(AFCSourcePlayer *player, const char *path, int video_ff_index, int audio_ff_index,
                    const char *external_audio, double audio_delay, uint64_t request_id);
/** Raw container seconds. Request IDs are nonzero and unique among pending requests. */
int afc_source_seek(AFCSourcePlayer *player, double seconds, uint64_t request_id);
int afc_source_set_paused(AFCSourcePlayer *player, int paused, uint64_t request_id);
/** Event count or a negative error; capacity and budget are 1...1024. */
int afc_source_poll(AFCSourcePlayer *player, AFCSourceEvent *events, size_t capacity, size_t budget);
/** Last observed time-pos (raw container seconds); STATE until one is observed. */
int afc_source_position(AFCSourcePlayer *player, double *seconds);
/** Current time-pos read synchronously from the core (control caller). */
int afc_source_time_pos(AFCSourcePlayer *player, double *seconds);
/** Display size of the selected video (control caller; may briefly block). */
int afc_source_video_size(AFCSourcePlayer *player, int *width, int *height);
/** Render caller: 1 when a frame was drawn into the bgr0 surface (B G R X bytes),
 * 0 when nothing changed. force redraws the current frame. stride is bytes per row. */
int afc_source_render(AFCSourcePlayer *player, int width, int height, uint8_t *bgr0, size_t stride, int force);
void afc_source_release_render(AFCSourcePlayer *player);
void afc_source_close(AFCSourcePlayer *player);
void afc_source_destroy(AFCSourcePlayer **player);
/** Asset zero in raw container seconds (the earliest audio/video stream start,
 * as the import probe defines it) and the first video ff-index, or -1. */
int afc_source_media_origin(const char *path, int64_t *numerator, int64_t *denominator,
                            int *first_video_index, char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
