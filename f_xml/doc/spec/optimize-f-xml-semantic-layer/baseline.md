# Baseline — optimize-f-xml-semantic-layer

> 记录时间：2026-10-30，**改动前**。本文件是 Gate M / Gate T 的对照基准；实施完成后由
> `verification.md` 记录「改后」值，本文件不改写历史。
>
> **本轮状态：§3 已补齐（2026-10-30 21:22–21:25 同轮实测）。** 旧代码 = `git archive HEAD`
> 复制到 `f_xml_old/` 并用**同一份新基准**编译（测完即删），新代码 = 本变更。两侧都是默认
> 运行时、空载机、独立进程。§3.1 / §3.2 是 Gate T / T-对照 / M / M-对照 的唯一合法对照；
> §1 / §2 / §4 / §5 是既有事实（部分来自上一轮 `verification.md`，部分来自用户本轮实测），
> 可以直接引用。

## 1. 一致性基线

| 项 | 值 | 来源 |
|---|---|---|
| `cjpm build` | 成功；`f_xml` 21 条 WARNING（逐条在 `doc/build-warnings.md`） | 上一轮 `verification.md` §5 |
| `cjpm test` | **337 passed / 0 failed / 0 skipped** | 上一轮 `verification.md` §1 |
| Python 工具用例 | **4 条**（`tools/test_xmlconf_gen.py`） | 同上 §3 |
| xmlconf Gate A | `pass = 2038`、`known = 0`、`fail = 0`、`unsupported = 524` | 同上 §1 |
| 可跑集 | 2062（2586 − 524） | 同上 |
| 五条排除规则 | `edition` 313 / `external-entity` 95 / `xml-1.1` 59 / `external-subset` 47 / `namespace-name` 10（合计 524） | 同上 §1 |
| 公开 API | `grep -rn '^public ' f_xml/src` 的清单，本变更要求 diff 为空 | 本轮待快照（`tasks.md` 0.2） |
| 构建档位 | `f_xml/cjpm.toml`：`compile-option` / `override-compile-option` 均含 `-O2` | 仓库现状 |

## 2. 性能与内存现状（上一轮 `-O2` 实测，同一合成流）

口径：合成流 `<root>` + 重复 `<item id="N" a="v">text-N</item>` + `</root>`；
`bufSize = 8192`；`XmlPullParser` 的 `while (nextEvent().isSome())` 循环，事件只计数。

| 文档 | 字节 | 事件数 | 记录数 | min | VmHWM |
|---|---|---|---|---|---|
| 1 MB | 1 048 576 | 80 311 | 26 769 | 80.1 ms | 294 956 kB |
| 10 MB | 10 485 760 | **764 857** | 254 951 | **1101.8 ms** | 294 956 kB |
| 50 MB | 52 428 800 | 3 726 208 | 1 247 399 | 5422.6 ms | 294 988 kB |

- 上一轮的 Gate 是 `10 MB < 7200 ms` 与 `VmHWM(50) ≤ 320 MB`，两项都过了。
- **本变更的 Gate 更严**：`10 MB min(5) < 1000 ms`、`VmHWM(50 MB) < 256 MB`，
  且**不得**用任何 GC 环境变量达成（见 §5）。
- 事件数校验关系：`events = 3 × records + 4`（每条记录 START/TEXT/END 共 3 条事件，
  外加 START document / START root / END root / END document）。

## 3. 同轮实测（待补 — Gate 判定的唯一合法对照）

**协议**（`tasks.md` 0.3 严格执行，缺一项则本表作废）：

1. 机器空载：`uptime` 的 1 分钟负载 ≤ `0.5 × nproc`；记录 `nproc`、`uname -r`、Cangjie SDK 版本。
2. 环境干净：`env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'` **输出为空**（不设 `cjHeapSize` / `cjGCInterval` /
   `cjRegionSize` 等任何 GC 变量）。记录该命令的原始输出。
3. 旧代码 = 当前 `HEAD`（不含本变更任何改动），新代码 = 本变更实施后；**两者用同一份
   `Perf_test` 基准**（基准自身的改造见 `design.md` §3，必须先落地再跑对照）。
4. 每档 5 次、每次独立进程、取 `min`；10 MB 与 50 MB **分进程**跑（`VmHWM` 单调，
   同进程内跑过一次 10 MB 就会污染 50 MB 的峰值）。
5. 记录 5 个单次数值；若 `max / min > 1.4`，该轮标记「负载不可信」，空载后重跑，
   **不得**用不可信轮次判负。

### 3.1 旧代码（`HEAD` = `a077dc6`，`-O2`，默认运行时，**新基准**）

