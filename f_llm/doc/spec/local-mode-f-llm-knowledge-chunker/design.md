## Context

`f_llm` 的知识写入链路是 `knowledge.upsert` → `KnowledgeChunker.split` → 逐块编码 → `llm_document_chunk`（`f_llm/doc/f_llm-memory-design.md` §3.1）。切块是纯函数，输入整篇文档，输出 `ArrayList<String>`。

现状（`f_llm/src/store/KnowledgeChunker.cj:33-68`）：

- `split` 先校验 `maxChars` / `overlap`，空内容直接返回；
- `:45-48` 把整篇文档展开成 `ArrayList<Rune>`；
- `:49` 用 `runes.size` 作为 `total`；
- `:51-66` 按 `maxChars` / `overlap` 滑窗，每个窗口用 `StringBuilder` 拼 `String`，非空才加入 `chunks`（`:40`）。

全文 `ArrayList<Rune>` 是本次唯一目标：它在 `split` 内创建、循环内只读、函数返回后不再引用，不逃逸。`chunks` 是返回值；chunk `String` 与 `StringBuilder` 跨函数边界，必须留在堆。

依据：

- `docs/LocalMode.md` §2.5 把 `f_llm KnowledgeChunker.split` 的全文 `ArrayList<Rune>` 列为 `@ local!`，内部 helper 参数 `@ local?`；§3.1 明确 `Rune` 是 `Copyable`，`ArrayList<Rune> @ local!` 是干净候选，`chunks` 保持普通。
- §1.9：所有线程活跃 local region 合计默认上限 256 MB，超限抛 `LocalRegionOutOfMemoryError`；因此需要门限。
- §2.2：只改模块 `[package].compile-option`，不改 `override-compile-option`；`f_base` / `f_data` / `f_svg` 已按此先例开启。
- §4.1：按 peak RSS、`getAllocatedHeapSize()`、`getAllocatedLocalObjectSize()` 验收，不以吞吐量证明收益。
- `f_svg` 的 `local-mode-f-svg-analytic-coverage` 已验证「单一实现 + `useLocal` 档位开关 + 门限」模式；本次沿用，但对象换成 `ArrayList<Rune>`，且 `@ local?` ArrayList 的读取支持需要在 apply 首步探针确认。

已核对的契约：

- `split` 是 `public static`，签名与默认值是公开面；`splitImpl` / predicate / 常量用 `internal`。
- 既有测试 `KnowledgeChunker_test.cj:25-85` 直接调用 `KnowledgeChunker.split`，同包测试可访问 `internal` 符号。
- `f_llm/cjpm.toml:9-10` 当前 `compile-option = "--dy-std"`、`override-compile-option = "--dy-std"`；`f_base/cjpm.toml:3-4` 是 local mode 先例。
- 2026-11-21 实测基线：`cd f_llm && cjpm test` 668 条，659 通过、9 条 ERROR；9 条全部是 `LoomMemoryE2E_test` / `LoomStoreGateway_test` / `SkillEvolutionJob_test` / `StoreFunctions_test` 访问未启动的 BgeM3 服务（`SocketException: Connection refused`），与 `KnowledgeChunker` 无关。后续回归以「无新增错误」为门禁。

## Goals / Non-Goals

**Goals:**

- 把全文 `ArrayList<Rune>` 从 GC 堆移到 local region，降低知识切块的峰值内存；`split` 返回时整块释放。
- 用 8 MiB local 预算 / 2 MiB 内容字节门限把单次 local 占用限制在 256 MB 合计上限的 1/32，给并发留余量。
- 保持输出逐元素一致、公开 API 与调用点不变、`f_llm` 自身 0 warning。
- 留下可测试的 `useLocal` 档位开关，使 local / 堆两条路径都能被单测直接覆盖。

**Non-Goals:**

- 不 local 化 `chunks` / `StringBuilder` / chunk `String`。
- 不改切块算法、参数语义、异常类型，不做 UTF-8 字节扫描的结构性重写。
- 不实现 `LocalRegionOutOfMemoryError` 的运行时回退。
- 不以吞吐量作为验收指标；不改变既有 `start + maxChars` 的极端溢出行为。
- 不解决 ohos 的 local mode 不支持问题。

## Decisions

### D1 门限按内容字节、由 8 MiB 预算推导、只用比较不展开 rune

