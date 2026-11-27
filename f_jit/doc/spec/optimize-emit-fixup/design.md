# 设计：标签索引 + 单遍回填

## 1. 现状与问题

`A64Emitter` 存标签用的是追加列表，查标签用线性扫：

```
bind(name)        -> labels.add(A64Label(name, out.size))
labelOffset(name) -> for (l in labels) { if (l.name == name) return l.at }  // O(L)
```

`A64Lower` 在每条字节码指令前 `bind('L${off}')`，另有 `'chkN'` / `'asmN'` / `'okN'` 等标签，
所以 L 与指令数同阶。`finishOrNull` 对 R 条重定位各查一次，`finish` 再各查一次：

| 量 | 规模（本变更基线） |
| --- | --- |
| 机器码 | 9644 B = 2411 字 |
| 标签 L | 与指令数同阶（数百） |
| 重定位 R | 与分支数同阶（数百） |
| 字符串比较次数 | ≈ 2 × R × L |

`String ==` 对同长度、共享前缀的名字（`L1200` vs `L1201`）要走完整比较，每次约 20–50 ns，
于是单函数就是 30–50 ms。

## 2. 方案

### 2.1 标签用哈希索引

```
private let labels: HashMap<String, Int64>
bind(name)        -> 未绑定才 add(name, out.size)      // 保留「首个绑定优先」
labelOffset(name) -> labels.get(name) ?? -1
```

**为什么保留「首个绑定优先」**：旧实现线性扫返回第一个同名项。当前 `A64Lower` 的标签名
都带唯一 `at`/`seq`（`L${off}`、`chk${at}`、`dec${seq}`…），理论上不会重名；
但保留旧语义可以让这次改动**只改复杂度、不改可观察行为**，避免「某个名字恰好重名」
这种隐性依赖被悄悄改变。代价是 `bind` 多一次查表。

### 2.2 回填合成一遍

旧实现：

```
finishOrNull(): for r in relocs { 查标签; 校验 delta%4 与范围 }      // 第一遍
               finish():       for r in relocs { 查标签; 回填 }    // 第二遍
```

新实现：

```
private func resolve(checkRange: Bool): ?Array<UInt8>
    for r in relocs:
        delta = labelOffset(r.label) - r.at        // O(1)
        if checkRange: 校验 delta%4 / ±128MB / ±1MB，越界 return None
        回填 imm26 或 imm19
    done = true
    Some(out.toArray())

finish()        = resolve(false)
finishOrNull()  = resolve(true)
```

**等价性**：校验条件、位域运算、`done` 幂等标志逐条保留。唯一差异是「越界时前面几条已被回填」——
该发射器对象在越界路径上被直接丢弃（`A64Compiler.compileFunctionWith` 用**新的** `A64Emitter`
做 farCond 第二遍），没有任何读者能看到这些半成品字节。

### 2.3 不动的部分

- `A64Lower` 的标签命名与 `bind` 调用点：一个不改，避免牵连降低器；
- `readWord` / `patchWord` 的逐字节读写：R 条重定位 × 8 字节，量级在 µs，不值得改成指针访问；
- 前端（parse / lower / assemble / load）：本轮不做，见 §3。

## 3. 为什么先不动前端

前端合计 5.5 ms，其中 `assemble` 1.6 ms、`parse` 1.0 ms、`lower` 0.9 ms、`load` 0.77 ms。
这些是真实工作量（词法、语法、降低、拼装、校验），不是复杂度问题；
在没有更细的 profile 前做「猜热点」式微调，不符合 `optimize-call-path.md` §1 的 MOV 规则。
`normalizeNewlines` 在整条管线被调 4 次（`SourceCompiler` / `Parser` / `Lexer` / `NameResolver` /
`DefiniteAssignment` 各一次），实测合计 38 µs，占改后总延迟 0.5%，**本轮不立项**。

## 4. 护栏设计

新增 `A64EmitterFixup_test`（`src/backend`，同包可访问 `internal` 发射器）：

| 用例 | 断言 |
| --- | --- |
| `branchesResolveToExactOffsets` | 建 200 个 `L<k>` 标签，每个标签前发 1 条 `b`，回填后逐字解码 imm26，必须等于 `(target-at)/4` |
| `firstBindWins` | 同名 `bind` 两次，`labelOffset` 返回第一次的偏移（旧语义） |
| `conditionalKindsUseImm19` | `bCond` / `cbz` 回填后 imm19 位域正确（kind 1/2 不串位） |
| `finishIsIdempotent` | `finishOrNull()` 后再 `finish()`，字节逐位相同 |
| `missingLabelStillResolvesLikeBefore` | 未绑定名字 → `labelOffset == -1`，`finishOrNull` 不 panic |

变异验证：

| 变异 | 期望 |
| --- | --- |
| `bind` 改为「总是覆盖」 | `firstBindWins` 必须红 |
| 只查一次标签但 `finish()` 用 `kind` 常量 0 回填 | `conditionalKindsUseImm19` 必须红 |

## 5. 判定规则

按 `doc/optimize-call-path.md` §1：MOV = `max(3%, 2×离散度)`。本项预期 **−80%**，
远超阈值，只要 A/B 同轮配对方向一致即判 keep。
