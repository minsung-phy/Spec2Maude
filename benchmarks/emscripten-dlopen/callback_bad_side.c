typedef int (*value_fn)(void);

extern void install_callback(value_fn callback);

__attribute__((visibility("default")))
int failed_plugin_callback(void) {
  static int counter = 70;
  return ++counter;
}

__attribute__((constructor))
static void register_then_fail(void) {
  install_callback(failed_plugin_callback);
  __builtin_trap();
}
