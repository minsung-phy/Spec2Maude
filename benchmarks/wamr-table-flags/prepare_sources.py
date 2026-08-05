#!/usr/bin/env python3
"""Extract WAMR's exact production table-flag validator into testable C files."""

from __future__ import annotations

import argparse
from pathlib import Path

PREFIX = r'''#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef uint8_t uint8;
typedef uint32_t uint32;

#define MAX_TABLE_SIZE_FLAG 0x01
#define SHARED_TABLE_FLAG 0x02
#define TABLE64_FLAG 0x04
#define WASM_ENABLE_MEMORY64 1

static void
wasm_loader_set_error_buf(char *error_buf, uint32 error_buf_size,
                          const char *string, bool is_aot)
{
    (void)error_buf;
    (void)error_buf_size;
    (void)string;
    (void)is_aot;
}

'''

SUFFIX = r'''

uint32_t
wamr_table_flag_accept(uint32_t flag)
{
    return wasm_table_check_flags((uint8)flag, NULL, 0, false) ? 1u : 0u;
}

#ifdef WAMR_TABLE_NATIVE_MAIN
#include <stdio.h>

static uint32_t
spec_accept(uint32_t flag)
{
    return flag == 0 || flag == 1 || flag == 4 || flag == 5;
}

int
main(void)
{
    uint32_t flag;
    uint32_t mismatches = 0;
    for (flag = 0; flag < 256; ++flag) {
        uint32_t actual = wamr_table_flag_accept(flag);
        uint32_t expected = spec_accept(flag);
        if (actual != expected) {
            printf("mismatch flag=%u expected=%u actual=%u\n",
                   flag, expected, actual);
            ++mismatches;
        }
    }
    printf("mismatch_count=%u\n", mismatches);
    printf("flag_2=%u\n", wamr_table_flag_accept(2));
    printf("flag_3=%u\n", wamr_table_flag_accept(3));
    return 0;
}
#endif
'''


def extract_function(text: str) -> str:
    start = text.index("bool\nwasm_table_check_flags(")
    next_marker = text.index("\n/*\n * compare with a bigger type set", start)
    return text[start:next_marker].rstrip()


def fix(function: str) -> str:
    old = '''        if (table_flag & SHARED_TABLE_FLAG) {
            wasm_loader_set_error_buf(error_buf, error_buf_size,
                                      "tables cannot be shared", is_aot);
        }
'''
    new = '''        if (table_flag & SHARED_TABLE_FLAG) {
            wasm_loader_set_error_buf(error_buf, error_buf_size,
                                      "tables cannot be shared", is_aot);
            return false;
        }
'''
    if function.count(old) != 1:
        raise RuntimeError("expected shared-table branch was not found exactly once")
    return function.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    source = args.source.read_text(encoding="utf-8")
    current = extract_function(source)
    repaired = fix(current)

    (args.output_dir / "current.c").write_text(
        PREFIX + current + SUFFIX, encoding="utf-8"
    )
    (args.output_dir / "fixed.c").write_text(
        PREFIX + repaired + SUFFIX, encoding="utf-8"
    )


if __name__ == "__main__":
    main()
