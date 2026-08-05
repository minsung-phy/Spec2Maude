#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

#ifndef LOAD_GLOBAL
#define LOAD_GLOBAL 0
#endif

#ifdef __EMSCRIPTEN__
#define PROVIDER_NAME "liblocal-provider.wasm"
#define CONSUMER_NAME "liblocal-consumer.wasm"
#else
#define PROVIDER_NAME "./liblocal-provider.so"
#define CONSUMER_NAME "./liblocal-consumer.so"
#endif

typedef int (*value_fn)(void);

static value_fn lookup(void *handle, const char *name, const char *label) {
  dlerror();
  value_fn function = (value_fn)(uintptr_t)dlsym(handle, name);
  const char *error = dlerror();
  printf("%s_symbol_nonnull=%d\n", label, function != NULL);
  printf("%s_symbol_error=%s\n", label, error ? error : "<none>");
  return function;
}

int main(void) {
  int provider_flags = RTLD_NOW | (LOAD_GLOBAL ? RTLD_GLOBAL : RTLD_LOCAL);
  printf("provider_requested_global=%d\n", LOAD_GLOBAL);

  dlerror();
  void *provider = dlopen(PROVIDER_NAME, provider_flags);
  const char *provider_error = dlerror();
  printf("provider_handle_nonnull=%d\n", provider != NULL);
  printf("provider_open_error=%s\n",
         provider_error ? provider_error : "<none>");

  if (!provider) {
    return 0;
  }

  value_fn direct = lookup(provider, "local_only", "provider");
  if (direct) {
    printf("provider_direct_result=%d\n", direct());
  }

  value_fn global = lookup(RTLD_DEFAULT, "local_only", "default");
  if (global) {
    printf("default_result=%d\n", global());
  }

  dlerror();
  void *consumer = dlopen(CONSUMER_NAME, RTLD_NOW | RTLD_LOCAL);
  const char *consumer_error = dlerror();
  printf("consumer_handle_nonnull=%d\n", consumer != NULL);
  printf("consumer_open_error=%s\n",
         consumer_error ? consumer_error : "<none>");

  if (consumer) {
    value_fn call_local = lookup(consumer, "call_local", "consumer");
    if (call_local) {
      printf("consumer_result=%d\n", call_local());
    }
  }

  return 0;
}
