#include "CNativeDecoder.h"

#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

/* Development limits keep decoded rasters and conversion buffers bounded. */
#define AFC_MAX_PIXELS (16LL * 1024 * 1024)
#define AFC_MAX_CHANNELS 64
#define AFC_MAX_AUDIO_FLOATS (16LL * 1024 * 1024)
#define AFC_MAX_PACKET_BYTES (64 * 1024 * 1024)

struct AFCDecoder {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVStream *stream;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *sws;
    SwrContext *swr;
    AVChannelLayout audio_layout;
    enum AVMediaType kind;
    int stream_index;
    int width;
    int height;
    int channels;
    int sample_rate;
    int audio_format;
    int drain_sent;
    int cached;
    int qualified;
    int needs_seek;
    AVRational video_rate;
    int64_t total_units;
    int64_t cached_unit;
    float *audio_buffer;
    size_t audio_buffer_capacity;
    int audio_buffer_valid;
};

static void clear_error(char *error, size_t size) {
    if (error && size) error[0] = '\0';
}

static int fail(char *error, size_t size, const char *format, ...) {
    if (error && size) {
        va_list args;
        va_start(args, format);
        vsnprintf(error, size, format, args);
        va_end(args);
    }
    return AVERROR(EINVAL);
}

static int ff_fail(char *error, size_t size, const char *operation, int code) {
    char detail[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, detail, sizeof(detail));
    fail(error, size, "%s: %s", operation, detail);
    return code < 0 ? code : AVERROR(EINVAL);
}

static int square_pixels(AVRational ratio) {
    return ratio.num == 0 || (ratio.num > 0 && ratio.num == ratio.den);
}

static int identity_matrix(const uint8_t *data, size_t size) {
    const int32_t identity[9] = {
        65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824
    };
    int32_t matrix[9];
    if (size < sizeof(matrix)) return 0;
    memcpy(matrix, data, sizeof(matrix));
    return memcmp(matrix, identity, sizeof(matrix)) == 0;
}

static int pcm_codec(enum AVCodecID codec) {
    switch (codec) {
    case AV_CODEC_ID_PCM_S8:
    case AV_CODEC_ID_PCM_U8:
    case AV_CODEC_ID_PCM_S16LE:
    case AV_CODEC_ID_PCM_S16BE:
    case AV_CODEC_ID_PCM_U16LE:
    case AV_CODEC_ID_PCM_U16BE:
    case AV_CODEC_ID_PCM_S24LE:
    case AV_CODEC_ID_PCM_S24BE:
    case AV_CODEC_ID_PCM_U24LE:
    case AV_CODEC_ID_PCM_U24BE:
    case AV_CODEC_ID_PCM_S32LE:
    case AV_CODEC_ID_PCM_S32BE:
    case AV_CODEC_ID_PCM_U32LE:
    case AV_CODEC_ID_PCM_U32BE:
    case AV_CODEC_ID_PCM_S64LE:
    case AV_CODEC_ID_PCM_S64BE:
    case AV_CODEC_ID_PCM_F32LE:
    case AV_CODEC_ID_PCM_F32BE:
    case AV_CODEC_ID_PCM_F64LE:
    case AV_CODEC_ID_PCM_F64BE:
    case AV_CODEC_ID_PCM_S8_PLANAR:
    case AV_CODEC_ID_PCM_S16LE_PLANAR:
    case AV_CODEC_ID_PCM_S16BE_PLANAR:
    case AV_CODEC_ID_PCM_S24LE_PLANAR:
    case AV_CODEC_ID_PCM_S32LE_PLANAR:
        return 1;
    default:
        return 0;
    }
}

/* Receive presentation-order frames, including delayed B-frames at EOF. A
 * successful receive owns frame until the next call/reset/close. */
