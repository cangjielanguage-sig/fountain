# local mode 在 -O2 前提下的重评估与实施方案

> 评审稿，2026-11-26。前提：应用项目统一用 `-O2` 编译，并通过 `override-compile-option` 透传到所有依赖。
> 环境：Linux aarch64 / Cangjie SDK `1.3.0-alpha.20261118001016`。

## 1. 前提验证

### 1.1 `override-compile-option` 的语义（实测确认）

构造 `app → lib` 两级依赖，`lib` 的 `compile-option = "--experimental --enable-local-mode -O0"`，
`app` 的 `override-compile-option = "-O2"`。`cjpm build -V` 打印的依赖编译命令是：

```
cjc -p .../lib/src ... --experimental --enable-local-mode -O0 -O2 --output-type=staticlib
```

结论三条：

1. **追加，不是替换**。依赖自己的 `compile-option` 保留在前，应用侧的 `override-compile-option` 追加在后。
2. **冲突时后者胜出**。`-O0 -O2` 最终按 `-O2` 编译。
3. **不会替依赖补选项**。把 `lib` 的 local mode 删掉后，`app` 的 `-O2` 救不回来（`error: local mode is disabled`）。

因此用户假设成立：**模块只需在自己 `compile-option` 里开 local mode，不必写 `-O2`；应用侧统一 `-O2` 会覆盖掉模块里的 `-O0`，且不丢 local mode / `--enable-eh` / `--debug-macro`。**

### 1.2 `-O2` 下 local 的耗时特征（微基准，3 次取最小）

`Array<Float64>`，`repeat` 初始化 + 全量读（读密集）：

| 分配字节 | 堆 µs | local µs | 结论 |
|---|---|---|---|
| 8 KB | 4–5 | 2 | local 快 2–2.5× |
| 64 KB | 39–46 | 15–17 | **local 快 2.6–3×（甜点）** |
| 256 KB | 155–191 | 167–169 | 持平 |
| 2 MB | 599–716 | 1332–1433 | **local 慢 2.0–2.2×** |
| 8 MB | 2547–3124 | 5723–7271 | **local 慢 2.2–2.5×** |

`Array<UInt8>`，循环内每轮新建（全量写 + 全量读）：

| 块大小 × 轮次 | 堆 | local | 循环内复用 |
|---|---|---|---|
| 1 KB × 4000 | 5747–5893 | 5902–5968 | **5081–5092** |
| 8 KB × 1000 | 11034–11332 | 11401–11470 | **9982–10157** |
| 32 KB × 500 | 22435–22656 | 22172–23571 | **19970–20089** |
| 256 KB × 64 | 22651–22733 | 29425–30963 | **20532–20694** |
| 1 MB × 32 | 44683–49650 | 58752–59760 | **41785–41991** |

结论：

1. **甜点区约 8–64 KB**，local 比堆快 2–3×；256 KB 起持平，≥2 MB 反而慢 2×。
2. **循环内新建 local 没有优势**：1–32 KB 与堆持平，256 KB 起慢 1.3×。
3. **循环内复用始终最快**，比堆快 10–12%，比 local 快 10–30%。
4. local 的价值不是「更快」，而是**把临时区从 GC 堆挪走**；大块 local 省堆但要付 2× 耗时。

> 与旧结论的差异：`docs/LocalMode.md` 早前记录「-O2 下 once ≥32 KB 时 local 快 1.3×」。
> 本次用独立进程、全量读写、3 次取最小重测，方向相反。旧数据来自不同形态（Float64 + 只写/不同循环结构），
> 不足以推广。以本节数据为准。

### 1.3 编译器风险

`-O2` 下把 `@ local!` 数组传给 `@ local?` 形参并在形参上做常量写循环，触发编译器 ICE：

```
terminate called after throwing an instance of 'std::out_of_range'
what():  _Map_base::at
Internal Compiler Error: Interrupt signal (6) received. Error Code: 13
```

同样的写循环在 `f_svg` 现有写法（读改写、变量下标）下可以编译。**每个 local 化点都必须单独编译验证，不能按模板批量套用。**