同轮采集（2026-10-30 21:22–21:24，`nproc = 7`，`loadavg1 ≈ 1.63–1.77`，SDK 1.3.0-alpha，
`env | grep -iE '^cj(Heap|GC|Region|...)'` 输出为空）。旧代码由 `git archive HEAD f_xml`
复制到同仓 `f_xml_old/` 并用**同一份新基准**（`Perf_test.cj` / `PerfTen_test.cj` /
`PerfFifty_test.cj`）编译，测完即删。

| 场景 | run1 | run2 | run3 | run4 | run5 | min | VmHWM |
|---|---|---|---|---|---|---|---|
| 1 MB | 118.6 | — | — | — | — | **118.6** | 272 996 kB |
| 10 MB | 1026.4 | 1107.7 | 1152.2 | 1080.8 | 1150.8 | **1026.4** | 295 052 kB |
| 50 MB（独立进程） | 5322.9 | — | — | — | — | **5322.9** | 295 136 kB（地板 34 296） |

- 10 MB 轮 `max/min = 1.123`、50 MB 单次；均无负载污染（阈值 1.4）。
- 与 §2 的 1101.8 ms 一致：**零分配基准没有改变旧代码的耗时**（说明那 1.1 s 是解析器成本，
  不是基准的 `recordText`）——这正是 `design.md` D10 需要的证据。

### 3.2 新代码（本变更，`-O2`，默认运行时）

同轮采集（21:23–21:25，负载同 §3.1，`gc_env=[]`）。

| 场景 | run1 | run2 | run3 | run4 | run5 | min | VmHWM |
|---|---|---|---|---|---|---|---|
| 1 MB | 57.5 | — | — | — | — | **57.5** | 73 556 kB |
| 10 MB | 543.1 | 511.1 | 524.7 | 497.0 | 509.0 | **497.0** | 108 016 kB |
| 50 MB（独立进程） | 2472.0 | — | — | — | — | **2472.0** | 104 280 kB（地板 34 932） |

- 10 MB 轮 `max/min = 1.093`，无污染。
- 分段计时（`SemanticPerf_test`，1 MB，同轮）：字符层 `advanceFast` **11.3 ms**
  （90 MB/s）、词法层切完所有令牌 **41.1 ms**（25 MB/s）、完整事件层 **62.3 ms**。
  语义层（词法 → 事件）约 21 ms，只剩 `XmlEvent` + `Option` 包装与 `String` 载荷。

### 3.3 微基准（`tasks.md` 0.4 / 0.5，用于预算核对）

| 项 | 实测 | 用途 / 结论 |
|---|---|---|
| `StringGenerator()` + N 次 `append(Rune)` + `toString()` 单次成本 | 用户本轮实测 **213–240 ns/次** | 10 MB 上 ~178 万次的绝对预算 |
| `StringGenerator.reset()` 是否保留底层容量 | **保留**。同一实例 `reset + 10000 append` × 2000 次 = **111.6 ms**，每次新建 = **115.9 ms**（比值 0.96）；500 万次 `reset + append(1 字节)` 每百万耗时 8.26–8.60 ms、RSS 85 508 → 85 568 kB（+60 kB） | 复用 `reset()` 即可，**未启用**顶层 `ByteScratch` 替换文本/值缓冲（`design.md` §5.3 保持“未启用”） |
| 名字缓冲为何仍用自建 `ByteScratch` | `StringGenerator.unsafeBytes()` 返回**按 size 截好的新数组**（探针：填 10000 → 取 10000；reset 后 append 1 → 取 1），每次驻留比对都会分配 | 名字扫描需要零拷贝视图做逐字节比对，故名字用 `ByteScratch`（`design.md` D16） |
| 三段耗时占比（1 MB） | 字符层 11.3 ms / 词法 41.1 ms / 事件 62.3 ms | Gate 未达标时的阶梯排序依据；本次未用阶梯 |

### 3.4 预算核对（`tasks.md` 0.5）

本仓合成流每条记录 `<item id="N" a="v">text-N</item>` 触发：`readName` 4 次
（开始名 + 2 个属性名 + 结束名）、文本 1 次、属性值 2 次 ⇒ 每记录 7 次
`StringGenerator`（本变更后前 4 次已被驻留表吸收）。1 MB = 26 769 条 ⇒
`readName` = 107 078 次，与 `SemanticPerf_test` 实测 `names_hits + names_misses = 107 074 + 4`
一致（差 4 = `<root>` / `</root>` 的开闭标签，以及文档首尾的计数口径差）。
10 MB = 254 951 条 ⇒ ~178 万次，与用户口径 ~230 万同量级（差异来自模板/计数口径）。

## 4. 分配解剖（本变更的立论基础）

按本仓合成流模板，每条记录 `<item id="N" a="v">text-N</item>` 触发：

