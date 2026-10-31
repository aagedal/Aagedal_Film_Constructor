#include "CNativeDecoder.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

/* Approximate timeline previews: thumbnails seek to the nearest decodable frame
 * and waveforms bin by timestamp. Unlike AFCDecoder, no exact-grid qualification
 * applies, so any stream FFmpeg decodes can be previewed. */
struct AFCPreview {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVStream *stream;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *sws;
    int stream_index;
    double zero;
};

static int preview_fail(char *error, size_t size, const char *format, ...) {
    if (error && size) {
        va_list args;
        va_start(args, format);
        vsnprintf(error, size, format, args);
        va_end(args);
    }
    return -1;
}

void afc_preview_close(AFCPreview *preview) {
    if (!preview) return;
    sws_freeContext(preview->sws);
    av_frame_free(&preview->frame);
    av_packet_free(&preview->packet);
    avcodec_free_context(&preview->codec);
    avformat_close_input(&preview->format);
    free(preview);
}

AFCPreview *afc_preview_open(const char *path, int stream_index, char *error, size_t error_size) {
    if (error && error_size) error[0] = '\0';
    struct stat file_stat;
    if (!path || path[0] != '/' || stat(path, &file_stat) != 0 || !S_ISREG(file_stat.st_mode)) {
        preview_fail(error, error_size, "Source must be an existing absolute local regular-file path");
        return NULL;
    }
    AFCPreview *preview = calloc(1, sizeof(*preview));
    if (!preview) return NULL;
    preview->stream_index = stream_index;
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int result = avformat_open_input(&preview->format, path, NULL, &options);
    av_dict_free(&options);
    if (result < 0 || avformat_find_stream_info(preview->format, NULL) < 0) {
        preview_fail(error, error_size, "Open local source for preview");
        goto invalid;
    }
    if (stream_index < 0 || (unsigned)stream_index >= preview->format->nb_streams) {
        preview_fail(error, error_size, "Container stream index %d is absent", stream_index);
        goto invalid;
    }
    preview->stream = preview->format->streams[stream_index];
    enum AVMediaType kind = preview->stream->codecpar->codec_type;
    if (kind != AVMEDIA_TYPE_VIDEO && kind != AVMEDIA_TYPE_AUDIO) {
        preview_fail(error, error_size, "Selected container stream is neither video nor audio");
        goto invalid;
    }
    /* Asset zero is the earliest video/audio stream start, matching the probe. */
    int have_zero = 0;
    for (unsigned i = 0; i < preview->format->nb_streams; ++i) {
        AVStream *stream = preview->format->streams[i];
        enum AVMediaType type = stream->codecpar->codec_type;
        if ((type != AVMEDIA_TYPE_VIDEO || (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) && type != AVMEDIA_TYPE_AUDIO) continue;
        double start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time * av_q2d(stream->time_base);
        if (!have_zero || start < preview->zero) { preview->zero = start; have_zero = 1; }
    }
    const AVCodec *codec = avcodec_find_decoder(preview->stream->codecpar->codec_id);
    preview->codec = codec ? avcodec_alloc_context3(codec) : NULL;
    preview->packet = av_packet_alloc();
    preview->frame = av_frame_alloc();
    if (!preview->codec || !preview->packet || !preview->frame ||
        avcodec_parameters_to_context(preview->codec, preview->stream->codecpar) < 0) {
        preview_fail(error, error_size, "Selected source codec has no decoder in this FFmpeg build");
        goto invalid;
    }
    preview->codec->pkt_timebase = preview->stream->time_base;
    preview->codec->max_pixels = 16LL * 1024 * 1024;
    if (avcodec_open2(preview->codec, codec, NULL) < 0) {
        preview_fail(error, error_size, "Initialize source decoder for preview");
        goto invalid;
    }
    return preview;
invalid:
    afc_preview_close(preview);
    return NULL;
}

/* Seconds of asset time at the decoded frame. */
static double frame_seconds(AFCPreview *preview) {
    int64_t pts = preview->frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) pts = preview->frame->pts;
    if (pts == AV_NOPTS_VALUE) return NAN;
    return pts * av_q2d(preview->stream->time_base) - preview->zero;
}

