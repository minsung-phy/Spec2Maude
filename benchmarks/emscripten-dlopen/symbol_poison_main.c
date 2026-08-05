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

  /* Try to consume zombie_value immediately, before any successful provider
     for that symbol has been loaded. */
  dlerror();
  void *pre_consumer =
      dlopen("libconsumer-pre.wasm", RTLD_NOW | RTLD_LOCAL);
  const char *pre_consumer_error = dlerror();
  print_open("pre_consumer", pre_consumer, pre_consumer_error);

  value_fn pre_consumer_value = NULL;
  if (pre_consumer) {
    pre_consumer_value =
        lookup(pre_consumer, "consumer_value", "pre_consumer");
    if (pre_consumer_value) {
      printf("pre_consumer_result_1=%d\n", pre_consumer_value());
      printf("pre_consumer_result_2=%d\n", pre_consumer_value());
    }
  }

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

  if (pre_consumer_value) {
    printf("pre_consumer_after_good_result=%d\n", pre_consumer_value());
  }

  /* A fresh consumer loaded after the good provider is the control case. */
  dlerror();
  void *post_consumer =
      dlopen("libconsumer-post.wasm", RTLD_NOW | RTLD_LOCAL);
  const char *post_consumer_error = dlerror();
  print_open("post_consumer", post_consumer, post_consumer_error);

  if (post_consumer) {
    value_fn post_consumer_value =
        lookup(post_consumer, "consumer_value", "post_consumer");
    if (post_consumer_value) {
      printf("post_consumer_result=%d\n", post_consumer_value());
    }
  }

  return 0;
}
