# Verification — optimize-f-xml-semantic-layer

> 采集时间：2026-10-30 21:20–21:30。机：`nproc = 7`，`uname -r = 6.6.0`，
> Cangjie SDK 1.3.0-alpha.20261023001052（`cjc-version = 1.2.0` 声明），交付档位 `-O2`。
> 运行时：**默认**（`env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'` 输出为空，用例内探测 `gc_env=[]`）。

## 1. 结果总览

| Gate | 标准 | 实测 | 判定 |
|---|---|---|---|
| **T**（时间） | 10 MB `min(5) < 1000 ms` | **497.0 ms** | ✅ |
| **T-对照** | `new_min ≤ 0.95 × old_min` | 497.0 / 1026.4 = **0.484** | ✅ |
| **M**（内存） | `VmHWM(50 MB) < 262 144 kB` | **104 280 kB** | ✅ |
| **M-对照** | 不高于改前 | 104 280 ≤ 295 136 kB（−64.7%） | ✅ |
| **A**（沿用） | `pass + known == 2038`、`fail == 0`、`unsupported == 524` | `pass=2038 fail=0 unsupported=524 known=0` | ✅ |
| **R**（回归） | 现有 337 条 + 新增全过；WARNING 不新增 | `cjpm test` **376/376**；`cjpm build` **21 条**（与改前一致） | ✅ |

## 2. 同轮对照（同一份零分配基准）

旧代码由 `git archive HEAD f_xml`（`a077dc6`）复制到 `f_xml_old/`，只替换
`Perf_test.cj` / `PerfTen_test.cj` / `PerfFifty_test.cj` 三份基准，测完即删；新代码为本变更。

### 2.1 10 MB（`F_XML_PERF=1 cjpm test --filter=PerfTen_test`，各 5 次、独立进程）

| | run1 | run2 | run3 | run4 | run5 | min | max/min | VmHWM |
|---|---|---|---|---|---|---|---|---|
| 旧 | 1026.4 | 1107.7 | 1152.2 | 1080.8 | 1150.8 | **1026.4** | 1.123 | 295 052 kB |
| 新 | 543.1 | 511.1 | 524.7 | 497.0 | 509.0 | **497.0** | 1.093 | 108 016 kB |

两轮 `max/min < 1.4` ⇒ 均非污染轮次，可用于判定。耗时 **−51.6%**。

### 2.2 50 MB（`F_XML_PERF=1 cjpm test --filter=PerfFifty_test`，单次、独立进程）

| | 耗时 | `VmHWM` | 进程地板 | 差值 |
|---|---|---|---|---|
| 旧 | 5322.9 ms | **295 136 kB** | 34 296 kB | 260 840 kB |
| 新 | 2472.0 ms | **104 280 kB** | 34 932 kB | 69 348 kB |

`VmHWM` 从「贴着默认堆上限长满」降到「运行时底座 + 70 MB」：名字不再逐次构造 `String`
（102 万 → 4 个），容器也不再逐个新建。

### 2.3 采集时的负载原文

```
21:22:35 up 2 days, 22:14,  2 users,  load average: 1.63, 1.50, 1.17
gate: env nproc=7 loadavg1=1.770000 load_bound=3.500000 gc_env=[]     # 旧 10 MB
gate: env nproc=7 loadavg1=1.700000 load_bound=3.500000 gc_env=[]     # 新 10 MB
gate: env nproc=7 loadavg1=1.670000 load_bound=3.500000 gc_env=[]     # 50 MB 两侧
```

1 分钟负载 ≤ `0.5 × nproc = 3.5`，且无任何 `cj*` 运行时变量 ⇒ 门禁有效。

## 3. 阶梯使用情况

**一级都没用。** B0（本变更主体：基准零分配 + 名字驻留 + 三缓冲复用 + 批量扫描 + 事件侧容器复用）
一次到位：10 MB 从 1026.4 ms 降到 497.0 ms，`VmHWM(50 MB)` 从 295 MB 降到 104 MB，
两项门禁各有一倍以上余量。B1–B4 / M0–M4 均未触发；`design.md` §8 的「阶梯用尽 → 重裁 Gate」
分支未进入。**未放宽任何阈值，未设置任何 GC 环境变量。**

## 4. 分段计时（诊断，非门禁；1 MB）

| 层 | 耗时 | 吞吐 |
|---|---|---|
| 纯字符层（`advanceFast`） | 11.3 ms | 90.4 MB/s |
| 词法层（切完 80 310 个令牌） | 41.1 ms | 24.9 MB/s |
| 完整事件层 | 62.3 ms | — |

词法层 → 事件层约 21 ms，剩下的是 `XmlEvent` + `Option` 包装与必然的 `String` 载荷
（公开枚举语义决定，`design.md` §2 已声明不消除）。

## 5. 一致性 / 回归证据

| 项 | 结果 |
|---|---|
| `cjpm clean && cjpm build` | `cjpm build success`；**21 条 WARNING**（与改前逐条同位置，`doc/build-warnings.md` 未新增） |
| `cjpm test` | **376 passed / 0 failed / 0 skipped**（改动前 337，新增 39） |
| xmlconf `fullSuite` | `xmlconf: pass=2038 fail=0 unsupported=524 observed=24 known=0` |
| 五条排除规则 | `edition` 313 / `external-entity` 95 / `xml-1.1` 59 / `external-subset` 47 / `namespace-name` 10（合计 524） |
| Python 工具用例 | `python3 -m unittest discover -s tools -p 'test_*.py'` = **4 条 OK** |
| 公开声明零变更 | `grep '^public '` 前后清单过滤掉 `*_test.cj` 后 `diff` **为空**（35 行） |
| 推 / 拉 / 单回调 | `PushPullParity_test` 全过（三份日志逐行相等） |