```cangjie
/** 单次全文 rune 缓冲允许进入 local 分配的预算（字节）。 */
internal let KNOWLEDGE_CHUNKER_LOCAL_BUDGET_BYTES: Int64 = 8 * 1024 * 1024
/** `Rune` 的元素宽度（字节）。 */
internal let KNOWLEDGE_CHUNKER_RUNE_BYTES: Int64 = 4
/** 对应最坏情况 ASCII 的内容字节上限（8 MiB / 4）。 */
internal let KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES: Int64 =
    KNOWLEDGE_CHUNKER_LOCAL_BUDGET_BYTES / KNOWLEDGE_CHUNKER_RUNE_BYTES

internal func knowledgeChunkerUsesLocalBytes(contentBytes: Int64): Bool {
    contentBytes > 0 && contentBytes <= KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES
}

internal func knowledgeChunkerUsesLocal(content: String): Bool {
    knowledgeChunkerUsesLocalBytes(content.size)
}
```

- 8 MiB = 8,388,608 字节；除以 4 得 2,097,152 字节（2 MiB）。2 MiB ASCII 恰好 2,097,152 个 rune，原始元素占用 8 MiB。
- `Rune` 是 `Copyable` 值，SDK 下按 4 字节计（`docs/LocalMode.md` 的「约 4 倍文本字节」）；apply 首步用 `getAllocatedLocalObjectSize()` 校准，若实际宽度不是 4，同步改 `KNOWLEDGE_CHUNKER_RUNE_BYTES` 与门限。
- 中文（3 字节/字符）在 2 MiB 内容时 rune 缓冲约 2.67 MiB；emoji（4 字节/字符）约 2 MiB；都低于预算。最坏情况是 ASCII，因此按 ASCII 推导。
- 只读 `content.size`，不做 `content.size * 4` 或 `runeCount * 4` 的乘法，避免极端长度溢出；`content.size` 本身非负，空内容由 `> 0` 排除。
- **0.1 探针实测（2026-11-21，SDK `1.3.0-alpha.20261118001016`）**：`ArrayList<Rune>(n) @ local!` 的 `getAllocatedLocalObjectSize()` 增量为 `4n + 4112` 字节；2,097,152 个 rune 实测 8,392,720 字节（8 MiB + 4,112 字节头/对齐开销）。超出预算 4 KB（0.05%），不属于「明显超过」，本轮维持 2 MiB 门限，并在 `perf-baseline.md` 记录该常数开销。`Rune` 宽度确认为 4 字节。
- 为什么不把门限写成「8 MiB 内容」：`ArrayList<Rune>` 是 4 倍放大，8 MiB 内容会对应约 32 MiB local，直接超过预算，也会让 256 MB 合计上限只够 8 个并发。
- 为什么不按 rune 数判定：需要先完整展开 rune 才能知道数量；本试点先用内容字节这个廉价上界，精确 rune 数只用于容量。若后续实测希望放宽中文门限，可在 D3 的 `countRunes` 后改用 `total <= BUDGET / 4`，但不作为本轮默认。
- 为什么拆出 `knowledgeChunkerUsesLocalBytes`：门限边界用例可以直接用字节数断言（0、1、2 MiB-1、2 MiB、2 MiB+1、`Int64.Max`），不必在单测里构造 2 MiB 字符串。

### D2 单一实现 + `useLocal` 开关 + `@ local?` rune 缓冲

公开 `split` 只做校验与档位选择；`splitImpl` 同时服务生产与 A/B：

```cangjie
public static func split(content: String, maxChars!: Int64 = DEFAULT_MAX_CHARS, overlap!: Int64 = DEFAULT_OVERLAP): ArrayList<String> {
    if (maxChars <= 0) {
        throw IllegalArgumentException('maxChars must be positive, got ${maxChars}')
    }
    if (overlap < 0 || overlap >= maxChars) {
        throw IllegalArgumentException('overlap must be in [0, maxChars), got ${overlap} (maxChars=${maxChars})')
    }
    splitImpl(content, maxChars, overlap, knowledgeChunkerUsesLocal(content))
}

internal static func splitImpl(content: String, maxChars: Int64, overlap: Int64, useLocal: Bool): ArrayList<String> {
    let chunks = ArrayList<String>()
    if (content.isEmpty()) {
        return chunks
    }
    let total = countRunes(content)
    if (useLocal) {
        let runes = ArrayList<Rune>(total) @ local!
        for (rune in content.runes()) {
            runes.add(rune)
        }
        appendChunksLocal(runes, total, maxChars, overlap, chunks)
    } else {
        let runes = ArrayList<Rune>(total)
        for (rune in content.runes()) {
            runes.add(rune)
        }
        appendChunksHeap(runes, total, maxChars, overlap, chunks)
    }
    chunks
}

private static func appendChunksLocal(
    runes: ArrayList<Rune> @ local!,
    total: Int64,
    maxChars: Int64,
    overlap: Int64,
    chunks: ArrayList<String>
): Unit {
    // 与 appendChunksHeap 相同的窗口循环，见下文「为什么两档分开」
}

private static func appendChunksHeap(
    runes: ArrayList<Rune>,
    total: Int64,
    maxChars: Int64,
    overlap: Int64,
    chunks: ArrayList<String>
): Unit {
    // 普通堆列表的窗口循环
}
```