static int next_frame(AFCDecoder *decoder, char *error, size_t size) {
    av_frame_unref(decoder->frame);
    decoder->cached = 0;
    decoder->audio_buffer_valid = 0;
    for (;;) {
        int result = avcodec_receive_frame(decoder->codec, decoder->frame);
        if (result == 0) return 1;
        if (result == AVERROR_EOF) return 0;
        if (result != AVERROR(EAGAIN))
            return ff_fail(error, size, "Receive decoded frame", result);
        if (decoder->drain_sent)
            return fail(error, size, "Decoder requested packets after EOF drain");

        for (;;) {
            result = av_read_frame(decoder->format, decoder->packet);
            if (result == AVERROR_EOF) {
                result = avcodec_send_packet(decoder->codec, NULL);
                if (result < 0)
                    return ff_fail(error, size, "Drain decoder", result);
                decoder->drain_sent = 1;
                break;
            }
            if (result < 0)
                return ff_fail(error, size, "Read source packet", result);
            if (decoder->packet->stream_index != decoder->stream_index) {
                av_packet_unref(decoder->packet);
                continue;
            }
            if (decoder->packet->size > AFC_MAX_PACKET_BYTES) {
                av_packet_unref(decoder->packet);
                return fail(error, size, "Source packet exceeds development memory limit");
            }
            result = avcodec_send_packet(decoder->codec, decoder->packet);
            av_packet_unref(decoder->packet);
            if (result < 0)
                return ff_fail(error, size, "Send source packet", result);
            break;
        }
    }
}

static int frame_pts(AFCDecoder *decoder, int64_t *pts,
                     char *error, size_t size) {
    if (decoder->frame->pts == AV_NOPTS_VALUE ||
        decoder->frame->best_effort_timestamp == AV_NOPTS_VALUE)
        return fail(error, size, "Decoded source frame is missing a presentation timestamp");
    if (decoder->frame->pts != decoder->frame->best_effort_timestamp)
        return fail(error, size, "Decoded source presentation timestamp required inference");
    *pts = decoder->frame->pts;
    if (*pts < 0)
        return fail(error, size, "Negative source presentation timestamps are unsupported");
    return 0;
}

static int video_geometry(AFCDecoder *decoder, char *error, size_t size) {
    AVFrame *frame = decoder->frame;
    const AVPixFmtDescriptor *pixel = av_pix_fmt_desc_get(frame->format);
    if (frame->width != decoder->width || frame->height != decoder->height)
        return fail(error, size, "Source video dimensions changed during decoding");
    if (!square_pixels(frame->sample_aspect_ratio) ||
        !square_pixels(av_guess_sample_aspect_ratio(decoder->format, decoder->stream, frame)))
        return fail(error, size, "Non-square source pixels are unsupported");
    if ((frame->flags & AV_FRAME_FLAG_INTERLACED) || frame->repeat_pict)
        return fail(error, size, "Interlaced/repeated-field source video is unsupported");
    if (frame->crop_top || frame->crop_bottom || frame->crop_left || frame->crop_right)
        return fail(error, size, "Source crop metadata is unsupported");
    const AVFrameSideData *matrix = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
    if (matrix && !identity_matrix(matrix->data, matrix->size))
        return fail(error, size, "Rotated/transformed source video is unsupported");
    if (frame->color_trc == AVCOL_TRC_SMPTE2084 || frame->color_trc == AVCOL_TRC_ARIB_STD_B67)
        return fail(error, size, "HDR source transfer functions are unsupported");
    if (!pixel || (pixel->flags & AV_PIX_FMT_FLAG_HWACCEL))
        return fail(error, size, "Source video pixel format is unsupported");
    return 0;
}

static int audio_shape(AFCDecoder *decoder, char *error, size_t size) {
    AVFrame *frame = decoder->frame;
    if (frame->sample_rate != decoder->sample_rate)
        return fail(error, size, "Source sample rate changed during decoding");
    if (frame->ch_layout.nb_channels != decoder->channels ||
        av_channel_layout_compare(&frame->ch_layout, &decoder->audio_layout) != 0)
        return fail(error, size, "Source channel layout changed during decoding");
    if (frame->nb_samples <= 0 ||
        (int64_t)frame->nb_samples * decoder->channels > AFC_MAX_AUDIO_FLOATS)
        return fail(error, size, "Decoded audio frame exceeds development memory limit or is empty");
    if (decoder->audio_format < 0) decoder->audio_format = frame->format;
    if (frame->format != decoder->audio_format)
        return fail(error, size, "Source sample format changed during decoding");
    if (av_frame_get_side_data(frame, AV_FRAME_DATA_SKIP_SAMPLES))
        return fail(error, size, "Source audio skip/padding metadata is unsupported");
    return 0;
}

/* All products fit signed 128 bits: units <= INT64_MAX and rational components
 * <= INT_MAX. No rounded timestamp rescaling is used to qualify frames. */
