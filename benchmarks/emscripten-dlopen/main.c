#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

#include <emscripten.h>

typedef int (*zombie_value_fn)(void);

EM_JS(int, wasm_table_length, (), {
  return Number(wasmTable.length);
});

static void attempt(int number) {
  printf("attempt_%d_table_before=%d\n", number, wasm_table_length());

  dlerror();
  void *handle = dlopen("libbad.wasm", RTLD_NOW | RTLD_LOCAL);
  const char *open_error = dlerror();

  printf("attempt_%d_table_after=%d\n", number, wasm_table_length());
  printf("attempt_%d_handle_nonnull=%d\n", number, handle != NULL);
  printf("attempt_%d_open_error=%s\n", number,
         open_error ? open_error : "<none>");

  if (!handle) {
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
