/* Development-only executable; run through native-decoder-check.py. */
#include "CNativeDecoder.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char error_text[1024];
static int check_count;

static void json_string(const char *value) {
    putchar('"');
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; cursor++) {
        if (*cursor == '"' || *cursor == '\\') printf("\\%c", *cursor);
        else if (*cursor < 32) printf("\\u%04x", *cursor);
        else putchar(*cursor);
    }
    putchar('"');
}

static void check(int condition, const char *name, int include_error) {
    if (!condition) {
        fprintf(stderr, "FAILED: %s: %s\n", name, error_text);
        exit(1);
    }
    if (check_count++) puts(",");
    printf("{\"name\":");
    json_string(name);
    printf(",\"passed\":true");
    if (include_error) {
        printf(",\"rejection\":");
        json_string(error_text);
    }
    printf("}");
}

static void rejected(int result, const char *name, const char *reason) {
    check(result < 0 && strstr(error_text, reason), name, 1);
}

static void read_at(const char *path, size_t offset, void *output, size_t size) {
    FILE *stream = fopen(path, "rb");
    if (!stream || fseek(stream, (long)offset, SEEK_SET) ||
        fread(output, 1, size, stream) != size || fclose(stream)) {
        fprintf(stderr, "Cannot read reference range at %zu: %s\n", offset, path);
        exit(1);
    }
}