- `@ ~local` 与 `@ local!` 都是 `@ local?` 的子类型；`if` 表达式两支分别返回堆列表与 local 列表时可以归一到 `@ local?`（0.1 探针已确认）。
- 因为 `ArrayList<T> @ local?` 没有 `add` / 下标赋值重载（`docs/LocalMode.md` §3.1、`f_svg` D3），填充必须在各自的 `@ local!` / 堆分支内完成。
- **为什么两档分开（2026-11-21 二轮探针）**：`-O0`（`cjpm test` 默认）构建下，从带 mode 的 `ArrayList` 读元素（`@ local!` 或 `@ local?`，无论列表实际在 local 还是堆）会为**每次访问**在当前 local region 留下 32 字节临时对象，直到函数返回才释放；`-O2` 下为 0。若两档共用 `@ local?` 变量，8 MiB 内容的 8.4M 次读会累积约 268 MB local，超过 256 MB 默认上限并抛 `LocalRegionOutOfMemoryError`——即堆路径在未优化构建下也会碰 local。分开后堆路径使用普通 `ArrayList<Rune>`，任何构建档位都不再访问 local region；local 路径的读开销在 2 MiB 门限下约 67 MB，仍低于上限（生产 `-O2` 为 0）。
- 两段窗口循环的重复是这份工具链行为的直接代价，注释互相指向；窗口 / 重叠语义只有一处数字来源（`maxChars`、`overlap`、`total`）。
- `appendChunksLocal` 声明为 `private static exclave func`：普通函数不能直接读外部 `@ local!` 元素的 `operator[]`（编译器报 `cannot pass argument of external @local! to @local! this parameter`）；`exclave` 让读操作留在 `splitImpl` 的 region，与 `f_svg` 的 `sortAnalyticLocalValues` 同型。
- 不把填充抽成公共 `fill`：`@ local?` 形参无法调用 `add`，抽出来只能拆成 local / 堆两个 helper，填充逻辑反而分叉。
- 不需要 `exclave`：local 列表在 `splitImpl` 自己的 local region 内创建，随后在同一函数内只读；没有把 local 值返回给调用者。
- `total` 来自 `countRunes`，同时用于构造容量与窗口边界，保证两者使用同一个数字。
- `splitImpl` 的 `useLocal` 是显式档位：生产路径由 `split` 的门限保证不超 8 MiB；测试 / 基准可以对小内容强制任一档位，但调用方不得在超门限内容上强制 local。
- `chunks` 与 `StringBuilder` 不写 mode，保持普通堆分配；chunk `String` 由 `builder.toString()` 产生，随后进入返回值。
- 备选「先分配堆列表再覆盖为 local 列表」会让峰值目标失效，否决。
- 备选「单一 `@ local?` 循环」在 `-O2` 下成立，但在 `-O0` 下堆路径会耗尽 local，违反「超过门限不占用 local」的约定，否决。

### D3 精确容量：先数 rune，再构造，避免扩容顶破预算

`ArrayList` 默认按增长因子扩容；2 MiB ASCII 的 2,097,152 个 `Rune` 若按默认增长，底层数组可能超过 8 MiB。因此在构造前数一遍：

```cangjie
private static func countRunes(content: String): Int64 {
    var count: Int64 = 0
    for (_ in content.runes()) {
        count += 1
    }
    count
}
```