| 位置 | 次数/记录 | 说明 |
|---|---|---|
| `readName` → `StringGenerator()` | 4 | 开始标签名、2 个属性名、结束标签名；**只有 2 个不同字面名** |
| `nextContentToken` → `StringGenerator()` | 1 | 文本 `text-N`（每个都唯一，无法驻留） |
| `readAttributeValue` → `StringGenerator()` | 2 | 属性值 `N`（唯一）与 `v`（可复用但未复用） |
| 合计 | **7** | 10 MB 上 ≈ `254 951 × 7 ≈ 178 万`；用户口径 ~230 万，量级一致（差异在模板/计数口径，`tasks.md` 0.5 核对） |

其它每记录/每事件分配：

- `readStartTag` 的 `ArrayList<RawAttribute>()`（每标签一个）与其扩容；
- `openElement` 的 `ArrayList<XmlAttribute>()` + `ArrayList<QName>()` + `resolved.toArray()`；
- 1 个 `StringGenerator` 内部的 `ArrayList<Byte>` 及其扩容（7 次/记录）；
- `XmlEvent` + `Option<XmlEvent>` 包装（每个事件，无法消除，公开类型决定）。

已知的时间/内存成本：

| 项 | 实测 | 来源 |
|---|---|---|
| 单次 `StringGenerator` 构造+填充+toString | 213–240 ns | 用户本轮微基准 |
| GC 时间占 10 MB 总耗时 | **160–260 ms**（约 15–24%） | 用户本轮 |
| 默认 `VmHWM`（10 MB / 50 MB） | **242–295 MB** | 用户本轮 + 上一轮 288.1 MB |
| 解释 | `cjHeapSize` 默认 256 MB，堆被长满 | 用户本轮结论 |

**基准自身污染（本变更必须处理）**：`SyntheticXmlStream.read()` 每条记录调用
`recordText(n)` 生成一个 `String` 再 `.toArray()`：
10 MB 上 254 951 次、50 MB 上 1 247 399 次。这些分配与解析器无关，却记在 `VmHWM` 与
耗时里。§3 的对照必须在**修正后的无分配基准**上做，且新旧代码同用这一份基准
（`design.md` §3.1）。

## 5. 已被证伪 / 被禁用的杠杆

| 杠杆 | 效果 | 结论 |
|---|---|---|
| `cjGCInterval=100ms` | `VmHWM` 242–295 MB → **165 MB**；**耗时无改善** | **禁用**：本变更禁止用环境变量达标；且该变量在 OpenHarmony 上不生效 |
| `cjHeapSize` / `cjRegionSize` 调参 | 未测 | **禁用**：同上，且把「内存达标」变成「运行期参数达标」 |
| `bufSize` 8192 → 16384 | 10 MB −9.3%（1000.8 ms），四档差异 < 0.5% | 不采用：不构成拐点，且改默认值是行为面变化（上一轮 D5） |
| `peekFast` / `advanceFast`、去两层 `ArrayList<Rune>` | ≈ 15% | 已在 M1 做完，量级不变 |

结论：剩余的可压空间只在**语义层分配**（名字、值、文本、事件侧临时容器）与
**基准自身分配**。这也是本变更的唯一方向。

## 6. 复现命令

```bash
# 模块根：f_xml
git rev-parse HEAD                     # 记录被测提交
env | grep -iE '^cj(Heap|GC|Region|Large|Exemption|Allocation|Garbage|Backup|Processor|Stack)'                    # 必须为空
uptime; nproc

# 一致性
cjpm clean && cjpm build
cjpm test                              # 337 条
python3 -m unittest discover -s tools -p 'test_*.py' -v   # 4 条

# 性能（本变更后：10 MB 与 50 MB 分进程）
F_XML_PERF=1 cjpm test --filter=PerfTen_test
F_XML_PERF=1 cjpm test --filter=PerfFifty_test

# Gate A（需缓存，缺缓存先跑 tools/xmlconf_gen.py）
# 看 XmlconfHarness_test.fullSuite 的输出行
```

## 7. 判定口径提醒

- **绝对门禁**：`10 MB min(5) < 1000 ms`、`VmHWM(50 MB) < 256 MB`，默认运行时，
  空载机、同一轮次、同一份基准。
- **同轮对照**：`new_min(10 MB) ≤ 0.95 × old_min(10 MB)`——只用于证明增益来自代码
  而不是机器变快；不替代绝对门禁。
- **波动上限**：本机同代码重复测量可达 1.4 倍差异。任何一轮 `max/min > 1.4` 视为
  负载污染，重测；**不得**据此判负，也**不得**据此判正。
- **一致性不降级**：2038 / 0 / 524、五条规则 313 / 95 / 59 / 47 / 10、337 条用例、
  4 条 Python 用例一条不删、期望不改。
- **公开声明零变更**：`grep '^public '` 的 diff 为空（`public class *_test` 除外）。