## 2. 总体结论

在 -O2 前提下，local mode 的适用面**没有扩大，反而收窄**：

- 唯一有速度优势的区间是 8–64 KB，而这个区间恰好也是「复用一块缓冲」成本最低、收益最高的区间；复用是 0 分配，仍然优于 local。
- ≥1 MB 的 local 稳定慢 2×。fountain 里需要大块临时区的地方（f_svg 累加器、f_llm rune 缓冲、f_mcp truncate、f_excel 包缓冲）都属于这一类。
- 因此策略不变：**结构性复用优先；local 只用于「无法复用、一次性、8–64 KB、不逃逸」的点。**

按这条线重新过全仓，**没有新增的 local 化点**。已有三处 local 实践中，一处需要收敛。

## 3. 分模块方案

### 3.1 A 类：保持现有 local（3 个模块）

| 模块 | 现实现 | -O2 下判断 | 动作 |
|---|---|---|---|
| **f_base / f_data** | `LocalEquatable` / `LocalComparable` 接口 + `@DataAssist` 生成 `localEq`/`localCompare` | 编译前置，不是性能优化 | 保持。任何使用 `@DataAssist[equal/compare]` 的模块必须开 local mode |
| **f_svg** | `SvgAnalyticRasterizer` 累加器 8 MiB 门限，超出走堆 | 8 MB 在「慢 2×」区间，但耗时主体是渲染不是分配；实测 1024² 整体耗时 115–129 ms vs 堆 128–147 ms，堆峰值 −16~−25 MB | 保持 8 MiB 门限。收益记在「GC 堆峰值」，不承诺吞吐 |

### 3.2 B 类：需要收敛（1 个模块）

| 模块 | 问题 | 数据 | 建议 |
|---|---|---|---|
| **f_llm** `KnowledgeChunker` | `ArrayList<Rune> @ local!`，2 MiB 内容 → 8.39 MB local | 实测 local 50 ms vs 堆 37–39 ms（**+30%**）；local 峰值 8,392,720 B | 两个选项见下 |

f_llm 的取舍：

- **选项 1（推荐）：门限从 2 MiB 降到 256 KB**。256 KB 内容约 65,536 rune，local 约 1.05 MB，落在甜点边缘；超过走堆。代价是大文档不再省那 19.4 MB 堆增量。
- **选项 2：保留 2 MiB 门限**，接受 +30% 耗时，换取 GC 堆增量从 +19.4 MB 降到 ≤0。只在「大文档切块是峰值瓶颈」时才成立。

需要重测 256 KB / 512 KB / 1 MiB / 2 MiB 四档的耗时与堆增量后再定。

### 3.3 C 类：结构性复用（收益来源，优先级最高）

这些点都在 8–64 KB 甜点区，但**复用优于 local**：

| 模块 | 位置 | 现状 | 动作 |
|---|---|---|---|
| **f_store** | `SSTable.cj:308/330` `Array<Byte>(blockSize)`、`:160` `Array<Byte>(recordLen)` | 每次读/写分配，`blockSize` 常为 4–64 KB | 复用读/写缓冲（`getLock`/写路径已串行化）；不做 local，因为耗时主体是 `pread`/`write` |
| **f_httpclient** | `SseReader.readLine` 每行 `ArrayList<Byte>` + `toArray()` | 行上限 1 MB，双份分配 | 字段缓冲 + `String.fromUtf8(buf, 0, n)` |
| **f_jsonrpc** | `readCapped` 8 KB 读缓冲 | 每次请求一块 | 复用 |
| **f_rule** | `AlphaMemory.range/select` 每次 `ArrayList<FactHandle>` + `toArray()` | 结果逃逸 | 改成调用方传 buffer（`probeList` 已是此形态） |
| **f_egraph** | `QueuedClosureTask.takeBatchLocked` 整队列 `toArray()` 快照 | 双份 | 迭代/复用，不做 local |
| **f_cache** | `HeapCache` 淘汰扫描每轮 `Array<Iterator>` + `HashMap` | 段数固定 | 字段复用 |
| **f_mcp** | `McpServer.cj:1140` `truncateUtf8` 用 `toRuneArray()` 放大 4× | 1 MB 文本 → 百万 Rune | UTF-8 字节边界切片 |
| **f_log** | `Logger.cj:47-51` 每条日志重新 `TextTemplate.compile` | 编译开销 | 缓存已编译模板 |
| **f_security** | `JWTSecurityContext.checkAndGet:67` 同一 JWT 解析两次 | 重复计算 | 把 verifier 结果传下去 |
| **f_email** | `MimeWriter.cj:181` Base64 成 String 再 `toArray()` | 3–4× 原文 | 走流式 encoder（部分已在 `reuse-f-email-stream-buffers` 完成） |

