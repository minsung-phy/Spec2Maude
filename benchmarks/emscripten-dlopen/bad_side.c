#include <stdlib.h>

__attribute__((constructor))
static void fail_constructor(void) {
  abort();
}

__attribute__((visibility("default")))
int zombie_value(void) {
  static int counter = 40;
  return ++counter;
}
