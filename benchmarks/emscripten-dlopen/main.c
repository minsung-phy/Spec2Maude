#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

#include <emscripten.h>

typedef int (*zombie_value_fn)(void);

EM_JS(int, wasm_table_length, (), {
  return Number(wasmTable.length);
});

EM_JS(int, wasm_table_slot_callable, (int index), {
  return typeof wasmTable.get(index) === 'function';
});

EM_JS(int, call_wasm_table_slot, (int index), {
  return wasmTable.get(index)();
});

static void attempt(int number) {
  int table_before = wasm_table_length();
  printf("attempt_%d_table_before=%d\n", number, table_before);

  dlerror();
  void *handle = dlopen("libbad.wasm", RTLD_NOW | RTLD_LOCAL);
  const char *open_error = dlerror();

  printf("attempt_%d_table_after=%d\n", number, wasm_table_length());
  printf("attempt_%d_handle_nonnull=%d\n", number, handle != NULL);
  printf("attempt_%d_open_error=%s\n", number,
         open_error ? open_error : "<none>");

  if (!handle) {
    if (number == 1) {
      int callable = wasm_table_slot_callable(table_before);
      printf("attempt_1_residual_slot_callable=%d\n", callable);
      if (callable) {
        printf("attempt_1_residual_result_1=%d\n",
               call_wasm_table_slot(table_before));
        printf("attempt_1_residual_result_2=%d\n",
               call_wasm_table_slot(table_before));
      }
    }
    return;
  }

  dlerror();
  zombie_value_fn zombie_value =
      (zombie_value_fn)(uintptr_t)dlsym(handle, "zombie_value");
  const char *symbol_error = dlerror();

  printf("attempt_%d_symbol_nonnull=%d\n", number, zombie_value != NULL);
  printf("attempt_%d_symbol_error=%s\n", number,
         symbol_error ? symbol_error : "<none>");

  if (zombie_value) {
    printf("attempt_%d_symbol_result=%d\n", number, zombie_value());
  }
}

int main(void) {
  attempt(1);
  attempt(2);
  return 0;
}
