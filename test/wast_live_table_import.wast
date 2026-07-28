(module $Provider
  (table (export "table") 1 3 funcref)
  (func (export "grow") (result i32)
    (table.grow (ref.null func) (i32.const 1)))
  (func (export "size") (result i32) table.size))
(register "grown-table" $Provider)
(assert_return (invoke $Provider "grow") (i32.const 1))

(module $Consumer
  (table (import "grown-table" "table") 2 3 funcref)
  (func (export "size") (result i32) table.size))
(assert_return (invoke $Consumer "size") (i32.const 2))
(assert_return (invoke $Provider "size") (i32.const 2))
