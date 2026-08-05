#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def uleb(value: int) -> bytes:
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


def module(flag: int) -> bytes:
    header = b"\x00asm\x01\x00\x00\x00"
    type_sec = section(1, b"\x01\x60\x00\x00")
    func_sec = section(3, b"\x01\x00")

    limits = bytes([flag]) + b"\x00"
    if flag & 1:
        limits += b"\x01"
    table_sec = section(4, b"\x01\x70" + limits)

    name = b"_start"
    export_sec = section(7, b"\x01" + uleb(len(name)) + name + b"\x00\x00")
    code_sec = section(10, b"\x01\x02\x00\x0b")
    return header + type_sec + func_sec + table_sec + export_sec + code_sec


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for flag in range(6):
        path = args.output_dir / f"table-flag-{flag}.wasm"
        path.write_bytes(module(flag))
        print(path.name, path.stat().st_size)


if __name__ == "__main__":
    main()
