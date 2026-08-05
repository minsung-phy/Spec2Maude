extern int local_only(void);

__attribute__((visibility("default")))
int call_local(void) {
  return local_only();
}
