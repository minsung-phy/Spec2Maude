#include <dlfcn.h>
#include <emscripten/emscripten.h>
#include <stdio.h>

typedef int (*value_fn)(void);

static int safe_callback(void) {
  return 7;
}

static value_fn installed_callback = safe_callback;

EMSCRIPTEN_KEEPALIVE
void install_callback(value_fn callback) {
  installed_callback = callback;
}

int main(void) {
  printf("callback_before=%d\n", installed_callback());

  dlerror();
  void *handle = dlopen("libcallback-bad.wasm", RTLD_NOW | RTLD_LOCAL);
  const char *error = dlerror();
  printf("callback_load_handle_nonnull=%d\n", handle != NULL);
  printf("callback_load_error=%s\n", error ? error : "<none>");

  printf("callback_after_failure_1=%d\n", installed_callback());
  printf("callback_after_failure_2=%d\n", installed_callback());
  return 0;
}
