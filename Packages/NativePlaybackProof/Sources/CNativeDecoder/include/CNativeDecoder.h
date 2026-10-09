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
void afc_decoder_close(AFCDecoder *decoder);
int afc_decoder_width(const AFCDecoder *decoder);
int afc_decoder_height(const AFCDecoder *decoder);
int afc_decoder_channels(const AFCDecoder *decoder);
int afc_decoder_sample_rate(const AFCDecoder *decoder);
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

/** Extract [start_sample, start_sample + sample_count) from the absolute source
 * sample grid. Capacity is in floats, not bytes: sample_count * source channels.
 * Requested rate must equal the source rate. EOF is an error rather than silent
 * padding; a zero-length request at EOF is valid. Returns zero or negative.
 */
int afc_decoder_audio(AFCDecoder *decoder, int64_t start_sample,
                      int sample_count, int sample_rate,
                      float *interleaved, size_t float_count,
                      char *error, size_t error_size);

#ifdef __cplusplus
}
#endif
#endif