static int seek_to(AFCPreview *preview, double seconds) {
    double target = (seconds + preview->zero) / av_q2d(preview->stream->time_base);
    int64_t pts = target < (double)INT64_MIN ? INT64_MIN : target > (double)INT64_MAX ? INT64_MAX : (int64_t)target;
    if (av_seek_frame(preview->format, preview->stream_index, pts, AVSEEK_FLAG_BACKWARD) < 0 &&
        av_seek_frame(preview->format, preview->stream_index, pts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY) < 0)
        av_seek_frame(preview->format, -1, 0, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(preview->codec);
    return 0;
}

/* 1 for a frame, 0 at end of stream, negative on error. */
static int next(AFCPreview *preview, int *drained) {
    av_frame_unref(preview->frame);
    for (;;) {
        int result = avcodec_receive_frame(preview->codec, preview->frame);
        if (result == 0) return 1;
        if (result == AVERROR_EOF) return 0;
        if (result != AVERROR(EAGAIN) || *drained) return -1;
        for (;;) {
            result = av_read_frame(preview->format, preview->packet);
            if (result < 0) {
                avcodec_send_packet(preview->codec, NULL);
                *drained = 1;
                break;
            }
            if (preview->packet->stream_index != preview->stream_index) { av_packet_unref(preview->packet); continue; }
            result = avcodec_send_packet(preview->codec, preview->packet);
            av_packet_unref(preview->packet);
            /* Undecodable packets are skipped; previews tolerate damage. */
            if (result < 0 && result != AVERROR(EAGAIN)) continue;
            break;
        }
    }
}

int afc_preview_frame(AFCPreview *preview, double seconds, int max_width, int max_height,
                      uint8_t *rgba, size_t rgba_size, int *width, int *height, char *error, size_t error_size) {
    if (error && error_size) error[0] = '\0';
    if (!preview || preview->stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO || !rgba || !width || !height ||
        max_width < 1 || max_height < 1 || max_width > 4096 || max_height > 4096 || !isfinite(seconds) ||
        rgba_size < (size_t)max_width * max_height * 4)
        return preview_fail(error, error_size, "Invalid preview frame request");
    seek_to(preview, seconds);
    int drained = 0, found = 0;
    AVFrame *best = av_frame_alloc();
    if (!best) return preview_fail(error, error_size, "Allocate preview frame: out of memory");
    for (;;) {
        int result = next(preview, &drained);
        if (result < 0) { av_frame_free(&best); return preview_fail(error, error_size, "Decode preview frame"); }
        if (!result) break;
        av_frame_unref(best);
        av_frame_ref(best, preview->frame);
        found = 1;
        double time = frame_seconds(preview);
        /* The first frame at or after the request, or the last before end of stream. */
        if (isnan(time) || time + 1e-6 >= seconds) break;
    }
    if (!found) { av_frame_free(&best); return preview_fail(error, error_size, "No decodable frame at the requested time"); }
    AVRational aspect = av_guess_sample_aspect_ratio(preview->format, preview->stream, best);
    double display = best->width * (aspect.num > 0 && aspect.den > 0 ? av_q2d(aspect) : 1.0);
    double scale = fmin((double)max_width / display, (double)max_height / best->height);
    int w = (int)fmax(1, lround(display * scale)), h = (int)fmax(1, lround(best->height * scale));
    if (w > max_width) w = max_width;
    if (h > max_height) h = max_height;
    preview->sws = sws_getCachedContext(preview->sws, best->width, best->height, best->format,
        w, h, AV_PIX_FMT_RGBA, SWS_BICUBIC, NULL, NULL, NULL);
    if (!preview->sws) { av_frame_free(&best); return preview_fail(error, error_size, "Initialize preview conversion"); }
    uint8_t *planes[4] = { rgba, NULL, NULL, NULL };
    int strides[4] = { w * 4, 0, 0, 0 };
    int scaled = sws_scale(preview->sws, (const uint8_t * const *)best->data, best->linesize, 0, best->height, planes, strides);
    av_frame_free(&best);
    if (scaled != h) return preview_fail(error, error_size, "Convert preview frame");
    *width = w;
    *height = h;
    return 0;
}

int afc_preview_peaks(AFCPreview *preview, double start, double duration, int bins,
                      const int *channels, int channel_count, float *peaks, size_t peak_count,
                      char *error, size_t error_size) {
    if (error && error_size) error[0] = '\0';
    if (!preview || preview->stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO || !channels || !peaks ||
        bins < 1 || bins > 100000 || channel_count < 1 || channel_count > 64 || !isfinite(start) ||
        !isfinite(duration) || duration <= 0 || peak_count < (size_t)bins * channel_count)
        return preview_fail(error, error_size, "Invalid waveform request");
    memset(peaks, 0, (size_t)bins * channel_count * sizeof(float));
    seek_to(preview, start);
    SwrContext *swr = NULL;
    float *samples = NULL;
    int capacity = 0, drained = 0, status = 0;
    for (;;) {
        int result = next(preview, &drained);
        if (result < 0) { status = preview_fail(error, error_size, "Decode waveform audio"); break; }
        if (!result) break;
        AVFrame *frame = preview->frame;
        double time = frame_seconds(preview);
        if (isnan(time) || frame->sample_rate <= 0) continue;
        if (time >= start + duration) break;
        int count = frame->ch_layout.nb_channels;
        if (count < 1 || count > 64) continue;
        /* Convert to interleaved float in the stream's own (FFmpeg) channel order. */
        if (!swr) {
            if (swr_alloc_set_opts2(&swr, &frame->ch_layout, AV_SAMPLE_FMT_FLT, frame->sample_rate,
                                    &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL) < 0 || swr_init(swr) < 0) {
                status = preview_fail(error, error_size, "Initialize waveform conversion");
                break;
            }
        }
        if (frame->nb_samples * count > capacity) {
            capacity = frame->nb_samples * count;
            float *grown = realloc(samples, capacity * sizeof(float));
            if (!grown) { status = preview_fail(error, error_size, "Allocate waveform buffer"); break; }
            samples = grown;
        }
        uint8_t *output[1] = { (uint8_t *)samples };
        int converted = swr_convert(swr, output, frame->nb_samples, (const uint8_t **)frame->extended_data, frame->nb_samples);
        if (converted < 0) { status = preview_fail(error, error_size, "Convert waveform audio"); break; }
        for (int i = 0; i < converted; ++i) {
            double relative = time + (double)i / frame->sample_rate - start;
            if (relative < 0 || relative >= duration) continue;
            int bin = (int)(relative / duration * bins);
            if (bin >= bins) bin = bins - 1;
            for (int c = 0; c < channel_count; ++c) {
                if (channels[c] < 0 || channels[c] >= count) continue;
                float amplitude = fabsf(samples[i * count + channels[c]]);
                if (!isfinite(amplitude)) continue;
                if (amplitude > 1) amplitude = 1;
                float *peak = &peaks[(size_t)c * bins + bin];
                if (amplitude > *peak) *peak = amplitude;
            }
        }
    }
    swr_free(&swr);
    free(samples);
    return status;
}