### 3.4 D 类：明确不做 local（其余全部）

| 分组 | 模块 | 原因 |
|---|---|---|
| 已完成复用，无需 local | f_xml、f_email、f_dbd、f_zip、f_excel、f_hydra、f_http、f_data、f_mq | 复用后分配已为 0 或只剩逃逸结果 |
| 小对象（< 1 KB） | f_codec、f_protocol、f_http ContentDisposition、f_chart、f_time、f_bloom、f_util、f_version、f_random、f_exception | local 头 16 B + 记账，收益为负 |
| 逃逸 / 接口 / 泛型 / 线程 | f_io、f_orm、f_mvc、f_jit、f_tui、f_ticktock、f_net、f_rpc、f_a2a、f_mcp 主体、f_jsonrpc 主体、f_concurrent、f_collection、f_pool | this mode 锁死 / `toArray()` 不能返回 / `spawn` 不能捕获 / 泛型参数不能带 mode |
| FFI / native 堆 | f_crypto、f_zip 压缩主体、f_encoding 相关 | local region 管不到 native 堆 |
| 跨调用持有 | f_store 索引、f_cache 条目、f_config、f_security 上下文、f_bean、f_aspect、f_app、f_probe、f_process、f_uring、f_dbm、f_dbpool、f_jwt、f_rx、f_health、f_cmd、f_mockdb、f_macros | 生命周期超出函数 |

## 4. 实施顺序

1. **前置**：确认应用侧 `override-compile-option` 至少含 `-O2`；不含 `--enable-local-mode` 的依赖仍由模块自己的 `compile-option` 提供（已实测不会被覆盖）。
2. **P0**：f_llm 门限决策（选项 1 或 2），先补 256 KB–2 MiB 四档实测。
3. **P1**：C 类里收益确定的四项——f_mcp `truncateUtf8`、f_log 模板缓存、f_security 去重复解析、f_rule 传 buffer。
4. **P2**：C 类里的 I/O 缓冲复用——f_store、f_httpclient、f_jsonrpc、f_egraph、f_cache。
5. **不做**：D 类不立项；不为「统一风格」加 `@ local`。

每个变更仍按 OpenSpec 六步走（update → propose → 评审 → apply → verify → archive），纯性能重构且输出字节不变时 `skip_specs: true`。

## 5. 验收口径与风险

- **验收**：`-O2` 构建；同输入同进程对比「local / 强制堆」两档；记录 `getAllocatedHeapSize()`、`getAllocatedLocalObjectSize()`、peak RSS、耗时（参考值，非门禁）。逐元素等价由测试覆盖。
- **风险 1**：`cjLocalRegionMaxSize` 默认 256 MB 是**全线程活跃 region 合计**；并发大块 local 会 `LocalRegionOutOfMemoryError`。
- **风险 2**：`-O2` + local 在部分写循环形态触发编译器 ICE（见 1.3），每个点单独编译验证。
- **风险 3**：local 产物不保证跨 SDK 兼容；ohos 不支持 `--enable-local-mode`。
- **风险 4**：大块 local 省 GC 堆但慢 2×，必须按「峰值是否真的是瓶颈」逐点决策，不能按「用了 local mode」统一声称收益。