static int units_to_pts(AFCDecoder *decoder, int64_t unit, AVRational rate,
                        int64_t *pts, char *error, size_t size) {
    __int128 numerator = (__int128)unit * rate.den * decoder->stream->time_base.den;
    __int128 denominator = (__int128)rate.num * decoder->stream->time_base.num;
    if (unit < 0 || denominator <= 0 || numerator % denominator != 0 ||
        numerator / denominator > INT64_MAX)
        return fail(error, size, "Requested source time is not exactly representable in the stream time base");
    *pts = (int64_t)(numerator / denominator);
    return 0;
}

static int pts_to_units(AFCDecoder *decoder, int64_t pts, AVRational rate,
                        int64_t *unit, char *error, size_t size) {
    __int128 numerator = (__int128)pts * decoder->stream->time_base.num * rate.num;
    __int128 denominator = (__int128)decoder->stream->time_base.den * rate.den;
    if (pts < 0 || denominator <= 0 || numerator % denominator != 0 ||
        numerator / denominator > INT64_MAX)
        return fail(error, size, "Decoded source timestamp is off the exact frame/sample grid");
    *unit = (int64_t)(numerator / denominator);
    return 0;
}

static int reset_to(AFCDecoder *decoder, int64_t pts, char *error, size_t size) {
    decoder->needs_seek = 1;
    /* Seeking backward permits demuxer/codec preroll. We discard decoded frames
     * by exact presentation timestamp, never by reported player time. */
    int result = av_seek_frame(decoder->format, decoder->stream_index, pts, AVSEEK_FLAG_BACKWARD);
    if (result < 0) return ff_fail(error, size, "Seek source backward", result);
    avcodec_flush_buffers(decoder->codec);
    av_packet_unref(decoder->packet);
    av_frame_unref(decoder->frame);
    swr_free(&decoder->swr);
    decoder->drain_sent = 0;
    decoder->cached = 0;
    decoder->audio_buffer_valid = 0;
    decoder->needs_seek = 0;
    return 0;
}

static int qualify(AFCDecoder *decoder, AVRational rate, char *error, size_t size) {
    if (decoder->qualified) return 0;
    int result = reset_to(decoder, 0, error, size);
    if (result < 0) return result;
    int64_t expected = 0;
    for (;;) {
        result = next_frame(decoder, error, size);
        if (result < 0) goto invalid;
        if (!result) break;
        int64_t pts, unit;
        result = frame_pts(decoder, &pts, error, size);
        if (result < 0) goto invalid;
        result = pts_to_units(decoder, pts, rate, &unit, error, size);
        if (result < 0) goto invalid;
        if (unit != expected) {
            result = fail(error, size, "Source timestamps are not contiguous on the exact frame/sample grid");
            goto invalid;
        }
        result = decoder->kind == AVMEDIA_TYPE_VIDEO
            ? video_geometry(decoder, error, size) : audio_shape(decoder, error, size);
        if (result < 0) goto invalid;
        int increment = decoder->kind == AVMEDIA_TYPE_VIDEO ? 1 : decoder->frame->nb_samples;
        if (expected > INT64_MAX - increment) {
            result = fail(error, size, "Source frame/sample count overflows");
            goto invalid;
        }
        expected += increment;
    }
    if (!expected) {
        result = fail(error, size, "Selected source stream contains no decoded frames");
        goto invalid;
    }
    decoder->total_units = expected;
    decoder->qualified = 1;
    decoder->needs_seek = 1;
    return 0;
invalid:
    decoder->needs_seek = 1;
    return result;
}