- `countRunes` 只读字符串、不分配；多一次 O(n) 扫描，换取精确容量与可验证的 8 MiB 上界。项目约定不以吞吐量作为本轮验收，故接受这次扫描。
- `ArrayList<Rune>(total) @ local!` / `ArrayList<Rune>(total)` 是否都有容量构造重载，由 0.1 探针确认；`f_collection/src/BitSet.cj:39` 已有 `ArrayList<UInt64>(capacity)` 的普通用法。
- **0.1 探针实测**：`ArrayList<Rune>(total) @ local!` 与普通堆容量构造都可用；填充后 `capacity == total`，未触发扩容，按精确容量构造即可给出 `4n + 4,112` 的可预测上界。
- 若容量构造不支持 `@ local!`：退回 `ArrayList<Rune>() @ local!` + 默认增长，并把内容门限下调到 **1 MiB**（为增长预留约 2 倍余量），同步改 D1、spec 与边界用例；这是 0.1 失败后的降级方案。
- 若 `runes().count()` 可用，可替代手写循环；`countRunes` 保留为可读的单一入口。
- `total` 同时用于 `end = minOf(total, start + maxChars)`，不改变窗口语义。

### D4 只改 `[package].compile-option`，公开面与调用点不动

`f_llm/cjpm.toml` 只改：

```toml
compile-option = "--dy-std --experimental --enable-local-mode"
```

- `override-compile-option = "--dy-std"` 与所有 `[target.*]` 段保持原样，和 `f_base` / `f_data` / `f_svg` 的已验证形态一致。
- `KnowledgeChunker.split` 的签名、默认值、异常与返回类型不变；`knowledge.upsert` 等调用点无需改动，调用方也不需要开启 local mode。
- `splitImpl`、`knowledgeChunkerUsesLocal*`、门限常量全部 `internal`；`git diff` 中 `public` 声明应为 0 处新增/修改。
- 评审约束（2026-11-21）：**不修改任何 `public` 声明**；`KnowledgeChunker.split` 的签名、默认值、参数校验、异常类型与返回类型逐字保持，新增符号全部 `internal` / `private`。
- 不新增生产文件（除本文件改动），不新增依赖。
- 风险是 `f_llm` 体量远大于 `f_svg`：开启 local mode 后，既有代码可能因 std 模态重载、重复父接口或 `exclave` 标识符报错。第 1 组任务先只加开关跑 `cjpm build`，把这类兼容修复单独处理；若修复需要改公开 API 或大规模业务逻辑，暂停并回报，不把本试点扩大成全模块重构。

### D5 OOM 回退留接口、不在本次落地

- 2 MiB 内容门限对应单次最多约 8 MiB local；默认 256 MB 合计上限允许约 32 个并发切块。超过时需调大 `cjLocalRegionMaxSize` 或降低单次内容。
- 本次不写 `try { ... } catch (e: LocalRegionOutOfMemoryError) { ... }`：错误类型能否在 local region 耗尽后安全捕获、失败后当前 region 是否可复用，都还没有实测结论。
- 预留落点是 `splitImpl` 的 `useLocal` 参数：后续若确认可捕获，只需在 `split` 的门限分支外包一层 try/catch，catch 内以 `useLocal = false` 重跑 `splitImpl`；切块逻辑不变。
- 注意 `chunks` / `StringBuilder` 本来就在堆，回退不需要改它们；这也是本次只 local 化 rune 缓冲的一个好处。

### D6 不 local 化返回值与拼装器

- `chunks` 是 `ArrayList<String>` 返回值，必须逃逸；local 值不能作为 `@ ~local` 返回。
- chunk `String` 进入 `chunks`，同样逃逸。
- `StringBuilder` 的 local 支持在 `docs/LocalMode.md` 未确认（附录 A P5），且 `toString()` 的结果要逃逸；把它 local 化没有收益，还会引入未验证的 API 风险。
- 更彻底的结构性优化是「不建 rune 数组，直接按 UTF-8 字节边界扫描」；它比 local 化更省内存，但会重写切块算法，属于后续独立变更。

