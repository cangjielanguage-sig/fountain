# 设计：`truncateUtf8` 惰性单遍扫描

## 1. 目标与约束

**目标**：把 `McpServer.truncateUtf8` 的额外内存从「文本字节的 1–4 倍」降到「与输出同阶（≤ limit）」，
同时输出逐字节不变。

**硬约束**：

| 约束 | 判定方式 |
| --- | --- |
| 结果与旧实现逐字节一致 | 测试内保留旧算法作 oracle，语料 × 边界 limit 全量比对 |
| `limit <= 0` → `''`、`limit >= size` → 原串 | 既有用例 + 新增零复制用例 |
| 结果 ≤ `limit` 字节、rune 对齐、合法 UTF-8 | 逐 rune 宽度累加（与旧实现同一判据） |
| 公开 API 不变 | 签名、访问级别、所在类型不动 |
| 不引入耗时门禁 | 基准只打印耗时，断言只用分配字节 |

## 2. 现状与成本

`f_mcp/src/server/McpServer.cj:1140-1164`：

```cangjie
static func truncateUtf8(text: String, limit: Int64): String {
    if (limit <= 0) {
        return ''
    }
    let builder = StringBuilder()
    var used: Int64 = 0
    for (r in text.toRuneArray()) {     // ← 全量物化
        let code = UInt32(r)
        let size: Int64 = if (code < 0x80) { 1 } else if (code < 0x800) { 2 }
            else if (code < 0x10000) { 3 } else { 4 }
        if (used + size > limit) {
            break
        }
        builder.append(r)
        used += size
    }
    builder.toString()
}
```

调用链：`applyLargeResult`（`1095`）→（无 `publicBaseUrl` 或 `put` 失败）→
`truncated`（`1123`）→ `truncateUtf8`。进入前已有一份完整 JSON 字符串（`json`）。

三块额外内存：

| 项 | 规模 | 可消除 |
| --- | --- | --- |
| `Array<Rune>` | `runeCount × 4` 字节（ASCII 为 4 × 字节数；中文 1.33×；emoji 1×） | 是 |
| `StringBuilder` 几何扩容的临时数组 | 与输出同阶的若干份历史缓冲 | 是（预分配） |
| 输出 `String` | ≤ `limit` | 否（返回值本身） |

`docs/LocalMode.md:436` 已把此处列为「先做结构性优化（收益确定）」的典型：
`toRuneArray()` 把 1 MB 文本放大成上百万个 Rune。

## 3. 方案对比

| 方案 | 额外内存 | 风险 | 结论 |
| --- | --- | --- | --- |
| **A 现状**：`toRuneArray` + 逐 rune | 1–4 × 文本字节 | 无 | 否 |
| **B `@ local!` rune 数组**（`LocalMode.md:317` 的次选） | 同上，只是挪进 local region | `String` / 返回值跨越 public 边界；local 构造需文档确认 | 否 |
| **C 直接 UTF-8 字节切片 + 边界回退** | ≈ 输出字节 | 需要 `unsafeBytes` 手工判边界，非法字节处理要自己保证 | 否（记录为后续可选项） |
| **D 惰性 `runes()` 单遍 + 快速路径 + 预算容量** | ≈ 输出字节 + O(1) 迭代器 | `StringBuilder(capacity)` 已确认（std `string_builder.cj:82`） | **采纳** |

选 D：收益与 C 同阶（都去掉全量数组），但不需要碰 `unsafeBytes`，边界判定与旧实现
完全同一套代码，等价性可证明。C 的余量只有「少一次 rune 解码」，对 1 MiB 量级不构成拐点，
留作后续（§8）。

## 4. 详细设计

### 4.1 代码形态

