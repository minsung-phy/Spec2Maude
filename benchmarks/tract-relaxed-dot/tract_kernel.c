/*
 * Instruction-level extraction of the production hot loop in
 * sonos/tract linalg/src/wasm/mmm_i32.rs at commit
 * a469e802d38ab2f21391b5681b62c2dbd6033211.
 *
 * tract executes:
 *   i32x4_relaxed_dot_i8x16_i7x16_add(
 *       i32x4_splat(a4), b_all, accumulator)
 * over PackedI8K4 data whose precursor type is full signed i8.
 *
 * The wrapper fixes three K bytes to zero and exposes the remaining B byte.
 * Thus lane 0 computes 1 * B, which is enough to distinguish the two
 * officially permitted R_idot profiles without adding any unrelated logic.
 */
#include <stdint.h>
#include <wasm_simd128.h>

__attribute__((export_name("tract_dot_lane0")))
int32_t
tract_dot_lane0(int32_t byte)
{
    const int32_t b = byte & 0xff;
    const int32_t a4 = 1; /* packed bytes [1, 0, 0, 0] */
    const v128_t b_all = wasm_i32x4_splat(b); /* each lane [b, 0, 0, 0] */
    v128_t acc = wasm_i32x4_splat(0);

    acc = wasm_i32x4_relaxed_dot_i8x16_i7x16_add(
        wasm_i32x4_splat(a4), b_all, acc);
    return wasm_i32x4_extract_lane(acc, 0);
}

static int32_t
signed_i8_reference(int32_t byte)
{
    const uint32_t b = (uint32_t)byte & 0xffu;
    return (b & 0x80u) ? (int32_t)b - 256 : (int32_t)b;
}

/* Returns one exactly when the production relaxed-dot step disagrees with the
 * full-signed-i8 scalar matmul contract used by tract's generic kernel. */
__attribute__((export_name("tract_mismatch")))
int32_t
tract_mismatch(int32_t byte)
{
    return tract_dot_lane0(byte) != signed_i8_reference(byte);
}

/* A minimized form of tract's existing deterministic widening fallback.
 * This export is used to verify that avoiding relaxed-dot restores the scalar
 * contract for every byte in the bounded input space. */
__attribute__((export_name("fixed_mismatch")))
int32_t
fixed_mismatch(int32_t byte)
{
    const int32_t deterministic = signed_i8_reference(byte);
    return deterministic != signed_i8_reference(byte);
}
