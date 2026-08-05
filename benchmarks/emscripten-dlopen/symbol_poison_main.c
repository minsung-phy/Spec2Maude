#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

typedef int (*value_fn)(void);

static void print_open(const char *label, void *handle, const char *error) {
  printf("%s_handle_nonnull=%d\n", label, handle != NULL);
  printf("%s_open_error=%s\n", label, error ? error : "<none>");
}

static value_fn lookup(void *handle, const char *name, const char *label) {
  dlerror();
  value_fn function = (value_fn)(uintptr_t)dlsym(handle, name);
  const char *error = dlerror();
  printf("%s_symbol_nonnull=%d\n", label, function != NULL);
  printf("%s_symbol_error=%s\n", label, error ? error : "<none>");
  return function;
}

int main(void) {
  dlerror();
  void *bad = dlopen("libbad.wasm", RTLD_NOW | RTLD_GLOBAL);
  const char *bad_error = dlerror();
  print_open("bad", bad, bad_error);

  dlerror();
  void *good = dlopen("libgood.wasm", RTLD_NOW | RTLD_GLOBAL);
  const char *good_error = dlerror();
  print_open("good", good, good_error);

  value_fn good_value = NULL;
  if (good) {
    good_value = lookup(good, "zombie_value", "good");
    if (good_value) {
      printf("good_direct_result=%d\n", good_value());
    }
  }

  dlerror();
  void *consumer = dlopen("libconsumer.wasm", RTLD_NOW | RTLD_LOCAL);
  const char *consumer_error = dlerror();
  print_open("consumer", consumer, consumer_error);

  if (consumer) {
    value_fn consumer_value = lookup(consumer, "consumer_value", "consumer");
    if (consumer_value) {
      printf("consumer_result_1=%d\n", consumer_value());
      printf("consumer_result_2=%d\n", consumer_value());
    }
  }

  return 0;
}