新增用例分布（39 条）：

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `NameTable_test.cj` | 7 | 命中 / 未命中 / 同 hash 反例 / 前缀切分 / 非 ASCII 与组合字符 / 上限 / 扩容重建 |
| `BufferReuse_test.cj` | 8 | 连续 token 不串内容 / 交替 1000 次 / 缓冲实例恒定 / 跨事件无别名 / 数组精确长度 / 两条错误不变 / `ByteScratch` 对拍 |
| `TextScan_test.cj` | 13 | 1 MB 批量文本（`peekCp` < 字符数/16）/ 跨块 / 非 ASCII / `]]>` / 实体切分 / 内联引用 / 0x01 位置 / 长属性值 / 空白归一 / 裸 `<` / 未闭合 / 实体展开含 `<` / ASCII 掩码 |
| `LineWindow_test.cj` | 4 | 块视图与逐字符逐点一致 / 边界取值 / 重填失效规则 / 坏字节处才抛 |
| `Lexer_test.cj` | 1 | 10 万条记录 `misses == 3`（结构性驻留证明） |
| `Perf_test.cj` | 1 | 零分配基准与旧实现逐字节 golden（含 9→10 / 99→100 进位） |
| `PerfTen_test.cj` / `PerfFifty_test.cj` | 2 | Gate T / Gate M |
| `SemanticPerf_test.cj` | 3 | 分段计时（诊断） |

## 6. Scenario → 用例对照（`specs/f-xml-semantic-layer/spec.md`）

| Requirement | Scenario | 用例 |
|---|---|---|
| 名字驻留 | 重复名字只构造一次 String | `Lexer_test.nameResidencyIsStructural`、`NameTable_test.hitReusesStoredString` |
| 名字驻留 | 同 hash 不同名字不误判 | `NameTable_test.sameHashDifferentNamesDoNotCollide` |
| 名字驻留 | 非 ASCII 与组合字符名字 | `NameTable_test.nonAsciiAndCombiningNames`、`NameTable_test.prefixAndLocalArePresplit` |
| 驻留表有界与计数 | 驻留表有界 | `NameTable_test.boundedByMaxEntries` |
| 扫描缓冲复用 | 连续 token 不串内容 | `BufferReuse_test.consecutiveTokensDoNotLeak`、`alternatingNamesAndValues` |
| 扫描缓冲复用 | token 数量不改变缓冲实例数 | `BufferReuse_test.scratchInstancesStayConstant` |
| 批量扫描 | 长文本走批量路径 | `TextScan_test.longAsciiTextIsSingleEvent` |
| 批量扫描 | 块边界不拆事件 | `TextScan_test.textAcrossBufferBoundaries` |
| 批量扫描 | 非法字符的报错位置不变 | `TextScan_test.controlCharInTextStillErrors`、`cdataCloseInTextStillErrors` |
| 批量扫描 | 属性值的空白归一不变 | `TextScan_test.attributeWhitespaceNormalizationUnchanged` |
| 事件侧复用 | 已交付事件不被后续事件改写 | `BufferReuse_test.deliveredEventIsNotAliased` |
| 事件侧复用 | 属性数组按长度精确分配 | `BufferReuse_test.attributeArrayLengthIsExact` |
| 门禁 | 10 MB 时间门禁 | `PerfTen_test.gateTenMegabytes`（§2.1） |
| 门禁 | 50 MB 内存门禁 | `PerfFifty_test.gateFiftyMegabytes`（§2.2） |
| 门禁 | 环境干净 | 两个门禁类均打印 `gate: env ... gc_env=[]`，非空即 `gate: invalid (env/load)` 并 return |
| 语义等价 | 三种前端事件日志一致 | `PushPullParity_test.pullEqualsPush` / `singleCallbackEquivalent` |
| 语义等价 | 公开声明零变更 | §5 的 `diff` |
| 语义等价 | 错误位置逐条不变 | `ParserError_test` / `InvalidByteMode_test` / `EntitySecurity_test` 全过 |

## 7. 与既有 spec 的偏离登记

| # | 既有要求 | 本变更做法 | 理由 |
|---|---|---|---|
| 1 | `f-xml-char-layer`：「文本累积 SHALL 使用 `StringGenerator`」 | **仍然遵守**：文本、属性值、声明值、CDATA、注释、PI 都用复用后的 `StringGenerator` | 未偏离 |
| 2 | `design.md` §5.3：`ByteScratch` 只在 `reset()` 不保留容量时启用 | **名字扫描**改用 `ByteScratch`（文本/值仍用 `StringGenerator`） | `reset()` 实测保留容量（§3.3），但 `StringGenerator.unsafeBytes()` 返回按 size 截好的**新数组**，逐字节比对会每 token 分配一次；名字驻留需要一个零拷贝视图。属§5.3 已授权的实现，未改 `f_base`，输出与 `StringGenerator` 逐字节一致（`BufferReuse_test.byteScratchMatchesStringGenerator`） |
| 3 | `design.md` §3.2：`Perf_test` 只留冒烟 / 矩阵 / 自检 | 保留原有 `gateTenAndFiftyMegabytes` 用例（未删除，默认 `F_XML_PERF` 关闭）作为历史冒烟；门禁判定只用 `PerfTen_test` / `PerfFifty_test` | 「337 条一条不删」优先；该用例不参与任何 Gate |

## 8. 遗留项

**无。** 两项门禁均以一倍以上余量达成，`M4`（记录曲线后重裁 Gate）未触发。
50 MB 仍由流合成、不落地测试数据；10 / 50 MB 门禁仍由 `F_XML_PERF=1` 开关，
默认 `cjpm test` 不跑大档位。