```cangjie
static func truncateUtf8(text: String, limit: Int64): String {
    if (limit <= 0) {
        return ''
    }
    if (limit >= text.size) {          // text.size 是 UTF-8 字节数
        return text                     // 零复制
    }
    let builder = StringBuilder(limit)  // 上界已确定，一次预留
    var used: Int64 = 0
    for (r in text.runes()) {           // 惰性迭代，不物化
        let code = UInt32(r)
        let size: Int64 = if (code < 0x80) {
            1
        } else if (code < 0x800) {
            2
        } else if (code < 0x10000) {
            3
        } else {
            4
        }
        if (used + size > limit) {
            break
        }
        builder.append(r)
        used += size
    }
    builder.toString()
}
```

改动点只有四处：`toRuneArray()` → `runes()`、新增 `limit >= text.size` 分支、
`StringBuilder()` → `StringBuilder(limit)`、其余一行不动。

### 4.2 为什么 `limit >= text.size` 是安全的

- `String.size` 是 UTF-8 字节数：`applyLargeResult`（`McpServer.cj:1100`）用
  `json.size <= limit` 与字节阈值比较，`truncated` 的 `limit` 也是字节口径。
- 若 `limit >= size`，则整串每个 rune 都能放下（各 rune 宽度之和恰为 `size ≤ limit`），
  旧实现会走完整个循环、把每个 rune 原样 append 一遍，输出与 `text` 逐字节相同。
- 因此「返回 `text`」与旧结果等价，且省掉一次完整复制与一次全量扫描。
- 生产路径上 `truncated()` 只在 `json.size > limit` 时被调用，该分支通常不可达；
  保留它是为了让函数对任意调用方都有完整、O(1) 的定义（既有用例
  `McpServer_test.cj:828` 的 `limit == size` 正落在这里）。

### 4.3 为什么容量可以取 `limit`

走到扫描时已保证 `0 < limit < text.size`：

- 输出字节数 `used <= limit`，且 `limit` 是 `Int64`、`text` 至少有 `limit + 1` 字节，
  预留不会超出输入量级；
- 预留 `limit` 后，`used + size > limit` 的 `break` 最多让实际输出比 `limit` 少 3 字节，
  不产生扩容；
- 由此额外内存 = 输出缓冲（≤ `limit`）+ 一个迭代器对象，与输入长度解耦。

### 4.4 等价性论证

对新旧实现，对同一 `(text, limit)`：

1. `limit <= 0`：两者都返回 `''`。
2. `limit >= text.size`：旧实现不触发 `break`，输出 = 逐 rune append 全串 = `text`；
   新实现直接返回 `text`。
3. 其它：两者都用 `text` 的 rune 序列，按同一宽度函数（边界 `0x80 / 0x800 / 0x10000`）
   累加 `used`，在同一条件 `used + size > limit` 处停止，按同一顺序 append。
   只要 `runes()` 与 `toRuneArray()` 产生相同的 rune 序列（同一解码器），输出必然逐字节相同。

唯一的实现差异风险是 `runes()` 的解码策略；两者都按 UTF-8 解码同一 `String`，测试用
ASCII / 2 / 3 / 4 字节混排语料覆盖。

**非法 UTF-8 输入**：`String` 理论上可由 `unsafe` 接口构造出非法字节，`toRuneArray` 与
`runes` 对替换字符的处理一致，但字节宽度可能与原始字节不同。这是既有行为的一部分，
本变更不改变、也不承诺（`Out of Scope`）。

### 4.5 兼容性

- 签名 `static func truncateUtf8(text: String, limit: Int64): String` 不变；
- 不新增 public 类型 / 方法 / 配置；
- `truncated()` 与 `applyLargeResult` 不需要改；
- 输出与现状逐字节一致，`data.truncated` / `data.limit` 语义不动。

## 5. 测试设计

新增 `f_mcp/src/server/TruncateUtf8_test.cj`（包 `fountain::f_mcp.server`）。

### 5.1 oracle：测试内保留旧算法

```cangjie
static func referenceTruncate(text: String, limit: Int64): String {
    // 与改造前 McpServer.truncateUtf8 完全同构：toRuneArray + StringBuilder()
}
```

