#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

maude -no-banner "$here/fib-baseline.maude" 2>&1 \
  | tee "$here/fib-baseline.log"

maude -no-banner "$here/fib-sorted.maude" 2>&1 \
  | tee "$here/fib-sorted.log"