AFCDecoder *afc_decoder_open(const char *path, int stream_index,
                             char *error, size_t error_size) {
    clear_error(error, error_size);
    struct stat file_stat;
    if (!path || path[0] != '/' || stat(path, &file_stat) != 0 || !S_ISREG(file_stat.st_mode)) {
        fail(error, error_size, "Source must be an existing absolute local regular-file path");
        return NULL;
    }
    AFCDecoder *decoder = calloc(1, sizeof(*decoder));
    if (!decoder) {
        fail(error, error_size, "Allocate decoder: out of memory");
        return NULL;
    }
    decoder->audio_format = -1;
    decoder->stream_index = stream_index;
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int result = avformat_open_input(&decoder->format, path, NULL, &options);
    av_dict_free(&options);
    if (result < 0) {
        ff_fail(error, error_size, "Open local source", result);
        goto invalid;
    }
    result = avformat_find_stream_info(decoder->format, NULL);
    if (result < 0) {
        ff_fail(error, error_size, "Inspect source streams", result);
        goto invalid;
    }
    if (stream_index < 0 || (unsigned)stream_index >= decoder->format->nb_streams) {
        fail(error, error_size, "Container stream index %d is absent", stream_index);
        goto invalid;
    }
    decoder->stream = decoder->format->streams[stream_index];
    AVCodecParameters *parameters = decoder->stream->codecpar;
    decoder->kind = parameters->codec_type;
    if (decoder->kind != AVMEDIA_TYPE_VIDEO && decoder->kind != AVMEDIA_TYPE_AUDIO) {
        fail(error, error_size, "Selected container stream is neither video nor audio");
        goto invalid;
    }
    if (!decoder->format->pb || !(decoder->format->pb->seekable & AVIO_SEEKABLE_NORMAL)) {
        fail(error, error_size, "Source does not support exact backward seeking");
        goto invalid;
    }
    if (decoder->stream->time_base.num <= 0 || decoder->stream->time_base.den <= 0) {
        fail(error, error_size, "Source stream has an invalid time base");
        goto invalid;
    }
    if (decoder->stream->start_time != AV_NOPTS_VALUE && decoder->stream->start_time != 0) {
        fail(error, error_size, "Nonzero source stream start times are unsupported");
        goto invalid;
    }
    if (decoder->kind == AVMEDIA_TYPE_VIDEO) {
        decoder->width = parameters->width;
        decoder->height = parameters->height;
        if (decoder->width <= 0 || decoder->height <= 0 ||
            (int64_t)decoder->width * decoder->height > AFC_MAX_PIXELS) {
            fail(error, error_size, "Source raster exceeds development geometry limits or is invalid");
            goto invalid;
        }
        if (!square_pixels(parameters->sample_aspect_ratio)) {
            fail(error, error_size, "Non-square source pixels are unsupported");
            goto invalid;
        }
        const AVPacketSideData *matrix = av_packet_side_data_get(
            parameters->coded_side_data, parameters->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        if (matrix && !identity_matrix(matrix->data, matrix->size)) {
            fail(error, error_size, "Rotated/transformed source video is unsupported");
            goto invalid;
        }
    } else {
        if (!pcm_codec(parameters->codec_id)) {
            fail(error, error_size, "Compressed/non-qualified audio is unsupported; this proof requires integer/float PCM");
            goto invalid;
        }
        decoder->channels = parameters->ch_layout.nb_channels;
        decoder->sample_rate = parameters->sample_rate;
        if (decoder->channels <= 0 || decoder->channels > AFC_MAX_CHANNELS ||
            decoder->sample_rate <= 0 || decoder->sample_rate > 384000 ||
            !av_channel_layout_check(&parameters->ch_layout)) {
            fail(error, error_size, "Source audio rate/channel layout exceeds development limits or is invalid");
            goto invalid;
        }
        if (parameters->initial_padding || parameters->trailing_padding) {
            fail(error, error_size, "Source audio delay/padding is unsupported");
            goto invalid;
        }
        result = av_channel_layout_copy(&decoder->audio_layout, &parameters->ch_layout);
        if (result < 0) {
            ff_fail(error, error_size, "Copy source channel layout", result);
            goto invalid;
        }
    }
    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec) {
        fail(error, error_size, "Selected source codec has no decoder in this FFmpeg build");
        goto invalid;
    }
    decoder->codec = avcodec_alloc_context3(codec);
    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    if (!decoder->codec || !decoder->packet || !decoder->frame) {
        fail(error, error_size, "Allocate decoder state: out of memory");
        goto invalid;
    }
    result = avcodec_parameters_to_context(decoder->codec, parameters);
    if (result < 0) {
        ff_fail(error, error_size, "Configure source decoder", result);
        goto invalid;
    }
    decoder->codec->thread_count = 1;
    decoder->codec->max_pixels = AFC_MAX_PIXELS;
    decoder->codec->pkt_timebase = decoder->stream->time_base;
    result = avcodec_open2(decoder->codec, codec, NULL);
    if (result < 0) {
        ff_fail(error, error_size, "Initialize source decoder", result);
        goto invalid;
    }
    result = next_frame(decoder, error, error_size);
    if (result <= 0) {
        if (!result) fail(error, error_size, "Selected source stream is empty");
        goto invalid;
    }
    int64_t first_pts;
    if (frame_pts(decoder, &first_pts, error, error_size) < 0) goto invalid;
    if (first_pts != 0) {
        fail(error, error_size, "Source first decoded presentation timestamp is not zero");
        goto invalid;
    }
    result = decoder->kind == AVMEDIA_TYPE_VIDEO
        ? video_geometry(decoder, error, error_size) : audio_shape(decoder, error, error_size);
    if (result < 0) goto invalid;
    decoder->cached = 1;
    decoder->cached_unit = 0;
    return decoder;
invalid:
    afc_decoder_close(decoder);
    return NULL;
}

