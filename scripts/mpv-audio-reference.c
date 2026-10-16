/* Offline diagnostic: decode one container audio stream with the same embedded
 * FFmpeg libraries as MPV. No timestamp clipping, padding or repairs.
 * Optional selected-stream seek-to-zero control before decoding.
 * argv: fixture, ff-index, output.f32, decoder (aac or aac_fixed), [seek-zero].
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
    uint64_t samples, skipped, discarded;
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
    if ((argc != 5 && argc != 6) || (strcmp(argv[4], "aac") && strcmp(argv[4], "aac_fixed")) ||
        (argc == 6 && strcmp(argv[5], "seek-zero"))) return 2;
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
    if (argc == 6 && (rc = av_seek_frame(format, (int)index, 0, AVSEEK_FLAG_BACKWARD)) < 0) {
        fail("seek selected stream to zero", rc); goto cleanup;
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
           "\"libavcodecVersion\":%u,\"libavformatVersion\":%u,\"libswresampleVersion\":%u,"
           "\"sampleRate\":%d,\"channels\":%d,\"samplesPerChannel\":%" PRIu64 ","
           "\"skippedSamples\":%" PRIu64 ",\"discardedSamples\":%" PRIu64 "}\n",
           decoder->name, index, argc == 6 ? "true" : "false",
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
