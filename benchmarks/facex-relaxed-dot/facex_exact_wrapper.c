#include <stdint.h>

void int8_gemm_4x8c8(const int8_t* A, int M, int K, int N,
                     const void* B_packed, int32_t* C,
                     const int32_t* col_sums);

/* Execute the exact production function on a one-output, sixteen-term signed
 * dot product whose mathematical result is zero. */
__attribute__((export_name("facex_exact_mismatch")))
int32_t facex_exact_mismatch(void) {
  static const int8_t a[16] = {
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
  };
  static const int8_t b[16] = {
      1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1,
  };
  static const int32_t col_sums[1] = {16};
  int32_t out[1] = {0};
  int8_gemm_4x8c8(a, 1, 16, 1, b, out, col_sums);
  return out[0] != 0;
}

__attribute__((export_name("facex_exact_result")))
int32_t facex_exact_result(void) {
  static const int8_t a[16] = {
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
  };
  static const int8_t b[16] = {
      1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1,
  };
  static const int32_t col_sums[1] = {16};
  int32_t out[1] = {0};
  int8_gemm_4x8c8(a, 1, 16, 1, b, out, col_sums);
  return out[0];
}