void afc_decoder_close(AFCDecoder *decoder) {
    if (!decoder) return;
    sws_freeContext(decoder->sws);
    swr_free(&decoder->swr);
    free(decoder->audio_buffer);
    av_channel_layout_uninit(&decoder->audio_layout);
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->packet);
    avcodec_free_context(&decoder->codec);
    avformat_close_input(&decoder->format);
    free(decoder);
}

int afc_decoder_width(const AFCDecoder *decoder) { return decoder ? decoder->width : 0; }
int afc_decoder_height(const AFCDecoder *decoder) { return decoder ? decoder->height : 0; }
int afc_decoder_channels(const AFCDecoder *decoder) { return decoder ? decoder->channels : 0; }
int afc_decoder_sample_rate(const AFCDecoder *decoder) { return decoder ? decoder->sample_rate : 0; }
const char *afc_decoder_version(void) { return av_version_info(); }

static int64_t gcd_positive(int64_t a, int64_t b) {
    while (b) { int64_t rest = a % b; a = b; b = rest; }
    return a;
}

static int convert_video(AFCDecoder *decoder, uint8_t *rgb, char *error, size_t size) {
    AVFrame *frame = decoder->frame;
    decoder->sws = sws_getCachedContext(decoder->sws,
        decoder->width, decoder->height, frame->format,
        decoder->width, decoder->height, AV_PIX_FMT_RGB24, SWS_BILINEAR,
        NULL, NULL, NULL);
    if (!decoder->sws) return fail(error, size, "Initialize native RGB conversion");
    int matrix = SWS_CS_DEFAULT;
    switch (frame->colorspace) {
    case AVCOL_SPC_BT709: matrix = SWS_CS_ITU709; break;
    case AVCOL_SPC_FCC: matrix = SWS_CS_FCC; break;
    case AVCOL_SPC_SMPTE240M: matrix = SWS_CS_SMPTE240M; break;
    case AVCOL_SPC_BT2020_NCL: matrix = SWS_CS_BT2020; break;
    case AVCOL_SPC_UNSPECIFIED:
    case AVCOL_SPC_RGB:
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M: break;
    default: return fail(error, size, "Source color matrix is unsupported");
    }
    int result = sws_setColorspaceDetails(decoder->sws, sws_getCoefficients(matrix),
        frame->color_range == AVCOL_RANGE_JPEG, sws_getCoefficients(matrix), 1,
        0, 1 << 16, 1 << 16);
    if (result < 0) return ff_fail(error, size, "Configure native RGB conversion", result);
    uint8_t *output[4] = {rgb, NULL, NULL, NULL};
    int strides[4] = {decoder->width * 3, 0, 0, 0};
    result = sws_scale(decoder->sws, (const uint8_t *const *)frame->data,
        frame->linesize, 0, decoder->height, output, strides);
    if (result != decoder->height) return fail(error, size, "Native RGB conversion returned an incomplete frame");
    return 0;
}

