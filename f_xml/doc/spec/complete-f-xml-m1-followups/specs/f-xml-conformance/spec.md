# Spec Delta — f-xml-conformance

## Purpose

把 M1 里「性能只记录」的临时口径收敛为本变更的**出口 Gate**，并补齐三处验收证据：
性能基准可复现、`bufSize`（R5）实测回填、`xmlconf_gen.py` 的 SHA-256 不匹配分支有自动化
用例。xmlconf 的可跑集口径（五条排除规则、2062 / 524 / 2038）**不变**。

## REMOVED Requirements

### Requirement: 性能只记录、不作门禁

**Reason**: M1 把性能移出出口是临时安排；本变更承接字符层重写后，性能成为可判定的
Gate P（10 MB < 7.2 s + RSS 非线性增长），继续保留「不作门禁」会与新 Gate 直接冲突。

**Migration**: 由本文件 ADDED 的「性能门禁」替代。原口径里的「内存 O(嵌套深度)」
「RSS 不作断言」两条约束不放宽：前者由 `retainedBytes` + `VmHWM` 差值保证，后者改为
**差值**断言（绝对值只记录）。

## MODIFIED Requirements

### Requirement: 验收门槛

验收 SHALL 同时满足下列四道 Gate：

| Gate | 标准 |
|---|---|
| A（必过） | 2038 条断言全部符合期望（`fail == 0`，`pass + known == 2038`） |
| B（例外管理） | `f_xml/tools/known-issues.json` 每条写明理由 + 规范章节，上限 5 条；超出即不通过 |
| C（可追溯） | 每次运行输出 `pass / fail / unsupported / observed`，并把 `unsupported` 的 ID 清单存档 |
| P（性能） | 10 MB `min(3) < 7200 ms`（相对基线 9649 ms ≥25%）；`VmHWM(50 MB) − VmHWM(10 MB) ≤ 24 MB` |

`known-issues` SHALL **默认清空（0 条）**。Gate A 的五条排除规则
（`edition` 313 / `external-entity` 95 / `xml-1.1` 59 / `external-subset` 47 /
`namespace-name` 10 = 524）SHALL 原样沿用；`unsupported` 524、可跑 2062、断言 2038
三个数字 SHALL NOT 改动。

#### Scenario: Gate A

- **WHEN** 运行全量套件
- **THEN** `fail == 0`，`pass + known == 2038`，`unsupported == 524`

#### Scenario: Gate P 与 Gate A 同时判定

- **WHEN** 性能与一致性都跑完
- **THEN** 任一道 Gate 不通过都视为本变更未验收通过，不接受「先合并再补」

#### Scenario: known-issues 为空是常态

- **WHEN** `f_xml/tools/known-issues.json` 为空数组
- **THEN** harness 通过 Gate B，不要求至少登记 1 条

#### Scenario: Gate B 超限即失败

- **WHEN** `known-issues.json` 有 6 条
- **THEN** harness 直接判不通过

#### Scenario: Gate C 三数字

- **WHEN** 任意一次运行
- **THEN** 输出 `pass / fail / unsupported`（可附加 `observed`），并写出 `unsupported` 的 ID 清单文件

## ADDED Requirements

### Requirement: 性能门禁

性能 SHALL 作为本变更的出口条件（Gate P），按下列口径判定：

| 指标 | 标准 |
|---|---|
| 事件模式 10 MB | `min(3 次) < 7200 ms`（相对基线 9649 ms ≥25%） |
| `VmHWM(50 MB) − VmHWM(10 MB)` | ≤ 24 MB |
| `VmHWM(50 MB)` | ≤ 256 MB |

1 MB 与 50 MB 的耗时 SHALL 记录但不设上限。DOM 模式 SHALL NOT 作为门禁，只记录。

RSS SHALL 用 `/proc/self/status` 的 `VmHWM`（峰值）；文件不可用时 SHALL 记录
`unavailable` 并跳过 RSS 断言，SHALL NOT 判 fail。RSS 断言超限时 SHALL 按
`design.md` §6.3 / §13 的方式复核（重测、查线性保留），SHALL NOT 以放宽阈值收尾。

事件模式的内存复杂度 SHALL 仍为 O(嵌套深度)，由 `retainedBytes`（内存侧保留字节）与
`VmHWM` 差值共同保证。

#### Scenario: 10 MB 事件解析达标

- **WHEN** `F_XML_PERF=1`，解析合成 10 MB 文档，事件回调为空操作
- **THEN** 3 次计时（去掉预热）的最小值 < 7200 ms

