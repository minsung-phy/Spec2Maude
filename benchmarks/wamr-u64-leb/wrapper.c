/*
 * Analysis wrapper for WAMR's production bh_leb_read implementation.
 *
 * The workflow pins and clones wasm-micro-runtime, then compiles this file
 * with the pinned core/shared/utils/bh_leb128.c on the include path.  The
 * implementation below is therefore the exact upstream decoder, not a
 * reimplementation.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* WAMR's bh_leb128.h includes bh_platform.h only for these aliases.  Defining
 * its include guard keeps the extracted production decoder self-contained
 * while preserving the upstream function body verbatim. */
typedef uint8_t uint8;
typedef uint32_t uint32;
typedef uint64_t uint64;
#define _BH_PLATFORM_H
#include "bh_leb128.c"

uint32_t
wamr_decode_status(uint32_t last_byte)
{
    uint8 data[10] = { 0x80, 0x80, 0x80, 0x80, 0x80,
                       0x80, 0x80, 0x80, 0x80, 0x00 };
    uint64 value = UINT64_C(0xfeedfacecafebeef);
    size_t offset = 0;

    data[9] = (uint8)(last_byte & 0x7f);
    return (uint32_t)bh_leb_read(data, data + sizeof(data), 64, false,
                                &value, &offset);
}

uint64_t
wamr_decode_value(uint32_t last_byte)
{
    uint8 data[10] = { 0x80, 0x80, 0x80, 0x80, 0x80,
                       0x80, 0x80, 0x80, 0x80, 0x00 };
    uint64 value = UINT64_C(0xfeedfacecafebeef);
    size_t offset = 0;

    data[9] = (uint8)(last_byte & 0x7f);
    (void)bh_leb_read(data, data + sizeof(data), 64, false, &value, &offset);
    return value;
}

#ifdef WAMR_LEB_NATIVE_MAIN
#include <stdio.h>

int
main(void)
{
    uint32_t last;
    uint32_t mismatches = 0;

    for (last = 0; last < 128; ++last) {
        uint32_t actual = wamr_decode_status(last);
        uint32_t expected = last <= 1 ? BH_LEB_READ_SUCCESS
                                     : BH_LEB_READ_OVERFLOW;
        if (actual != expected) {
            if (mismatches < 8) {
                printf("mismatch last=%u expected=%u actual=%u value=%llu\n",
                       last, expected, actual,
                       (unsigned long long)wamr_decode_value(last));
            }
            ++mismatches;
        }
    }

    printf("mismatch_count=%u\n", mismatches);
    printf("status_last_0=%u\n", wamr_decode_status(0));
    printf("status_last_1=%u\n", wamr_decode_status(1));
    printf("status_last_2=%u\n", wamr_decode_status(2));
    printf("value_last_2=%llu\n",
           (unsigned long long)wamr_decode_value(2));
    return 0;
}
#endif