int afc_decoder_video(AFCDecoder *decoder, int64_t source_frame,
                      int64_t rate_num, int64_t rate_den,
                      uint8_t *rgb, size_t rgb_size,
                      char *error, size_t error_size) {
    clear_error(error, error_size);
    if (!decoder || decoder->kind != AVMEDIA_TYPE_VIDEO)
        return fail(error, error_size, "Video extraction requires a video stream decoder");
    if (source_frame < 0 || rate_num <= 0 || rate_den <= 0)
        return fail(error, error_size, "Video source frame/rational rate is invalid");
    int64_t divisor = gcd_positive(rate_num, rate_den);
    rate_num /= divisor;
    rate_den /= divisor;
    if (rate_num > INT_MAX || rate_den > INT_MAX)
        return fail(error, error_size, "Video rational rate exceeds supported integer bounds");
    AVRational rate = {(int)rate_num, (int)rate_den};
    if (decoder->qualified && av_cmp_q(rate, decoder->video_rate))
        return fail(error, error_size, "Requested rate differs from the qualified source CFR rate");
    size_t required = (size_t)decoder->width * decoder->height * 3;
    if (!rgb || rgb_size < required)
        return fail(error, error_size, "RGB24 output buffer is too small");
    int64_t target_pts;
    int result = units_to_pts(decoder, source_frame, rate, &target_pts, error, error_size);
    if (result < 0) return result;
    result = qualify(decoder, rate, error, error_size);
    if (result < 0) return result;
    decoder->video_rate = rate;
    if (source_frame >= decoder->total_units)
        return fail(error, error_size, "Requested source video frame is beyond EOF");
    if (decoder->needs_seek || !decoder->cached || source_frame < decoder->cached_unit) {
        result = reset_to(decoder, target_pts, error, error_size);
        if (result < 0) return result;
    }
    int64_t previous = -1;
    int retry_from_zero = 1;
    for (;;) {
        if (decoder->cached && decoder->cached_unit == source_frame)
            return convert_video(decoder, rgb, error, error_size);
        if (decoder->cached) previous = decoder->cached_unit;
        result = next_frame(decoder, error, error_size);
        if (result < 0) goto invalid;
        if (!result) {
            result = fail(error, error_size, "EOF before the requested source video timestamp");
            goto invalid;
        }
        int64_t pts, frame_unit;
        result = frame_pts(decoder, &pts, error, error_size);
        if (result < 0) goto invalid;
        result = pts_to_units(decoder, pts, rate, &frame_unit, error, error_size);
        if (result < 0) goto invalid;
        result = video_geometry(decoder, error, error_size);
        if (result < 0) goto invalid;
        if (previous >= 0 && frame_unit != previous + 1) {
            result = fail(error, error_size, "Video presentation timestamps changed after qualification");
            goto invalid;
        }
        if (frame_unit > source_frame) {
            if (retry_from_zero) {
                result = reset_to(decoder, 0, error, error_size);
                if (result < 0) goto invalid;
                previous = -1;
                retry_from_zero = 0;
                continue;
            }
            result = fail(error, error_size, "Seek/decode skipped the requested exact source frame");
            goto invalid;
        }
        decoder->cached = 1;
        decoder->cached_unit = frame_unit;
    }
invalid:
    decoder->needs_seek = 1;
    return result;
}

