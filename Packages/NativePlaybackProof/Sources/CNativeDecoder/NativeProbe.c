#include "CNativeDecoder.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/timecode.h>

/* The same work bounds as AVFoundation import qualification: a bounded scan
 * leaves the file importable with an unproven cadence. */
#define AFC_PROBE_MAX_STREAMS 64
#define AFC_PROBE_MAX_VIDEO_PACKETS 100000
#define AFC_PROBE_MAX_PACKETS 2000000
#define AFC_PROBE_SECONDS 5.0

typedef struct {
    int container_index;
    int64_t first_pts;
    int64_t end_pts;
    int64_t *pts;
    int64_t *durations;
    int count;
    int capacity;
    int timing_valid;
    int sample_exact;
    int64_t next_sample;
} ProbeScan;

struct AFCProbe {
    char format_name[64];
    int count;
    AFCProbeStream streams[AFC_PROBE_MAX_STREAMS];
    int64_t asset_num;
    int64_t asset_den;
    int has_timecode;
    int64_t timecode_frames;
    int64_t timecode_num;
    int64_t timecode_den;
};

static int probe_fail(char *error, size_t size, const char *format, ...) {
    if (error && size) {
        va_list args;
        va_start(args, format);
        vsnprintf(error, size, format, args);
        va_end(args);
    }
    return -1;
}

/* n/d reduced into 64 bits; fails rather than rounding. */
static int reduce(__int128 n, __int128 d, int64_t *num, int64_t *den) {
    if (d <= 0) return -1;
    __int128 a = n < 0 ? -n : n, b = d;
    while (b) { __int128 rest = a % b; a = b; b = rest; }
    if (a == 0) a = 1;
    n /= a; d /= a;
    if (n > INT64_MAX || n < INT64_MIN || d > INT64_MAX) return -1;
    *num = (int64_t)n;
    *den = (int64_t)d;
    return 0;
}

static int exact_seconds(int64_t value, AVRational time_base, int64_t *num, int64_t *den) {
    return reduce((__int128)value * time_base.num, time_base.den, num, den);
}

static int square(AVRational ratio) {
    return ratio.num == 0 || (ratio.num > 0 && ratio.num == ratio.den);
}

