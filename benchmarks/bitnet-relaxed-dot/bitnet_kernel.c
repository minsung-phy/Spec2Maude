/*
 * Instruction-level extraction of the production Wasm logits loop in
 * artalis-io/bitnet.c src/transformer/logits_wasm.c at commit
 * bfd5877d44a28c152c2fbee8e134b423e3bfe0e7.
 *
 * The production loop feeds signed int8 embedding weights as operand one and
 * signed int8 quantized activations as operand two to
 * i32x4.relaxed_dot_i8x16_i7x16_add.  The scalar reference multiplies both as
 * signed int8.  This wrapper isolates one nonzero byte and compares the exact
 * relaxed instruction with that scalar contract.
 */
#include <stdint.h>
#include <wasm_simd128.h>

__attribute__((export_name("bitnet_dot_lane0")))
int32_t
bitnet_dot_lane0(int32_t activation_byte)
{
    const int32_t x = activation_byte & 0xff;
    const v128_t weight = wasm_i32x4_splat(1); /* bytes [1,0,0,0] per lane */
    const v128_t activation = wasm_i32x4_splat(x);
    const v128_t acc = wasm_i32x4_splat(0);
    const v128_t result = wasm_i32x4_relaxed_dot_i8x16_i7x16_add(
        weight, activation, acc);
    return wasm_i32x4_extract_lane(result, 0);
}

static int32_t
signed_i8_reference(int32_t byte)
{
    const uint32_t x = (uint32_t)byte & 0xffu;
    return (x & 0x80u) ? (int32_t)x - 256 : (int32_t)x;
}

__attribute__((export_name("bitnet_mismatch")))
int32_t
bitnet_mismatch(int32_t activation_byte)
{
    return bitnet_dot_lane0(activation_byte)
        != signed_i8_reference(activation_byte);
}

/* Deterministic replacement used to show that avoiding the relaxed dot for
 * signed×signed operands restores the scalar logits contract. */
__attribute__((export_name("fixed_mismatch")))
int32_t
fixed_mismatch(int32_t activation_byte)
{
    const int32_t result = signed_i8_reference(activation_byte);
    return result != signed_i8_reference(activation_byte);
}
