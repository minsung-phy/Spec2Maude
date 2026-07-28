(module $Writer
  (table $table (import "spectest" "table") 10 20 funcref)
  (table $table64 (import "spectest" "table64") i64 10 20 funcref)
  (func $target)
  (elem declare func $target)
  (func (export "write")
    i32.const 0
    ref.func $target
    table.set $table
    i64.const 0
    ref.func $target
    table.set $table64))

(module $Reader
  (table $table (import "spectest" "table") 10 20 funcref)
  (table $table64 (import "spectest" "table64") i64 10 20 funcref)
  (func (export "read-table") (result i32)
    i32.const 0
    table.get $table
    ref.is_null)
  (func (export "read-table64") (result i32)
    i64.const 0
    table.get $table64
    ref.is_null))

(invoke $Writer "write")
(assert_return (invoke $Reader "read-table") (i32.const 0))
(assert_return (invoke $Reader "read-table64") (i32.const 0))
