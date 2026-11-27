# 编译延迟：A64 分支回填从 O(R×L) 降到 O(R)

## Why

2026-11-27 分段探针（200 注册函数 × 50 调用点，1 个函数、1230 字节字节码、9644 字节机器码；
5 轮取最小，load 5.0–7.8）：

| 阶段 | 实测 | 占单次编译 |
| --- | --- | --- |
| `JitExecutor.create` | **37.7 ms** | **87%** |
| 其中 `JitCompiler.compileUnitWith` | 37.7 ms | 87% |
| 其中 `A64Compiler.compileOnce` 的 `finishOrNull` | **33–53 ms** | **78–92%** |
| 其中 `A64Lower.lower` | 1.3–1.8 ms | 3–4% |
| 前端 `SourceCompiler.compile` 合计 | 5.5 ms | 13% |
| ├ `assemble` | 1.6 ms | 3.7% |
| ├ `parse`（含分词） | 1.0 ms | 2.3% |
| ├ `lower` | 0.9 ms | 2.1% |
| ├ `FbcReader.load` | 0.77 ms | 1.8% |
| └ `normalize` 4 次 + DA + 各构造 | 0.3 ms | 0.7% |

根因在 `A64Emitter`：

1. `bind` 是 `ArrayList<A64Label>` 追加；`labelOffset(name)` **线性扫描全表**；
2. `A64Lower` 对每个字节码偏移都 `bind('L${off}')`，并大量 `bind('chk${at}')` / `'ok${at}'` 等，
   标签数 L 与指令数同阶；
3. `finishOrNull()` 对每条重定位调一次 `labelOffset`，随后 `finish()` **再对每条重定位调一次**
   —— 同一份 O(R×L) 做两遍。

单函数 2411 条指令要 33–53 ms，即约 15 µs/指令，属病态复杂度，不是发码本身的开销。

## What Changes

1. **标签索引化**：`A64Emitter.labels` 由 `ArrayList<A64Label>` 改为 `HashMap<String, Int64>`；
   `bind` 只在名字**未绑定**时写入（保持旧「首个匹配」语义），`labelOffset` 变 O(1)。
2. **回填合并为一遍**：新增 `private func resolve(checkRange: Bool): ?Array<UInt8>`，
   一次遍历同时完成「查标签 → 校验范围 → 回填 imm」；
   `finish()` = `resolve(false)`，`finishOrNull()` = `resolve(true)`。
   旧实现是「先全量校验、再全量回填」两遍，语义等价，失败时同样不产出字节。
3. 删除只服务于线性扫的 `A64Label` 结构（`A64Emitter.cj` 内唯一使用点）。

**语义不变**：标签首次绑定优先、`b/bl` imm26 与 `b.cond/cbz/cbnz` imm19 的位域、
±128 MB / ±1 MB 范围判定、失败返回 `None` 的路径全部保持逐位一致。

## Impact

- 收益目标：`A64Emitter.finishOrNull` **≥10×**（33–53 ms → 亚毫秒），
  单次编译总延迟从 ~38–40 ms 降到 ~7–8 ms（**−80%**）；
- 影响文件：`src/backend/A64Emitter.cj`（+ 护栏用例 `A64EmitterFixup_test.cj`）；
- 风险：标签重名时「首个绑定优先」的语义必须保留（否则同一名字二次 `bind` 会改变跳转目标）；
  回填合并后若范围校验失败，已回填的字留在对象内——但该对象随即被丢弃
  （`compileFunctionWith` 越界时新建发射器重试），无可观察差异。
