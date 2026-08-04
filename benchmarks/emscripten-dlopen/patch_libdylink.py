#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = """    if (flags.loadAsync) {
#if DYLINK_DEBUG
      dbg('loadDynamicLibrary: done (async)');
#endif
      return getExports().then((exports) => {
        moduleLoaded(exports);
        return true;
      });
    }

    moduleLoaded(getExports());
"""
new = """    function moduleLoadFailed(error) {
      // A failed load must not leave a DSO cached as `loading`, otherwise a
      // later dlopen treats it as an already loaded library and returns a
      // poisoned non-null handle.
      delete LDSO.loadedLibsByName[libName];
      if (handle) {
        delete LDSO.loadedLibsByHandle[handle];
      }
      throw error;
    }

    if (flags.loadAsync) {
#if DYLINK_DEBUG
      dbg('loadDynamicLibrary: done (async)');
#endif
      return getExports().then((exports) => {
        moduleLoaded(exports);
        return true;
      }, moduleLoadFailed);
    }

    try {
      moduleLoaded(getExports());
    } catch (error) {
      moduleLoadFailed(error);
    }
"""
if old not in text:
    raise SystemExit("expected libdylink.js block was not found")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print(f"patched {path}")
