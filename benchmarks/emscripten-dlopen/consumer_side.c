extern int zombie_value(void);

__attribute__((visibility("default")))
int consumer_value(void) {
  return zombie_value();
}