放在测试里而不是生产代码里：它只服务于等价性证明，不参与运行期；实现删干净后，
oracle 仍然固化「旧行为」这份契约。

### 5.2 用例清单

| 用例 | 断言 |
| --- | --- |
| `equivalenceAcrossCorpus` | 语料 × `limit ∈ {0,1,2,3,4,5,7,11,size-2,size-1,size,size+1}` → 与 oracle 逐字节相同 |
| `equivalenceOnLargeText` | 1 MiB ASCII / 中文 / emoji，`limit ∈ {3,4,5,size/2,size-1}` → 与 oracle 相同且 `cut.size <= limit` |
| `fastPathDoesNotCopy` | `limit == text.size` 与 `limit > text.size` → 内容相同、分配量 `< text.size / 16` |
| `stopsAtFirstNonFittingRune` | 文本 = 「前缀能填满 limit」+「1 MiB 尾巴」→ 结果只含前缀，不含尾巴任何内容 |
| `zeroAndNegativeLimit` | `limit = 0, -1` → `''`（与 oracle 一致） |
| `keepsRuneBoundaryForMixedScript` | 混合串在 `limit` 落在各宽度字符中间 → 结果可按 UTF-8 往返 |

语料包含：纯 ASCII、`中`（3B）、`é`（2B）、`😀`（4B）、四者交替、以及长度恰好等于
各宽度整数倍的串，保证 `limit` 落在每个偏移上都有覆盖。

### 5.3 1 MiB 基准（`F_MCP_BENCH=1` 门控）

沿用 `f_protocol/src/default/FrameEncodeBench_test.cj` 的门控与分配测量写法：

- 未设 `F_MCP_BENCH=1` 时打印 `SKIP:` 并返回，常规 `cjpm test` 不受影响；
- 输入：1 MiB ASCII（`'a' × 1_048_576`）与约 1 MiB 中文（`'中' × 349_525`），
  `limit = 256 KiB`；
- 测量：`gc(heavy: true)` + 等 GC 计数稳定（`settleGc`）→ 记录 `getAllocatedHeapSize()` 与
  `getGCFreedSize()` → 调一次 → 再记录；分配量按 `存活堆增量 + 期间释放量` 计算，
  5 个样本取中位数。
  （只读存活堆会在窗口内发生 GC 时低估：大对象分配本身会诱发 GC，`setGCThreshold` 对大对象无效；
  先 `settleGc` 清空既有垃圾后，窗口内的释放量只可能来自本次调用新产生的对象。）
- 输出一行：
  `TRUNCATE_BENCH case=ascii bytes=... limit=... newAlloc=... refAlloc=... newNs=... refNs=... samples=...`
- 断言（只在门控开启时）：
  - `newAlloc <= 2 * limit`；
  - ASCII 用例 `newAlloc * 2 < refAlloc`（旧路径 ≈ 4 × 1 MiB + 256 KiB）；
  - 两条路径结果逐字节相同。

中文用例的 `refAlloc` 约 1.4 × 文本 + 输出，倍数小，只打印不断言，避免脆弱的比例阈值。

## 6. 验收

| 项 | 标准 |
| --- | --- |
| 等价性 | `TruncateUtf8_test` 全部通过；`McpServer_test` 4 条既有截断用例一字不改、通过 |
| 分配 | 门控基准下 `newAlloc <= 2 × limit`；ASCII 对照 `newAlloc × 2 < refAlloc` |
| 回归 | `cd f_mcp && cjpm test` 全绿；`cjpm build` 不新增 WARNING |
| 契约 | `git diff` 中 `McpServer.cj` 只涉及 `truncateUtf8` 函数体；无 public 符号变化 |

## 7. 风险与回退

