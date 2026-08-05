#!/usr/bin/env python3
"""Generate minimal memory64 modules for the WAMR loader reproduction."""

from __future__ import annotations

import argparse
from pathlib import Path


def uleb(value: int) -> bytes:
    if value < 0:
        raise ValueError("uleb requires a non-negative integer")
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            byte |= 0x80
        out.append(byte)
        if not value:
            return bytes(out)


def section(section_id: int, payload: bytes) -> bytes:
    return bytes([section_id]) + uleb(len(payload)) + payload


def module(offset_encoding: bytes) -> bytes:
    magic_and_version = b"\x00asm\x01\x00\x00\x00"
    type_section = section(1, b"\x01\x60\x00\x00")
    function_section = section(3, b"\x01\x00")

    # memory64, minimum one page.
    memory_section = section(5, b"\x01\x04\x01")

    # Export as main so the production iwasm CLI executes it.
    name = b"main"
    export_section = section(
        7, b"\x01" + uleb(len(name)) + name + b"\x00\x00"
    )

    # () -> () body:
    #   i64.const 0
    #   i32.load align=2 offset=<u64 candidate>
    #   drop
    #
    # With memory64 enabled, the memarg offset is decoded as unsigned u64 by
    # WAMR's read_leb_mem_offset path.  An invalid value 2^64 must be rejected
    # during loading, not wrapped to offset zero and executed.
    body = (
        b"\x00"          # local decl vector
        + b"\x42\x00"    # i64.const 0
        + b"\x28\x02"    # i32.load, alignment 2
        + offset_encoding
        + b"\x1a\x0b"    # drop; end
    )
    code_section = section(10, b"\x01" + uleb(len(body)) + body)

    return (
        magic_and_version
        + type_section
        + function_section
        + memory_section
        + export_section
        + code_section
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    (args.output_dir / "memory64-offset-valid-zero.wasm").write_bytes(
        module(b"\x00")
    )

    # A ten-byte unsigned LEB may use only bit 0 of the final payload for u64.
    # 0x80^9 0x02 denotes 2^64 and is invalid; current WAMR accepts it and
    # wraps it to zero.  0x7f is a second invalid terminal payload.
    prefix = b"\x80" * 9
    (args.output_dir / "memory64-offset-overflow-2.wasm").write_bytes(
        module(prefix + b"\x02")
    )
    (args.output_dir / "memory64-offset-overflow-127.wasm").write_bytes(
        module(prefix + b"\x7f")
    )

    for path in sorted(args.output_dir.glob("*.wasm")):
        print(f"{path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