static int convert_audio(AFCDecoder *decoder, char *error, size_t size) {
    if (decoder->audio_buffer_valid) return 0;
    AVFrame *frame = decoder->frame;
    size_t floats = (size_t)frame->nb_samples * decoder->channels;
    if (floats > decoder->audio_buffer_capacity) {
        float *buffer = realloc(decoder->audio_buffer, floats * sizeof(float));
        if (!buffer) return fail(error, size, "Allocate audio conversion buffer: out of memory");
        decoder->audio_buffer = buffer;
        decoder->audio_buffer_capacity = floats;
    }
    if (!decoder->swr) {
        int result = swr_alloc_set_opts2(&decoder->swr,
            &decoder->audio_layout, AV_SAMPLE_FMT_FLT, decoder->sample_rate,
            &decoder->audio_layout, frame->format, decoder->sample_rate, 0, NULL);
        if (result < 0) return ff_fail(error, size, "Configure PCM float conversion", result);
        result = swr_init(decoder->swr);
        if (result < 0) return ff_fail(error, size, "Initialize PCM float conversion", result);
    }
    uint8_t *output[1] = {(uint8_t *)decoder->audio_buffer};
    int result = swr_convert(decoder->swr, output, frame->nb_samples,
        (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (result < 0) return ff_fail(error, size, "Convert source PCM to float", result);
    if (result != frame->nb_samples || swr_get_delay(decoder->swr, decoder->sample_rate) != 0)
        return fail(error, size, "PCM conversion introduced unsupported delay/resampling");
    decoder->audio_buffer_valid = 1;
    return 0;
}

int afc_decoder_audio(AFCDecoder *decoder, int64_t start_sample,
                      int sample_count, int sample_rate,
                      float *interleaved, size_t float_count,
                      char *error, size_t error_size) {
    clear_error(error, error_size);
    if (!decoder || decoder->kind != AVMEDIA_TYPE_AUDIO)
        return fail(error, error_size, "Audio extraction requires a PCM audio stream decoder");
    if (sample_rate != decoder->sample_rate)
        return fail(error, error_size, "Audio resampling is unsupported; requested rate must equal source rate");
    if (start_sample < 0 || sample_count < 0 || start_sample > INT64_MAX - sample_count)
        return fail(error, error_size, "Audio source sample range is invalid");
    size_t required = (size_t)sample_count * decoder->channels;
    if ((sample_count && !interleaved) || float_count < required)
        return fail(error, error_size, "Interleaved float output buffer is too small");
    AVRational rate = {sample_rate, 1};
    int result = qualify(decoder, rate, error, error_size);
    if (result < 0) return result;
    if (start_sample + sample_count > decoder->total_units)
        return fail(error, error_size, "Requested source audio samples extend beyond EOF");
    if (!sample_count) return 0;
    if (decoder->needs_seek || !decoder->cached || start_sample < decoder->cached_unit) {
        int64_t target_pts;
        /* Audio packet timestamps need only be sample-aligned, so choose the
         * preceding representable stream tick for an arbitrary sample seek. */
        __int128 numerator = (__int128)start_sample * decoder->stream->time_base.den;
        __int128 denominator = (__int128)sample_rate * decoder->stream->time_base.num;
        if (numerator / denominator > INT64_MAX)
            return fail(error, error_size, "Audio seek timestamp overflows");
        target_pts = (int64_t)(numerator / denominator);
        result = reset_to(decoder, target_pts, error, error_size);
        if (result < 0) return result;
    }
    int64_t wanted = start_sample;
    int64_t end = start_sample + sample_count;
    int64_t previous_end = -1;
    int retry_from_zero = 1;
    while (wanted < end) {
        if (!decoder->cached || decoder->cached_unit + decoder->frame->nb_samples <= wanted) {
            if (decoder->cached) previous_end = decoder->cached_unit + decoder->frame->nb_samples;
            result = next_frame(decoder, error, error_size);
            if (result < 0) goto invalid;
            if (!result) {
                result = fail(error, error_size, "EOF before the requested source audio samples");
                goto invalid;
            }
            int64_t pts, unit;
            result = frame_pts(decoder, &pts, error, error_size);
            if (result < 0) goto invalid;
            result = pts_to_units(decoder, pts, rate, &unit, error, error_size);
            if (result < 0) goto invalid;
            result = audio_shape(decoder, error, error_size);
            if (result < 0) goto invalid;
            if (unit > INT64_MAX - decoder->frame->nb_samples ||
                (previous_end >= 0 && unit != previous_end)) {
                result = fail(error, error_size, "Audio presentation timestamps changed after qualification");
                goto invalid;
            }
            decoder->cached = 1;
            decoder->cached_unit = unit;
        }
        if (decoder->cached_unit > wanted) {
            if (retry_from_zero && wanted == start_sample) {
                result = reset_to(decoder, 0, error, error_size);
                if (result < 0) goto invalid;
                previous_end = -1;
                retry_from_zero = 0;
                continue;
            }
            result = fail(error, error_size, "Seek/decode skipped the requested exact source sample");
            goto invalid;
        }
        int64_t available_end = decoder->cached_unit + decoder->frame->nb_samples;
        if (available_end <= wanted) continue;
        result = convert_audio(decoder, error, error_size);
        if (result < 0) goto invalid;
        int64_t copy_end = available_end < end ? available_end : end;
        size_t source_offset = (size_t)(wanted - decoder->cached_unit) * decoder->channels;
        size_t output_offset = (size_t)(wanted - start_sample) * decoder->channels;
        size_t copy_floats = (size_t)(copy_end - wanted) * decoder->channels;
        memcpy(interleaved + output_offset, decoder->audio_buffer + source_offset,
            copy_floats * sizeof(float));
        wanted = copy_end;
    }
    return 0;
invalid:
    decoder->needs_seek = 1;
    return result;
}
