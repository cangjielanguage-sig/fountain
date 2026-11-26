# 提案：`McpServer.truncateUtf8` 去全量 rune 数组（惰性扫描 + 快速路径 + 预算容量）

> **唯一入库副本**：`f_mcp/doc/spec/optimize-mcp-truncate-utf8/`。`openspec/changes/optimize-mcp-truncate-utf8/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份逐文件字节一致。
> 同步：以 `f_mcp/doc/spec/optimize-mcp-truncate-utf8/` 为准 `cp -a` 到
> `openspec/changes/optimize-mcp-truncate-utf8/`（本机无 rsync）。
> 校验：`diff -ru f_mcp/doc/spec/optimize-mcp-truncate-utf8 openspec/changes/optimize-mcp-truncate-utf8` 无输出。

## Why

1. **截断路径的额外内存是文本的 1–4 倍，且完全没必要**。
   `f_mcp/src/server/McpServer.cj:1146` 的 `for (r in text.toRuneArray())` 先把整串展开成
   `Array<Rune>`，再逐 rune 累加字节数。`Rune` 占 4 字节、数组还有对象头：纯 ASCII 的
   1 MiB 文本 → 1 048 576 个 Rune ≈ **4 MiB** 额外峰值；中文约 1.33 倍，emoji 约 1 倍。
   这些内存既不参与结果，也不跨调用复用，纯属一次性放大。

2. **它落在「大结果」路径上，正是峰值最敏感的地方**。
   `applyLargeResult`（`McpServer.cj:1095-1121`）已经把结果完整序列化成一份 JSON 字符串
   （默认 1 MiB 量级）；未配 `publicBaseUrl` 或 `ToolResultStore.put` 失败时进入
   `truncated()`（`1123-1134`）→ `truncateUtf8`。也就是说峰值 = 原字符串 + 全量 rune 数组 +
   输出缓冲，其中第二项是唯一可以无痛消除的。

3. **截断天然是流式的**：只需要从头扫到「第一个放不下的 rune」，后面的内容一个字都不用看。
   全量物化把「扫到即停」变成了「先读完整个字符串」。

4. **`StringBuilder` 不预留容量时会几何扩容**。输出上界在函数入口就已确定（`limit`，因为
   `limit < text.size` 才会走到扫描），按上界一次预留可省掉多轮扩容拷贝与临时数组。

5. **契约不能动**：截断结果是 `tools/call` 的可见内容，必须与现状**逐字节一致**——前缀、
   rune 边界、`<= limit` 三件事一个都不能变。`limit >= text.size` 时直接返回原串，
   语义上等价于「全部 rune 都能放下」，只是省掉一次完整复制。

6. **`docs/LocalMode.md` 已点名此处**（`317`、`436`、`1061` 行）：结论是「先做结构性优化
   （UTF-8 边界切片），local 只是次选」。本变更做结构性那一半；local 需要跨越
   `String`/返回值的 public 边界，不在本变更范围内。

## What Changes

范围仅 `f_mcp/src/server/McpServer.cj` 的 `truncateUtf8` 与新增测试文件。

### A. 惰性 rune 扫描（去掉 `toRuneArray()`）

- 改为 `for (r in text.runes())`：`String.runes()` 是惰性迭代器（仓库内已有大量同型用法，
  如 `f_llm/src/util/TextClip.cj:39`），不再产生全量 `Array<Rune>`。
- 逐 rune 的 UTF-8 宽度判定沿用现有分支链（`< 0x80` / `< 0x800` / `< 0x10000` / 其它），
  不改判定阈值，保证字节计数与旧实现完全一致。
- 一旦 `used + size > limit` 立即 `break`，不继续消费迭代器。

### B. 快速路径

- `limit <= 0` → `''`（保持不变）。
- `limit >= text.size` → 直接返回 `text`。`String.size` 是 UTF-8 字节数
  （`applyLargeResult` 用它和字节阈值 `json.size <= limit` 比较，语义已确认），
  因此该条件等价于「所有 rune 都放得下」，返回原串不改变任何可观察行为，且零复制。
- 该分支在生产路径上通常不可达（`truncated()` 只在 `json.size > limit` 时调用），
  但它让函数对任意调用方都是完整、零成本的定义，且既有用例
  `testTruncateUtf8KeepsRuneBoundary`（`McpServer_test.cj:828`）就依赖 `limit == size` 的语义。

### C. 输出缓冲按上界预留

- 进入扫描前已知 `0 < limit < text.size`，输出字节上界就是 `limit`；用
  `StringBuilder(capacity = limit)`（或文档确认的等价 API，见 `design.md` §7 风险）
  一次预留，不再依赖几何扩容。

### D. 测试：大文本 UTF-8 边界等价 + 1 MiB 基准

- 新增 `f_mcp/src/server/TruncateUtf8_test.cj`：
  - 测试内保留**旧算法**作为 oracle（`toRuneArray` 版），对多字节混合语料 × 边界 `limit`
    （`0/1/2/3/4/5/…/size-1/size/size+1/中间值`）逐字节比对；
  - 1 MiB 文本（ASCII / 中文 / emoji）在 `limit` 落在字符中间时结果 ≤ `limit` 且为合法前缀；
  - 快速路径的零复制证据：`limit >= text.size` 时分配量远小于 `text.size`；
  - `F_MCP_BENCH=1` 门控的 1 MiB 基准：打印新旧两条路径的分配字节与耗时，断言
    「新路径分配 ≤ 2 × limit」「ASCII 上旧路径分配 > 2 × 新路径」（分配量是确定性指标，
    耗时只打印不断言）。
- 既有 `McpServer_test.cj:823-857` 的 4 条截断用例**一条不改**，作为行为不变的硬约束。

### E. 契约

- `truncateUtf8(text: String, limit: Int64): String` 签名、访问级别、所在类型全部不变；
  不新增 public 类型 / 方法 / 配置项。

## Impact

- **修改代码**：`f_mcp/src/server/McpServer.cj`（`truncateUtf8`，约 25 行 → 约 25 行，逻辑替换）。
- **新增代码**：`f_mcp/src/server/TruncateUtf8_test.cj`（等价性 + 基准）。
- **公开 API**：0 处变更。无新公开符号；`truncateUtf8` 的调用点（`truncated()`）不改。
- **依赖 / 配置 / 路由**：不改。
- **行为**：对任意合法 UTF-8 输入，输出与现状逐字节相同；`limit <= 0`、`limit >= size`、
  中途截断三种情况语义不变。
- **内存**：截断路径的额外峰值从「1–4 × 文本字节」降到「≈ 输出字节（≤ limit）」。
- **风险**：`String.runes()` 每次调用会创建一个迭代器对象（O(1)）；`StringBuilder(capacity: Int64)` 已在 std `string_builder.cj:82` 确认存在，直接按 `limit` 预分配，无退化路径。

## Out of Scope

- **不做 UTF-8 字节直接切片**（`unsafeBytes` + 边界回退）。理论上比逐 rune 更省，但要手工处理
  边界与非法字节，收益相对本变更已很小；仅作为后续可选项记录在 `design.md` §3。
- **不做 local mode**：截断结果要逃逸回 `CallToolResult`，`String` 与 public 边界锁死。
- **不改 `applyLargeResult` / `truncated` / `ToolResultStore`**：本变更只换 `truncateUtf8` 的内部实现。
- **不改截断后的字段语义**（`data.truncated` / `limit`、`isError` / `resultType` /
  `inputRequired` / `requestState` 的保留规则）。
- **不引入耗时门禁**：测试机负载不可控，基准只输出数字与分配量断言。
