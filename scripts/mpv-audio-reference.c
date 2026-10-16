/* Offline diagnostic: decode one container audio stream with the same embedded
 * FFmpeg libraries as MPV. Baseline uses decoder skip/discard metadata only;
 * optional frame-duration control clips to explicit decoded-frame duration.
 * No nominal-duration inference, output alignment or padding.
 * Optional selected-stream seek controls before decoding.
 * argv: fixture, ff-index, output.f32, decoder (aac or aac_fixed), [unseeked|seek-zero|seek-first-packet], [frame-duration].
 * Decoder skip/discard side data applies to its frame; absent metadata is not
 * inferred from container duration. This is a diagnostic, not format admission.
 */
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    AVCodecContext *decoder;
    AVFrame *frame;
    SwrContext *resampler;
    FILE *output;
    int rate, channels, format;
    uint64_t samples, skipped, discarded, packets;
    int64_t first_packet_pts, last_packet_pts, last_packet_duration;
    int64_t last_frame_pts, last_frame_duration;
    int last_frame_samples, use_frame_duration;
    AVRational time_base;
    uint64_t duration_clipped;
} Capture;

static int fail(const char *operation, int error) {
    char message[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(error, message, sizeof(message));
    fprintf(stderr, "%s: %s\n", operation, message);
    return error;
}

static int receive(Capture *capture) {
    for (;;) {
        int rc = avcodec_receive_frame(capture->decoder, capture->frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) return rc;
        if (rc < 0) return fail("receive frame", rc);
        AVFrame *frame = capture->frame;
        if (frame->sample_rate != capture->rate ||
            frame->ch_layout.nb_channels != capture->channels ||
            frame->format != capture->format || frame->nb_samples < 0)
            return fail("unexpected changing audio format", AVERROR(EINVAL));
        capture->last_frame_pts = frame->pts;
        capture->last_frame_duration = frame->duration;
        capture->last_frame_samples = frame->nb_samples;
        uint32_t skip = 0, discard = 0;
        AVFrameSideData *side = av_frame_get_side_data(frame, AV_FRAME_DATA_SKIP_SAMPLES);
        if (side) {
            if (side->size < 10) return fail("short skip metadata", AVERROR(EINVAL));
            skip = AV_RL32(side->data);
            discard = AV_RL32(side->data + 4);
        }
        if ((uint64_t)skip + discard > (uint64_t)frame->nb_samples)
            return fail("skip metadata exceeds frame", AVERROR(EINVAL));
        capture->skipped += skip;
        capture->discarded += discard;
        int count = frame->nb_samples - (int)skip - (int)discard;
        if (capture->use_frame_duration && frame->duration > 0) {
            /* A separate diagnostic uses explicit decoded-frame duration only.
             * Reject fractional sample durations; never infer a source extent. */
            int64_t duration_samples = av_rescale_q(frame->duration, capture->time_base,
                                                   (AVRational){1, capture->rate});
            if (av_compare_ts(frame->duration, capture->time_base, duration_samples,
                              (AVRational){1, capture->rate}) != 0 || duration_samples < skip)
                return fail("nonintegral or incompatible frame duration", AVERROR(EINVAL));
            int64_t available = duration_samples - skip;
            if (available < count) {
                capture->duration_clipped += (uint64_t)(count - available);
                count = (int)available;
            }
        }
        if (count) {
            int planar = av_sample_fmt_is_planar((enum AVSampleFormat)frame->format);
            int stride = av_get_bytes_per_sample((enum AVSampleFormat)frame->format);
            if (stride <= 0) return fail("invalid sample format", AVERROR(EINVAL));
            const uint8_t *input[2] = {0};
            for (int i = 0; i < (planar ? capture->channels : 1); ++i)
                input[i] = frame->extended_data[i] + (size_t)skip * stride * (planar ? 1 : capture->channels);
            int capacity = swr_get_out_samples(capture->resampler, count);
            if (capacity < 0) return fail("conversion capacity", capacity);
            uint8_t *output = NULL;
            rc = av_samples_alloc(&output, NULL, capture->channels, capacity, AV_SAMPLE_FMT_FLT, 0);
            if (rc < 0) return fail("allocate conversion", rc);
            int converted = swr_convert(capture->resampler, &output, capacity, input, count);
            if (converted < 0) {
                av_freep(&output);
                return fail("convert audio", converted);
            }
            size_t bytes = (size_t)converted * capture->channels * sizeof(float);
            int written = fwrite(output, 1, bytes, capture->output) == bytes;
            av_freep(&output);
            if (!written) return fail("write audio", AVERROR(EIO));
            capture->samples += (uint64_t)converted;
        }
        av_frame_unref(frame);
    }
}

int main(int argc, char **argv) {
    if ((argc < 5 || argc > 7) || (strcmp(argv[4], "aac") && strcmp(argv[4], "aac_fixed")) ||
        (argc >= 6 && strcmp(argv[5], "unseeked") && strcmp(argv[5], "seek-zero") && strcmp(argv[5], "seek-first-packet")) ||
        (argc == 7 && strcmp(argv[6], "frame-duration"))) return 2;
    char *end = NULL;
    errno = 0;
    long index = strtol(argv[2], &end, 10);
    if (errno || !*argv[2] || *end || index < 0 || index > INT32_MAX) return 2;
    AVFormatContext *format = NULL;
    AVPacket *packet = NULL;
    Capture capture = {0};
    int result = 1, rc;
    if ((rc = avformat_open_input(&format, argv[1], NULL, NULL)) < 0) {
        fail("open input", rc); goto cleanup;
    }
    if ((rc = avformat_find_stream_info(format, NULL)) < 0) {
        fail("stream information", rc); goto cleanup;
    }
    if ((unsigned long)index >= format->nb_streams ||
        format->streams[index]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
        fail("missing or wrong-kind stream", AVERROR(EINVAL)); goto cleanup;
    }
    AVStream *stream = format->streams[index];
    int64_t seek_target = 0;
    if (argc >= 6 && !strcmp(argv[5], "seek-first-packet")) {
        /* Observe the actual first selected packet, including negative priming
         * timestamps. Do not guess a codec frame size or use nominal duration. */
        AVPacket *first = av_packet_alloc();
        if (!first) { fail("allocate first packet", AVERROR(ENOMEM)); goto cleanup; }
        while ((rc = av_read_frame(format, first)) >= 0 && first->stream_index != index)
            av_packet_unref(first);
        if (rc >= 0) seek_target = first->pts;
        av_packet_free(&first);
        if (rc < 0 || seek_target == AV_NOPTS_VALUE) {
            fail("missing first selected packet timestamp", rc < 0 ? rc : AVERROR(EINVAL));
            goto cleanup;
        }
    }
    if (argc >= 6 && strcmp(argv[5], "unseeked") && (rc = av_seek_frame(format, (int)index, seek_target, AVSEEK_FLAG_BACKWARD)) < 0) {
        fail("seek selected stream", rc); goto cleanup;
    }
    const AVCodec *decoder = avcodec_find_decoder_by_name(argv[4]);
    if (!decoder || decoder->id != stream->codecpar->codec_id) {
        fail("requested decoder unavailable or incompatible", AVERROR(EINVAL)); goto cleanup;
    }
    capture.decoder = avcodec_alloc_context3(decoder);
    capture.frame = av_frame_alloc();
    packet = av_packet_alloc();
    if (!capture.decoder || !capture.frame || !packet) {
        fail("allocate decoder state", AVERROR(ENOMEM)); goto cleanup;
    }
    if ((rc = avcodec_parameters_to_context(capture.decoder, stream->codecpar)) < 0) {
        fail("codec parameters", rc); goto cleanup;
    }
    capture.decoder->pkt_timebase = stream->time_base;
    capture.decoder->flags2 |= AV_CODEC_FLAG2_SKIP_MANUAL;
    capture.decoder->thread_count = 1;
    if ((rc = avcodec_open2(capture.decoder, decoder, NULL)) < 0) {
        fail("open decoder", rc); goto cleanup;
    }
    capture.time_base = stream->time_base;
    capture.use_frame_duration = argc == 7;
    capture.rate = capture.decoder->sample_rate;
    capture.channels = capture.decoder->ch_layout.nb_channels;
    capture.format = capture.decoder->sample_fmt;
    if (capture.rate <= 0 || (capture.channels != 1 && capture.channels != 2)) {
        fail("unsupported audio layout/rate", AVERROR(EINVAL)); goto cleanup;
    }
    if ((rc = swr_alloc_set_opts2(&capture.resampler, &capture.decoder->ch_layout,
            AV_SAMPLE_FMT_FLT, capture.rate, &capture.decoder->ch_layout,
            capture.decoder->sample_fmt, capture.rate, 0, NULL)) < 0 ||
        (rc = swr_init(capture.resampler)) < 0) {
        fail("initialize conversion", rc); goto cleanup;
    }
    capture.output = fopen(argv[3], "wbx");
    if (!capture.output) { perror("create output"); goto cleanup; }
    while ((rc = av_read_frame(format, packet)) >= 0) {
        if (packet->stream_index == index) {
            if (!capture.packets) capture.first_packet_pts = packet->pts;
            capture.packets++;
            capture.last_packet_pts = packet->pts;
            capture.last_packet_duration = packet->duration;
            rc = avcodec_send_packet(capture.decoder, packet);
            if (rc < 0) { fail("send packet", rc); goto cleanup; }
            rc = receive(&capture);
            if (rc != AVERROR(EAGAIN)) {
                if (rc == AVERROR_EOF) fail("premature decoder EOF", AVERROR(EINVAL));
                goto cleanup;
            }
        }
        av_packet_unref(packet);
    }
    if (rc != AVERROR_EOF) { fail("read packet", rc); goto cleanup; }
    if ((rc = avcodec_send_packet(capture.decoder, NULL)) < 0) {
        fail("drain decoder", rc); goto cleanup;
    }
    rc = receive(&capture);
    if (rc != AVERROR_EOF) {
        if (rc == AVERROR(EAGAIN)) fail("incomplete decoder drain", rc);
        goto cleanup;
    }
    /* Same-rate format conversion must not retain samples. Do not silently
     * discard conversion delay; reject it rather than inventing an edge fix. */
    if (swr_get_delay(capture.resampler, capture.rate) != 0) {
        fail("unexpected conversion delay", AVERROR(EINVAL)); goto cleanup;
    }
    if (fflush(capture.output) || ferror(capture.output)) {
        perror("flush output"); goto cleanup;
    }
    if (fclose(capture.output)) {
        capture.output = NULL; perror("close output"); goto cleanup;
    }
    capture.output = NULL;
    printf("{\"passed\":true,\"decoder\":\"%s\",\"ffIndex\":%ld,\"seekZero\":%s,"
           "\"useFrameDuration\":%s,\"durationClippedSamples\":%" PRIu64 ","
           "\"seekFirstPacket\":%s,\"seekTarget\":%" PRId64 ","
           "\"timeBaseNumerator\":%d,\"timeBaseDenominator\":%d,"
           "\"packets\":%" PRIu64 ",\"firstPacketPTS\":%" PRId64 ","
           "\"lastPacketPTS\":%" PRId64 ",\"lastPacketDuration\":%" PRId64 ","
           "\"lastFramePTS\":%" PRId64 ",\"lastFrameDuration\":%" PRId64 ",\"lastFrameSamples\":%d,"
           "\"libavcodecVersion\":%u,\"libavformatVersion\":%u,\"libswresampleVersion\":%u,"
           "\"sampleRate\":%d,\"channels\":%d,\"samplesPerChannel\":%" PRIu64 ","
           "\"skippedSamples\":%" PRIu64 ",\"discardedSamples\":%" PRIu64 "}\n",
           decoder->name, index, argc >= 6 && !strcmp(argv[5], "seek-zero") ? "true" : "false",
           capture.use_frame_duration ? "true" : "false", capture.duration_clipped,
           argc >= 6 && !strcmp(argv[5], "seek-first-packet") ? "true" : "false", seek_target,
           stream->time_base.num, stream->time_base.den, capture.packets, capture.first_packet_pts,
           capture.last_packet_pts, capture.last_packet_duration,
           capture.last_frame_pts, capture.last_frame_duration, capture.last_frame_samples,
           avcodec_version(), avformat_version(), swresample_version(),
           capture.rate, capture.channels, capture.samples, capture.skipped, capture.discarded);
    result = 0;
cleanup:
    if (capture.output && fclose(capture.output)) perror("close failed output");
    swr_free(&capture.resampler);
    av_frame_free(&capture.frame);
    av_packet_free(&packet);
    avcodec_free_context(&capture.decoder);
    avformat_close_input(&format);
    return result;
}
