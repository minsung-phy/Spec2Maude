__attribute__((constructor))
static void fail_constructor(void) {
  __builtin_trap();
}

__attribute__((visibility("default")))
int zombie_value(void) {
  static int counter = 40;
  return ++counter;
}
