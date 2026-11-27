# 编译等待超时与编译失败的语义区分（H6）

## Why

`src/CompileCache.cj` 的 `awaitReady()` 在 30 s 后返回 `None`，而
`src/CompilePipeline.cj` 的 `None` 分支统一抛 `CompileFailed`（或复述失败文本）。

于是两种完全不同的情况对调用方**长得一样**：

1. 首次编译真的失败了（源码错误）——失败文本被共享；
2. 等待者超时（首编线程卡住/极慢）——缓存里既没有失败文本也没有结果。

调用方无法区分「我的源码有问题」和「等太久了」，诊断信息也不足。

## What Changes

1. `CompileCache` 增加 `internal static var awaitTimeoutNs`（默认 30 s，测试可调小）；
   `awaitReady()` 用它代替硬编码的 30 s。
2. 新增 `isCompiling(key): Bool`（锁内查 `compiling`）。
3. `CompilePipeline` 抽一个纯函数 `missingResult(key): (DiagKind 文本, 消息)`：
   - 有失败文本 → `('CompileFailed', 文本)`（原行为）；
   - 仍在编译 → `('CompileTimeout', '编译等待超时（N s）：同键编译未在期限内完成')`；
   - 其它（已被移除/从未登记）→ `('CompileFailed', '编译失败')`。
   `runSource` / `runUnit` 的 `None` 分支改用它。

`SourceCompileException.kind` 是自由字符串（`DiagKind` 常量只是清单），新增
`CompileTimeout` 不需要改错误码体系——编译期异常本就不占用运行期 `ErrCode`。

## Impact

- 影响文件：`src/CompileCache.cj`、`src/CompilePipeline.cj`；新增护栏 `src/CompileAwaitTimeout_test.cj`；
- 行为：正常路径（编译成功/失败）完全不变；只有「等待超时」从 `CompileFailed` 变为
  `CompileTimeout` 且消息带秒数；
- 风险：低。超时值可配后，测试能在 1 ms 内验证，不需要构造慢编译。