#### Scenario: RSS 不随文档线性增长

- **WHEN** 依次解析 1 MB、10 MB、50 MB
- **THEN** `VmHWM(50 MB) − VmHWM(10 MB) ≤ 24 MB`，且 `VmHWM(50 MB) ≤ 256 MB`

#### Scenario: 基准默认不拖慢回归

- **WHEN** 未设置 `F_XML_PERF=1` 运行 `cjpm test`
- **THEN** 10 MB / 50 MB / RSS 用例只打印 `perf: disabled` 并直接返回，不判 fail

#### Scenario: DOM 不作门禁

- **WHEN** DOM 模式解析 10 MB 耗时超过 1 s
- **THEN** 不因此判 fail，只在记录中体现

### Requirement: 性能基准可复现

基准 SHALL 用**合成 `InputStream`** 生成文档，SHALL NOT 依赖入库的大文件。
合成流 SHALL 满足：

1. 精确产出目标字节数（允许 ±64 B，实际值 SHALL 打印）；
2. 文档良构，事件数与文档规模成线性；
3. 可重复：同一 `targetBytes` 两次生成的字节序列一致。

计时口径 SHALL 固定：

- 先预热一次 1 MB（丢弃结果）；
- 只对 `nextEvent()` 循环计时，事件回调为空操作；
- 每档重复 3 次（每次新建流与 parser），报告 3 个值与最小值；
- 输出行 SHALL 包含 `bytes / events / ms=[…] / min / rss_kb / hwm_kb / buf`。

#### Scenario: 合成流字节数准确

- **WHEN** `targetBytes = 10 * 1024 * 1024`
- **THEN** 合成流产出的总字节数与目标值之差 ≤ 64，且文档可被完整解析

#### Scenario: 计时结果可复核

- **WHEN** 重跑同一档基准
- **THEN** 输出格式一致，3 个计时值都可见，`min` 与最小值一致

### Requirement: `bufSize` 实测与回填

R5 SHALL 实测 `bufSize ∈ {4096, 8192, 16384, 65536}` 在 1 MB 与 10 MB 文档上的事件解析
耗时（每档 3 次取最小），SHALL 记录曲线形状与拐点。

实测结果 SHALL 回填到：

- `design.md` §8.2（本变更）；
- `f_xml/doc/f_xml模块设计.md` §15.1；
- `f_xml/README.md` 的状态段；
- `implement-f-xml-m1/design.md` §10.1 的 R5 行（改为「已实测」并给出指向）。

本变更 SHALL NOT 修改 `bufSize` 的默认值（仍为 8192）。

#### Scenario: 矩阵完整

- **WHEN** 跑 R5
- **THEN** 4 个 `bufSize` × 2 档文档共 8 个结果都有记录，缺一即视为未完成

#### Scenario: 默认值不变

- **WHEN** 对比改动前后的 `XmlParserOptions.init` 默认参数
- **THEN** `bufSize` 仍为 8192

### Requirement: 生成脚本自测

`f_xml/tools/xmlconf_gen.py` SHALL 有可执行的自动化用例
（`f_xml/tools/test_xmlconf_gen.py`，标准库 `unittest`，不引入第三方依赖），至少覆盖：

1. SHA-256 匹配 → 通过；
2. SHA-256 不匹配 → 返回非 0，stderr 含期望值与实际值；
3. 端到端不匹配 → 进程退出码非 0，且**不**产出 `cases.json` / `unsupported.json`，
   也**不**解压（`suite/` 不存在）。

校验逻辑 SHALL 收敛为单一函数（`ensure_sha256`），`download()` 与 `main()` SHALL 复用，
SHALL NOT 各写一份。

#### Scenario: 不匹配时中止且不产出

- **WHEN** 缓存目录里放一个损坏的 `download/xmlts20130923.tar.gz`，运行
  `F_XML_XMLCONF_CACHE=<tmp> python3 f_xml/tools/xmlconf_gen.py --offline`
- **THEN** 退出码非 0，stderr 含 `SHA-256 不匹配`、期望值、实际值；
  `<tmp>/cases.json` 与 `<tmp>/unsupported.json` 都不存在

#### Scenario: 匹配时通过

- **WHEN** 用一个内容已知、期望值由 `sha256_of` 现算的临时文件调用 `ensure_sha256`
- **THEN** 返回 0

#### Scenario: 单一校验入口

- **WHEN** 检查脚本源码
- **THEN** 只有一处计算/比较 SHA-256 的实现，`download()` 与 `main()` 都调用它
