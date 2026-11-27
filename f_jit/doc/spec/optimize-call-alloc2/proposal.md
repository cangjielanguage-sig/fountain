# 调用期两处分配：返回值解包闭包 + 零实参 cells

## Why

`JitFunction.callLocked` 每次调用有两处纯分配：

1. `marshal.makeRetUnboxer(unboxCode)(ret)`：为解包**现建一个闭包**再立即调用一次
   （`CallMarshal.cj:188`），既分配又付一次间接调用；
2. `Array<Int64>(args.size, repeat: 0)`：零实参单元（`{ => ... }`）也会分配一个长度 0 的数组。

在 3.0 µs 的短调用里，这两项属于纯开销；且调用路径已被 `optimize-helper-table` 证明
「每调用若做 O(1) 以上的固定工作，量级会很明显」。

## What Changes

1. **`CallMarshal.unboxRet(t, cell)`**：把解包体从闭包搬进方法，直接调用；
   `makeRetUnboxer` 保留并委托给它（测试在用，语义不变）。
2. **零实参共享空数组**：`args.size == 0` 时复用静态 `Array<Int64>()`（永不被写）。

**语义不变**：解包分支顺序、逃逸与登记、异常文案逐条不变；空 cells 不会被任何代码写入
（封送循环 `while (i < args.size)` 不执行）。

## Impact

- 收益目标：每次调用少 1 个闭包 + 1 次间接调用（零实参单元再少 1 个数组）；
- 影响文件：`src/CallMarshal.cj`、`src/JitFunction.cj`；
- 判定：`CallPathBench` 的 L1（同进程 5 万次 × 3 轮取最小）两臂 A/B；
  若无可测差异，按前两项的教训**如实记录、不宣称加速**。
