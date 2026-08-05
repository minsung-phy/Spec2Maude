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


def module(memory_min_encoding: bytes) -> bytes:
    magic_and_version = b"\x00asm\x01\x00\x00\x00"

    # One () -> () function used as an executable control.
    type_section = section(1, b"\x01\x60\x00\x00")
    function_section = section(3, b"\x01\x00")

    # limits flags 0x04 select memory64 with no maximum.  Consequently the
    # minimum is encoded as u64 rather than u32.
    memory_section = section(5, b"\x01\x04" + memory_min_encoding)

    name = b"_start"
    export_payload = b"\x01" + uleb(len(name)) + name + b"\x00\x00"
    export_section = section(7, export_payload)

    # Function body: no locals; end.
    code_section = section(10, b"\x01\x02\x00\x0b")

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

    # Valid zero-page memory64 module.
    (args.output_dir / "memory64-valid-zero.wasm").write_bytes(module(b"\x00"))

    # Ten-byte encodings with nine zero payload continuation bytes.  In a valid
    # u64 encoding, the final payload may only be 0 or 1.  Final payloads 2 and
    # 127 encode values beyond 2^64-1 and must be rejected as integer overflow.
    prefix = b"\x80" * 9
    (args.output_dir / "memory64-overflow-2.wasm").write_bytes(
        module(prefix + b"\x02")
    )
    (args.output_dir / "memory64-overflow-127.wasm").write_bytes(
        module(prefix + b"\x7f")
    )

    for path in sorted(args.output_dir.glob("*.wasm")):
        print(f"{path.name}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
