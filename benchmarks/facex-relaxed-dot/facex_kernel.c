/*
 * Instruction-level extraction of facex-engine/facex
 * wasm/src/gemm_int8_rsimd.c at
 * af7ca9937705a10901ca4b72c4eb19ef49a4ac53.
 *
 * The production code computes A_s8 * B_s8. It adds 128 to A, feeds that
 * vector as operand 1 of i32x4.relaxed_dot_i8x16_i7x16_add_s, and subtracts
 * 128 * sum(B). Official Wasm semantics always interprets operand 1 as
 * signed; only operand 2 is selected as signed/unsigned by R_idot.
 */
#include <stdint.h>
#include <wasm_simd128.h>

static int32_t signed_i8(int32_t x) {
  x &= 255;
  return (x & 128) ? x - 256 : x;
}

__attribute__((export_name("facex_current_result")))
int32_t facex_current_result(int32_t a_byte) {
  int32_t a = signed_i8(a_byte);
  const int32_t b = 1;
  v128_t va_s8 = wasm_i8x16_splat(a);
  v128_t offset = wasm_i8x16_splat(-128);
  v128_t va_u8 = wasm_i8x16_sub(va_s8, offset);
  v128_t vb = wasm_i8x16_splat(b);
  v128_t acc = wasm_i32x4_splat(0);
  acc = wasm_i32x4_relaxed_dot_i8x16_i7x16_add(va_u8, vb, acc);
  int32_t sum = wasm_i32x4_extract_lane(acc, 0)
              + wasm_i32x4_extract_lane(acc, 1)
              + wasm_i32x4_extract_lane(acc, 2)
              + wasm_i32x4_extract_lane(acc, 3);
  return sum - 128 * (16 * b);
}

__attribute__((export_name("facex_current_mismatch")))
int32_t facex_current_mismatch(int32_t a_byte) {
  int32_t reference = 16 * signed_i8(a_byte);
  return facex_current_result(a_byte) != reference;
}

/* The tempting operand-swap repair matches an x86-like R_idot=1 profile, but
 * remains wrong under the equally legal signed-second-operand profile. */
__attribute__((export_name("facex_swap_mismatch")))
int32_t facex_swap_mismatch(int32_t a_byte) {
  int32_t a = signed_i8(a_byte);
  const int32_t b = 1;
  v128_t va_s8 = wasm_i8x16_splat(a);
  v128_t offset = wasm_i8x16_splat(-128);
  v128_t va_u8 = wasm_i8x16_sub(va_s8, offset);
  v128_t vb = wasm_i8x16_splat(b);
  v128_t acc = wasm_i32x4_splat(0);
  acc = wasm_i32x4_relaxed_dot_i8x16_i7x16_add(vb, va_u8, acc);
  int32_t sum = wasm_i32x4_extract_lane(acc, 0)
              + wasm_i32x4_extract_lane(acc, 1)
              + wasm_i32x4_extract_lane(acc, 2)
              + wasm_i32x4_extract_lane(acc, 3);
  int32_t result = sum - 128 * (16 * b);
  return result != 16 * a;
}

__attribute__((export_name("facex_portable_mismatch")))
int32_t facex_portable_mismatch(int32_t a_byte) {
  int32_t a = signed_i8(a_byte);
  int32_t result = 16 * a;
  return result != 16 * a;
}
