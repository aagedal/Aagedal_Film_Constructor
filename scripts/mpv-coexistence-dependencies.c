/* Development-only binding probe, compiled separately into each dependency island. */
#include <stddef.h>

extern unsigned avformat_version(void);
extern unsigned avcodec_version(void);
extern unsigned avutil_version(void);
extern unsigned swresample_version(void);
extern unsigned swscale_version(void);

#ifndef AFC_PROBE_NAME
#error Supply the exported probe name
#endif

int AFC_PROBE_NAME(int index, unsigned *version, const void **address) {
    unsigned (*functions[])(void) = {avformat_version, avcodec_version,
        avutil_version, swresample_version, swscale_version};
    if (index < 0 || (size_t)index >= sizeof(functions) / sizeof(*functions)) return -1;
    *version = functions[index]();
    *address = (const void *)functions[index];
    return 0;
}
