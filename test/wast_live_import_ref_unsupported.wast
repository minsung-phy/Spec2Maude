(module $Provider
  (table (export "table") 1 3 funcref))
(register "funcref-table" $Provider)

(module
  (table (import "funcref-table" "table") 2 3 externref))
