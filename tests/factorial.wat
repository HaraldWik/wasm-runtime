(module
  (type (;0;) (func (param f64) (result f64)))
  (func $fac (type 0) (param f64) (result f64)
    local.get 0
    f64.const 0x1p+0 (;=1;)
    f64.lt
    if (result f64)  ;; label = @1
      f64.const 0x1p+0 (;=1;)
    else
      local.get 0
      local.get 0
      f64.const 0x1p+0 (;=1;)
      f64.sub
      call $fac
      f64.mul
    end)
  (export "fac" (func $fac)))