## Risks / Trade-offs

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 256 MB 全线程合计上限 | 并发大文档抛 `LocalRegionOutOfMemoryError` | 2 MiB 内容门限（单次 ≤ 8 MiB）；`useLocal` 预留回退；文档说明 `cjLocalRegionMaxSize` |
| `ArrayList` 扩容 | 默认增长可能把局部占用推过 8 MiB | 先 `countRunes` 再按精确容量构造（D3）；探针失败则门限降到 1 MiB |
| `@ local?` ArrayList 读取不确定 | 切块循环无法读 `runes[index]` | 0.1 探针优先验证；失败则 local 分支在 `@ local!` 作用域内切块、堆分支独立入口（D2） |
| 模块级 local mode 编译波及 | f_llm 既有代码可能因模态重载 / 重复父接口报错 | 第 1 组任务先只加开关跑 `cjpm build`；最小修复；需要改公开 API 时暂停回报 |
| 多一次 rune 扫描 | 吞吐略降 | 本轮不以吞吐为验收；`countRunes` 只读不分配；若后续在意，可改用 `runes().count()` 或接受默认容量并降门限 |
| local 释放时机是函数返回 | rune 缓冲贯穿整个切块循环，峰值下降受限于函数时长 | 切块函数短，返回即释放；只 local 化真正不逃逸的缓冲，不动 chunks |
| 小内容负收益 | local 记账成本可能高于收益 | 验收只看峰值内存，不看吞吐；小内容本来占用就小，不放大 |
| 实验特性 / 工具链 | cjfmt / cjlint / LSP 不保证识别模态 | 改动集中在单个文件；跑 `cjpm build` + `cjpm test`；必要时手工格式化 |
| 产物不跨 SDK 兼容 | `f_llm` 需同 SDK 重编译 | 与 `f_base` / `f_data` / `f_svg` 一致，随 SDK 版本发布 |
| ohos 不支持 local mode | ohos 目标无法编译 | 本分支 `f_base` 已因同一开关在 ohos 失败；f_llm 与既有基线一致，本次不额外处理 |
| 门限判断写错 | 大文档误入 local 顶爆上限 | 字节 predicate 覆盖 0、1、2 MiB-1、2 MiB、2 MiB+1、`Int64.Max`；字符串 wrapper 覆盖空 / 非空 |
| `Rune` 宽度假设 | 若实际不是 4 字节，预算换算错误 | 0.1 用 `getAllocatedLocalObjectSize()` 校准；常量集中在一处，改一处即可 |

## Testing Strategy

- **TDD**：先写 `KnowledgeChunkerLocalMode_test.cj`（RED：常量 / predicate / `splitImpl` 不存在，编译失败），再实现到 GREEN。
- **门限用例**：`knowledgeChunkerUsesLocalBytes` 覆盖 0、1、2,097,151、2,097,152、2,097,153、`Int64.Max`；`knowledgeChunkerUsesLocal` 覆盖空串与小串；断言 `KNOWLEDGE_CHUNKER_LOCAL_BUDGET_BYTES == 8 * 1024 * 1024`、`KNOWLEDGE_CHUNKER_RUNE_BYTES == 4`、`KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES == 2,097,152`。不构造 2 MiB 字符串做边界断言。
- **等价性用例**：ASCII、中文、emoji、混合内容，`maxChars` 取 1 / 2 / 4 / 400、`overlap` 取 0 / 1 / 50（合法组合），分别用 `splitImpl(..., true)` 与 `false` 计算，断言长度与每个 chunk 相等；覆盖「内容长度恰好等于 maxChars」「单 rune」「overlap=0」。
- **公开 API 回归**：`split` 与 `splitImpl(..., false)` 对门限以下内容逐元素一致；既有 `KnowledgeChunkerTest` 的 5 条切块用例与 3 条知识检索用例全部保持通过。
- **全量回归**：`cd f_llm && cjpm test` 无新增错误（2026-11-21 基线 668 条：659 通过、9 条外部 BgeM3 服务连接错误）；`cjpm test --filter '*KnowledgeChunkerLocalModeTest*'` 单独通过。
- **内存口径**：按 `docs/LocalMode.md` §4.1，用 `-O2`、固定输入记录 peak RSS 与 `getAllocatedLocalObjectSize()` / `getAllocatedHeapSize()`；只在基准进程里调用后者。结果写入 `f_llm/doc/perf-baseline.md`，作为参考值、不作 CI 门禁。
- **基准输入**：门限边界 ASCII（2 MiB 走 local、2 MiB+1 走堆）与中文（699,050 个汉字走 local、699,051 个汉字即 2 MiB+1 走堆），另加 8 MiB ASCII 堆路径；默认 `maxChars=400`、`overlap=50`。两次输入只差极小的字节数，用于隔离门限档位；严格同输入的 A/B 由单测的 `splitImpl(..., true/false)` 覆盖。
- **命令**：`cd f_llm && cjpm build`、`cd f_llm && cjpm test`、`cjpm test --filter '*KnowledgeChunkerLocalModeTest*'`。