static void control_path(char *output, size_t size, const char *directory, const char *name) {
    int count = snprintf(output, size, "%s/%s", directory, name);
    if (count < 0 || (size_t)count >= size) {
        fputs("Control path is too long\n", stderr);
        exit(1);
    }
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fputs("Usage: native-decoder-check SOURCE.mov REFERENCE.rgb REFERENCE.f32 CONTROL-DIRECTORY\n", stderr);
        return 2;
    }
    const char *source = argv[1], *reference_rgb = argv[2], *reference_audio = argv[3];
    const char *controls = argv[4];
    char path[4096];
    uint8_t rgb[160 * 90 * 3], expected_rgb[sizeof(rgb)];
    float audio[4096], expected_audio[4096];
    puts("{\"checks\":[");

    AFCDecoder *video = afc_decoder_open(source, 0, error_text, sizeof(error_text));
    check(video != NULL, "open exact video container stream", 0);
    check(afc_decoder_width(video) == 160 && afc_decoder_height(video) == 90,
          "native video raster", 0);
    const int frames[] = {0, 1, 60, 119, 299, 120, 15, 15, 2, 299, 0};
    for (size_t index = 0; index < sizeof(frames) / sizeof(*frames); index++) {
        int frame = frames[index];
        int result = afc_decoder_video(video, frame, 30000, 1001,
            rgb, sizeof(rgb), error_text, sizeof(error_text));
        read_at(reference_rgb, (size_t)frame * sizeof(rgb), expected_rgb, sizeof(rgb));
        char name[96];
        snprintf(name, sizeof(name), "exact RGB request %zu at source frame %d", index, frame);
        check(result == 0 && !memcmp(rgb, expected_rgb, sizeof(rgb)), name, 0);
    }
    rejected(afc_decoder_video(video, 300, 30000, 1001, rgb, sizeof(rgb),
        error_text, sizeof(error_text)), "reject video after EOF", "beyond EOF");
    rejected(afc_decoder_video(video, 1, 25, 1, rgb, sizeof(rgb),
        error_text, sizeof(error_text)), "reject changed qualified video rate", "qualified source CFR rate");
    rejected(afc_decoder_video(video, 0, 30000, 1001, rgb, 1,
        error_text, sizeof(error_text)), "reject short RGB buffer", "buffer is too small");
    rejected(afc_decoder_video(video, -1, 30000, 1001, rgb, sizeof(rgb),
        error_text, sizeof(error_text)), "reject negative source frame", "invalid");
    rejected(afc_decoder_video(video, INT64_MAX, 30000, 1001, rgb, sizeof(rgb),
        error_text, sizeof(error_text)), "reject video timestamp overflow", "not exactly representable");
    rejected(afc_decoder_audio(video, 0, 1, 48000, audio, 4096,
        error_text, sizeof(error_text)), "reject audio operation on video stream", "requires a PCM audio stream");
    check(afc_decoder_video(video, 0, 30000, 1001, rgb, sizeof(rgb),
        error_text, sizeof(error_text)) == 0, "video remains usable after rejected requests", 0);
    afc_decoder_close(video);

    video = afc_decoder_open(source, 0, error_text, sizeof(error_text));
    check(video != NULL, "open fresh video for off-grid control", 0);
    rejected(afc_decoder_video(video, 1, 24000, 1001, rgb, sizeof(rgb),
        error_text, sizeof(error_text)), "reject source time between exact stream ticks", "not exactly representable");
    check(afc_decoder_video(video, 1, 30000, 1001, rgb, sizeof(rgb),
        error_text, sizeof(error_text)) == 0, "correct rate succeeds after off-grid rejection", 0);
    afc_decoder_close(video);

    AFCDecoder *pcm = afc_decoder_open(source, 2, error_text, sizeof(error_text));
    check(pcm != NULL, "open second exact PCM container stream", 0);
    check(afc_decoder_channels(pcm) == 1 && afc_decoder_sample_rate(pcm) == 48000,
          "source channel count and rate", 0);
    const int starts[] = {0, 1, 1023, 1024, 100000, 480479, 480000, 1025, 5, 5, 480479, 0};
    for (size_t index = 0; index < sizeof(starts) / sizeof(*starts); index++) {
        int start = starts[index], count = 480480 - start;
        if (count > 4096) count = 4096;
        int result = afc_decoder_audio(pcm, start, count, 48000, audio, 4096,
            error_text, sizeof(error_text));
        read_at(reference_audio, (size_t)start * sizeof(float), expected_audio,
                (size_t)count * sizeof(float));
        char name[96];
        snprintf(name, sizeof(name), "exact PCM request %zu at source sample %d", index, start);
        check(result == 0 && !memcmp(audio, expected_audio, (size_t)count * sizeof(float)), name, 0);
    }
    rejected(afc_decoder_audio(pcm, 0, 10, 44100, audio, 4096,
        error_text, sizeof(error_text)), "reject actual PCM rate mismatch", "resampling is unsupported");
    rejected(afc_decoder_audio(pcm, 480480, 1, 48000, audio, 4096,
        error_text, sizeof(error_text)), "reject audio after EOF", "beyond EOF");
    check(afc_decoder_audio(pcm, 480480, 0, 48000, NULL, 0,
        error_text, sizeof(error_text)) == 0, "empty audio range at EOF", 0);
    rejected(afc_decoder_audio(pcm, 0, 10, 48000, audio, 1,
        error_text, sizeof(error_text)), "reject short float buffer", "buffer is too small");
    rejected(afc_decoder_audio(pcm, INT64_MAX, 1, 48000, audio, 4096,
        error_text, sizeof(error_text)), "reject source sample range overflow", "range is invalid");
    rejected(afc_decoder_audio(pcm, -1, 1, 48000, audio, 4096,
        error_text, sizeof(error_text)), "reject negative source sample", "range is invalid");
    rejected(afc_decoder_video(pcm, 0, 25, 1, rgb, sizeof(rgb),
        error_text, sizeof(error_text)), "reject video operation on audio stream", "requires a video stream");
    afc_decoder_close(pcm);

    control_path(path, sizeof(path), controls, "vfr.mov");
    video = afc_decoder_open(path, 0, error_text, sizeof(error_text));
    check(video != NULL, "open VFR control before full timestamp qualification", 0);
    rejected(afc_decoder_video(video, 0, 25, 1, rgb, sizeof(rgb),
        error_text, sizeof(error_text)), "reject timestamp gap anywhere in VFR video", "not contiguous");
    afc_decoder_close(video);

    const char *rejected_files[] = {"offset.mov", "sar.mov", "rotation.mov", "aac.m4a", "raw.h264"};
    const char *reasons[] = {"Nonzero", "Non-square", "Rotated/transformed", "requires integer/float PCM", "missing a presentation timestamp"};
    for (size_t index = 0; index < sizeof(rejected_files) / sizeof(*rejected_files); index++) {
        control_path(path, sizeof(path), controls, rejected_files[index]);
        video = afc_decoder_open(path, 0, error_text, sizeof(error_text));
        char name[96];
        snprintf(name, sizeof(name), "reject unsupported source %s", rejected_files[index]);
        check(video == NULL && strstr(error_text, reasons[index]), name, 1);
        afc_decoder_close(video);
    }

    control_path(path, sizeof(path), controls, "audio-gap.nut");
    pcm = afc_decoder_open(path, 0, error_text, sizeof(error_text));
    check(pcm != NULL, "open PCM with timestamp gap before qualification", 0);
    rejected(afc_decoder_audio(pcm, 0, 1, 48000, audio, 4096,
        error_text, sizeof(error_text)), "reject PCM timestamp gap", "not contiguous");
    afc_decoder_close(pcm);

    control_path(path, sizeof(path), controls, "pcm.wav");
    pcm = afc_decoder_open(path, 0, error_text, sizeof(error_text));
    check(pcm != NULL, "open timestamped PCM WAV", 0);
    check(afc_decoder_audio(pcm, 19000, 200, 48000, audio, 4096,
        error_text, sizeof(error_text)) == 0, "PCM WAV EOF boundary", 0);
    check(afc_decoder_audio(pcm, 1, 200, 48000, audio, 4096,
        error_text, sizeof(error_text)) == 0, "PCM WAV arbitrary backward request", 0);
    afc_decoder_close(pcm);

    control_path(path, sizeof(path), controls, "four-channel.wav");
    pcm = afc_decoder_open(path, 0, error_text, sizeof(error_text));
    check(pcm != NULL && afc_decoder_channels(pcm) == 4, "preserve all four source PCM channels", 0);
    const int multichannel_starts[] = {0, 511, 13, 13, 300, 1};
    for (size_t index = 0; index < sizeof(multichannel_starts) / sizeof(*multichannel_starts); index++) {
        int start = multichannel_starts[index], count = 512 - start;
        if (count > 128) count = 128;
        int result = afc_decoder_audio(pcm, start, count, 48000, audio, 4096,
            error_text, sizeof(error_text));
        int matches = result == 0;
        for (int sample = 0; sample < count; sample++) {
            for (int channel = 0; channel < 4; channel++) {
                int value = (((start + sample) * (channel + 1) * 257 + channel * 7919) % 65536) - 32768;
                if (audio[sample * 4 + channel] != value / 32768.0f) matches = 0;
            }
        }
        char name[96];
        snprintf(name, sizeof(name), "four-channel interleaving request %zu at sample %d", index, start);
        check(matches, name, 0);
    }
    afc_decoder_close(pcm);

    video = afc_decoder_open("https://example.invalid/a.mov", 0, error_text, sizeof(error_text));
    check(video == NULL && strstr(error_text, "local regular-file"), "reject nonlocal source path", 1);
    video = afc_decoder_open(source, 99, error_text, sizeof(error_text));
    check(video == NULL && strstr(error_text, "absent"), "reject absent container stream", 1);
    afc_decoder_close(NULL);
    printf("],\"checkCount\":%d,\"linkedFFmpegVersion\":", check_count);
    json_string(afc_decoder_version());
    puts(",\"passed\":true}");
    return 0;
}