static int untransformed(const AVCodecParameters *parameters) {
    const AVPacketSideData *matrix = av_packet_side_data_get(parameters->coded_side_data,
        parameters->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (!matrix) return 1;
    if (matrix->size < 9 * sizeof(int32_t)) return 0;
    const int32_t identity[9] = { 65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824 };
    return memcmp(matrix->data, identity, sizeof(identity)) == 0;
}

/* Mono and stereo by count, like AVFoundation import. Six channels are 5.1 only
 * when FFmpeg decodes them as L R C LFE Ls Rs (back or side surrounds). */
static int layout_kind(const AVChannelLayout *layout) {
    if (layout->nb_channels == 1) return AFC_PROBE_LAYOUT_MONO;
    if (layout->nb_channels == 2) return AFC_PROBE_LAYOUT_STEREO;
    if (layout->nb_channels != 6 || layout->order == AV_CHANNEL_ORDER_UNSPEC) return AFC_PROBE_LAYOUT_UNKNOWN;
    static const enum AVChannel expected[6][2] = {
        { AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_LEFT }, { AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_RIGHT },
        { AV_CHAN_FRONT_CENTER, AV_CHAN_FRONT_CENTER }, { AV_CHAN_LOW_FREQUENCY, AV_CHAN_LOW_FREQUENCY },
        { AV_CHAN_BACK_LEFT, AV_CHAN_SIDE_LEFT }, { AV_CHAN_BACK_RIGHT, AV_CHAN_SIDE_RIGHT }
    };
    for (int i = 0; i < 6; ++i) {
        enum AVChannel channel = av_channel_layout_channel_from_index(layout, i);
        if (channel != expected[i][0] && channel != expected[i][1]) return AFC_PROBE_LAYOUT_UNKNOWN;
    }
    return AFC_PROBE_LAYOUT_SURROUND51;
}

static int compare_pts(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}

/* A proven cadence: every presentation interval and every packet duration is
 * the same positive tick count, as AVFoundation import requires of samples. */
static int64_t proven_cadence(ProbeScan *scan) {
    if (!scan->timing_valid || scan->count < 2 || !scan->pts) return 0;
    for (int i = 0; i < scan->count; ++i) {
        if (scan->durations[i] <= 0) return 0;
    }
    int64_t duration = scan->durations[0];
    for (int i = 1; i < scan->count; ++i) {
        if (scan->durations[i] != duration) return 0;
    }
    qsort(scan->pts, scan->count, sizeof(int64_t), compare_pts);
    int64_t cadence = scan->pts[1] - scan->pts[0];
    if (cadence <= 0 || cadence != duration) return 0;
    for (int i = 1; i < scan->count; ++i) {
        if (scan->pts[i] - scan->pts[i - 1] != cadence) return 0;
    }
    return cadence;
}

/* Audio packets must tile the sample grid exactly, as the native decoder's
 * qualification of decoded frames requires (Matroska's ms clock does not). */
static void sample_grid(ProbeScan *scan, const AVPacket *packet, const AVStream *stream) {
    int64_t rate = stream->codecpar->sample_rate;
    __int128 start = (__int128)packet->pts * stream->time_base.num * rate;
    __int128 length = (__int128)packet->duration * stream->time_base.num * rate;
    if (packet->pts == AV_NOPTS_VALUE || packet->duration <= 0 ||
        start % stream->time_base.den || length % stream->time_base.den) { scan->sample_exact = 0; return; }
    int64_t first = (int64_t)(start / stream->time_base.den);
    if (scan->next_sample != INT64_MIN && first != scan->next_sample) { scan->sample_exact = 0; return; }
    scan->next_sample = first + (int64_t)(length / stream->time_base.den);
}

static double now_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

/* Embedded start timecode: a QuickTime tmcd track's own rate first, then a
 * video stream tag (MXF material package, Matroska tags) at the picture rate. */
static void read_timecode(AFCProbe *probe, AVFormatContext *format, const int64_t *cadences) {
    const char *text = NULL;
    AVRational rate = { 0, 1 };
    for (unsigned i = 0; i < format->nb_streams && !text; ++i) {
        AVStream *stream = format->streams[i];
        AVDictionaryEntry *entry = av_dict_get(stream->metadata, "timecode", NULL, 0);
        if (entry && stream->codecpar->codec_type == AVMEDIA_TYPE_DATA &&
            stream->codecpar->codec_tag == MKTAG('t', 'm', 'c', 'd') && stream->avg_frame_rate.num > 0) {
            text = entry->value;
            rate = stream->avg_frame_rate;
        }
    }
    for (int i = 0; i < probe->count && !text; ++i) {
        if (probe->streams[i].kind != AFC_PROBE_VIDEO) continue;
        AVStream *stream = format->streams[probe->streams[i].index];
        AVDictionaryEntry *entry = av_dict_get(stream->metadata, "timecode", NULL, 0);
        if (!entry) entry = av_dict_get(format->metadata, "timecode", NULL, 0);
        if (!entry) continue;
        if (cadences[i] > 0) rate = av_make_q(stream->time_base.den, (int)(cadences[i] * stream->time_base.num));
        else if (stream->r_frame_rate.num > 0) rate = stream->r_frame_rate;
        else continue;
        text = entry->value;
    }
    if (!text || rate.num <= 0 || rate.den <= 0) return;
    AVTimecode timecode;
    if (av_timecode_init_from_string(&timecode, rate, text, NULL) < 0 || timecode.start <= 0) return;
    /* Seconds are frames x frame duration, as QuickTime timecode samples count. */
    if (reduce(rate.den, rate.num, &probe->timecode_num, &probe->timecode_den) < 0) return;
    probe->has_timecode = 1;
    probe->timecode_frames = timecode.start;
}

AFCProbe *afc_probe_open(const char *path, char *error, size_t error_size) {
    if (error && error_size) error[0] = '\0';
    struct stat file_stat;
    if (!path || path[0] != '/' || stat(path, &file_stat) != 0 || !S_ISREG(file_stat.st_mode)) {
        probe_fail(error, error_size, "Source must be an existing absolute local regular-file path");
        return NULL;
    }
    AFCProbe *probe = calloc(1, sizeof(*probe));
    AVFormatContext *format = NULL;
    AVPacket *packet = av_packet_alloc();
    ProbeScan scans[AFC_PROBE_MAX_STREAMS] = {0};
    int64_t cadences[AFC_PROBE_MAX_STREAMS] = {0};
    if (!probe || !packet) {
        probe_fail(error, error_size, "Allocate probe: out of memory");
        goto invalid;
    }
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int result = avformat_open_input(&format, path, NULL, &options);
    av_dict_free(&options);
    if (result < 0) {
        probe_fail(error, error_size, "Open local source: %s", av_err2str(result));
        goto invalid;
    }
    result = avformat_find_stream_info(format, NULL);
    if (result < 0) {
        probe_fail(error, error_size, "Inspect source streams: %s", av_err2str(result));
        goto invalid;
    }
    snprintf(probe->format_name, sizeof(probe->format_name), "%s", format->iformat->name);
    /* Image demuxers are stills or numbered sequences, which import handles separately. */
    if (format->iformat->flags & AVFMT_NOFILE || strstr(format->iformat->name, "_pipe") || !strcmp(format->iformat->name, "image2")) {
        probe_fail(error, error_size, "Image files are not probed as movies");
        goto invalid;
    }
    /* Streams a demuxer adds while reading (no header) stay unmapped. */
    int stream_of[AFC_PROBE_MAX_STREAMS];
    for (int i = 0; i < AFC_PROBE_MAX_STREAMS; ++i) stream_of[i] = -1;
    for (unsigned i = 0; i < format->nb_streams; ++i) {
        AVStream *stream = format->streams[i];
        AVCodecParameters *parameters = stream->codecpar;
        int video = parameters->codec_type == AVMEDIA_TYPE_VIDEO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC);
        int audio = parameters->codec_type == AVMEDIA_TYPE_AUDIO;
        if (!video && !audio) continue;
        if (i >= AFC_PROBE_MAX_STREAMS) {
            probe_fail(error, error_size, "Source has more streams than the probe supports");
            goto invalid;
        }
        if (stream->time_base.num <= 0 || stream->time_base.den <= 0) {
            probe_fail(error, error_size, "Stream %u has an invalid time base", i);
            goto invalid;
        }
        AFCProbeStream *out = &probe->streams[probe->count];
        out->index = (int)i;
        out->kind = video ? AFC_PROBE_VIDEO : AFC_PROBE_AUDIO;
        out->time_base_num = stream->time_base.num;
        out->time_base_den = stream->time_base.den;
        const AVCodecDescriptor *codec = avcodec_descriptor_get(parameters->codec_id);
        snprintf(out->codec, sizeof(out->codec), "%s", codec ? codec->name : "unknown");
        if (video) {
            out->width = parameters->width;
            out->height = parameters->height;
            out->square_untransformed = parameters->width > 0 && parameters->height > 0 &&
                square(parameters->sample_aspect_ratio) && square(stream->sample_aspect_ratio) && untransformed(parameters);
        } else {
            out->channels = parameters->ch_layout.nb_channels;
            out->sample_rate = parameters->sample_rate;
            out->layout = layout_kind(&parameters->ch_layout);
            if (out->channels < 1 || out->channels > 64 || out->sample_rate <= 0) {
                probe_fail(error, error_size, "Stream %u has an unsupported audio channel count or rate", i);
                goto invalid;
            }
        }
        ProbeScan *scan = &scans[probe->count];
        scan->container_index = (int)i;
        scan->first_pts = INT64_MAX;
        scan->end_pts = INT64_MIN;
        scan->timing_valid = 1;
        scan->sample_exact = audio;
        scan->next_sample = INT64_MIN;
        stream_of[i] = probe->count;
        probe->count++;
    }
    if (!probe->count) {
        probe_fail(error, error_size, "This file has no supported video or audio tracks.");
        goto invalid;
    }

    /* Demux every packet once: presentation extents for all streams and the
     * full video timestamp grid, bounded like AVFoundation's sample scan. */
    double deadline = now_seconds() + AFC_PROBE_SECONDS;
    long packets = 0;
    int complete = 0;
    for (;;) {
        result = av_read_frame(format, packet);
        if (result == AVERROR_EOF) { complete = 1; break; }
        if (result < 0) break;
        int slot = packet->stream_index < AFC_PROBE_MAX_STREAMS ? stream_of[packet->stream_index] : -1;
        if (slot >= 0 && !(packet->flags & AV_PKT_FLAG_DISCARD)) {
            ProbeScan *scan = &scans[slot];
            if (scan->sample_exact) sample_grid(scan, packet, format->streams[packet->stream_index]);
            if (packet->pts == AV_NOPTS_VALUE) scan->timing_valid = 0;
            else {
                if (packet->pts < scan->first_pts) scan->first_pts = packet->pts;
                int64_t end = packet->pts + (packet->duration > 0 ? packet->duration : 0);
                if (end > scan->end_pts) scan->end_pts = end;
                if (probe->streams[slot].kind == AFC_PROBE_VIDEO && scan->timing_valid) {
                    if (scan->count == AFC_PROBE_MAX_VIDEO_PACKETS) scan->timing_valid = 0;
                    else {
                        if (scan->count == scan->capacity) {
                            int capacity = scan->capacity ? scan->capacity * 2 : 1024;
                            int64_t *pts = realloc(scan->pts, capacity * sizeof(int64_t));
                            if (pts) scan->pts = pts;
                            int64_t *durations = pts ? realloc(scan->durations, capacity * sizeof(int64_t)) : NULL;
                            if (durations) scan->durations = durations;
                            if (!pts || !durations) {
                                av_packet_unref(packet);
                                probe_fail(error, error_size, "Allocate probe timing: out of memory");
                                goto invalid;
                            }
                            scan->capacity = capacity;
                        }
                        scan->pts[scan->count] = packet->pts;
                        scan->durations[scan->count] = packet->duration;
                        scan->count++;
                    }
                }
            }
        }
        av_packet_unref(packet);
        if (++packets >= AFC_PROBE_MAX_PACKETS || ((packets & 255) == 0 && now_seconds() > deadline)) break;
    }

    /* The earliest stream defines asset zero; other streams keep their offset. */
    int64_t zero_num = 0, zero_den = 1;
    int have_zero = 0;
    int64_t start_num[AFC_PROBE_MAX_STREAMS], start_den[AFC_PROBE_MAX_STREAMS];
    for (int i = 0; i < probe->count; ++i) {
        AVStream *stream = format->streams[probe->streams[i].index];
        int64_t start = complete && scans[i].first_pts != INT64_MAX ? scans[i].first_pts
            : stream->start_time != AV_NOPTS_VALUE ? stream->start_time : 0;
        probe->streams[i].start_pts = start;
        if (exact_seconds(start, stream->time_base, &start_num[i], &start_den[i]) < 0) {
            probe_fail(error, error_size, "Stream start time is not representable");
            goto invalid;
        }
        if (!have_zero || (__int128)start_num[i] * zero_den < (__int128)zero_num * start_den[i]) {
            zero_num = start_num[i]; zero_den = start_den[i]; have_zero = 1;
        }
    }
    __int128 asset_num = 0, asset_den = 1;
    for (int i = 0; i < probe->count; ++i) {
        AFCProbeStream *out = &probe->streams[i];
        AVStream *stream = format->streams[out->index];
        if (out->kind == AFC_PROBE_VIDEO && complete) cadences[i] = proven_cadence(&scans[i]);
        out->frame_duration = cadences[i];
        out->sample_exact = out->kind == AFC_PROBE_AUDIO && complete && scans[i].sample_exact;
        if (cadences[i] > 0) out->duration_pts = (int64_t)scans[i].count * cadences[i];
        else if (complete && scans[i].end_pts > scans[i].first_pts && scans[i].first_pts != INT64_MAX)
            out->duration_pts = scans[i].end_pts - scans[i].first_pts;
        else if (stream->duration > 0 && stream->duration != AV_NOPTS_VALUE)
            out->duration_pts = stream->duration;
        else if (format->duration > 0)
            out->duration_pts = av_rescale_q(format->duration, AV_TIME_BASE_Q, stream->time_base);
        /* Offset from asset zero, as a reduced exact fraction. */
        if (reduce((__int128)start_num[i] * zero_den - (__int128)zero_num * start_den[i],
                   (__int128)start_den[i] * zero_den, &out->offset_num, &out->offset_den) < 0) {
            probe_fail(error, error_size, "Stream offset is not representable");
            goto invalid;
        }
        int64_t extent_num, extent_den;
        if (exact_seconds(out->duration_pts, stream->time_base, &extent_num, &extent_den) < 0) {
            probe_fail(error, error_size, "Stream duration is not representable");
            goto invalid;
        }
        /* end = offset + extent; the asset lasts until the latest stream end. */
        __int128 end_num = (__int128)out->offset_num * extent_den + (__int128)extent_num * out->offset_den;
        __int128 end_den = (__int128)out->offset_den * extent_den;
        if (end_num * asset_den > asset_num * end_den) { asset_num = end_num; asset_den = end_den; }
    }
    if (asset_num <= 0) {
        probe_fail(error, error_size, "The media does not have a finite, positive duration.");
        goto invalid;
    }
    if (reduce(asset_num, asset_den, &probe->asset_num, &probe->asset_den) < 0) {
        probe_fail(error, error_size, "Duration is not representable");
        goto invalid;
    }
    read_timecode(probe, format, cadences);
    for (int i = 0; i < probe->count; ++i) { free(scans[i].pts); free(scans[i].durations); }
    av_packet_free(&packet);
    avformat_close_input(&format);
    return probe;
invalid:
    for (int i = 0; i < AFC_PROBE_MAX_STREAMS; ++i) { free(scans[i].pts); free(scans[i].durations); }
    av_packet_free(&packet);
    avformat_close_input(&format);
    free(probe);
    return NULL;
}

void afc_probe_close(AFCProbe *probe) { free(probe); }
int afc_probe_stream_count(const AFCProbe *probe) { return probe ? probe->count : 0; }
const char *afc_probe_format_name(const AFCProbe *probe) { return probe ? probe->format_name : ""; }

int afc_probe_stream(const AFCProbe *probe, int position, AFCProbeStream *stream) {
    if (!probe || !stream || position < 0 || position >= probe->count) return -1;
    *stream = probe->streams[position];
    return 0;
}

int afc_probe_duration(const AFCProbe *probe, int64_t *numerator, int64_t *denominator) {
    if (!probe || !numerator || !denominator) return -1;
    *numerator = probe->asset_num;
    *denominator = probe->asset_den;
    return 0;
}

int afc_probe_timecode(const AFCProbe *probe, int64_t *frames, int64_t *frame_numerator, int64_t *frame_denominator) {
    if (!probe || !probe->has_timecode || !frames || !frame_numerator || !frame_denominator) return -1;
    *frames = probe->timecode_frames;
    *frame_numerator = probe->timecode_num;
    *frame_denominator = probe->timecode_den;
    return 0;
}