| 风险 | 处理 |
| --- | --- |
| `StringBuilder(capacity)` 签名 | 已确认 `init(capacity: Int64)`（std `string_builder.cj:82`）；无需 `reserve` 退化 |
| `runes()` 每次创建迭代器 | O(1) 对象，远小于被消除的数组；基准会把它计入 `newAlloc` |
| 分配量测量受 GC 影响 | `settleGc` 清空既有垃圾，再按「存活堆增量 + `getGCFreedSize` 增量」计分配量（GC 不再导致低估）；只做上界断言 |
| `-O0` 测试构建下的耗时不可比 | 耗时只打印；门控基准不代表生产 `-O2` 数值，结论以分配量为准 |
| 非法 UTF-8 输入 | 明确不在范围内，行为与现状一致不承诺 |

**回退**：改动是单个函数体替换，`git revert` 该提交即可恢复；无数据/配置/协议影响。

## 8. 后续可选项（不在本变更）

- **UTF-8 字节直接切片**：`text.unsafeBytes()` + 从 `limit` 向前回退到字符起始字节，
  再 `String.fromUtf8(bytes[0..k])`。可省掉 rune 解码，但需处理非法字节与 `limit` 落在
  代理范围的情况；等有更硬的吞吐指标时再评估。
- **复用输出缓冲**：若截断成为高频热路径，可把 `StringBuilder` 挂在调用方（`McpServer` 实例字段）
  复用容量；当前截断是小概率降级路径，不值得引入共享可变状态。

## 9. 落地顺序

1. 确认 `StringBuilder` 容量 API 与 `String.size` / `runes()` 语义（文档 + 编译探针）；
2. 写入 oracle 与等价性用例（Red：`fastPathDoesNotCopy` 在现实现下失败）；
3. 替换 `truncateUtf8` 实现（Green）；
4. 加门控基准，跑一次并把输出写入本文 §10 的实测记录；
5. `cd f_mcp && cjpm test` 全绿后独立提交。

## 10. 实测记录

> 落地后补：`TRUNCATE_BENCH` 输出、机器与构建参数（`-O0` 测试构建 / `-O2` 参考）。

### 10.1 改造前基线（临时探针，未入库）

`-O0` 测试构建，`limit = 256 KiB`，5 个有效样本取中位数（窗口内 GC 计数不变）：

```
BASELINE case=ascii   bytes=1048576 limit=262144 alloc=13692960 ns=56607691 samples=5
BASELINE case=chinese bytes=1048575 limit=262144 alloc=5288032  ns=32110489 samples=5
```

ASCII 额外分配约为文本字节的 13 倍（`toRuneArray` 的全量数组 + 几何扩容历史缓冲），
中文约 5 倍。绝对耗时只作参照（`-O0` 且非生产构建），结论以分配量为准。

### 10.2 改造后基准（`F_MCP_BENCH=1`）

`-O0` 测试构建（`cjpm test` 默认），`limit = 262 144`（256 KiB），5 个有效样本取中位数：

```
TRUNCATE_BENCH case=ascii   bytes=1048576 limit=262144 newAlloc=266344 refAlloc=13675048 newNs=14918444 refNs=48476271 samples=5/5
TRUNCATE_BENCH case=chinese bytes=1048575 limit=262144 newAlloc=266344 refAlloc=5296912  newNs=10422974 refNs=27925793 samples=5/5
```

| 用例 | 新路径分配 | 旧路径分配 | 倍数 | 新/旧耗时（`-O0`） |
| --- | --- | --- | --- | --- |
| ASCII 1 MiB | 266 344 B（≈ limit） | 13 675 048 B | **51.3×** | 14.9 ms / 48.5 ms |
| 中文 1 MiB | 266 344 B（≈ limit） | 5 296 912 B | **19.9×** | 10.4 ms / 27.9 ms |

结论与设计一致：额外内存从「与输入文本同阶（1–13×）」降到「与输出同阶（≈ limit）」，
且耗时同步下降。断言 `newAlloc <= 2 × limit` 与 ASCII `newAlloc × 2 < refAlloc` 均成立。
（耗时是 `-O0` 数值，仅作参照；生产 `-O2` 下分配量结论不变。）
