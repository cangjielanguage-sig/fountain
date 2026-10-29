# Baseline — complete-f-xml-m1-followups

> 记录时间：2026-10-29，改动前。数据来源：`implement-f-xml-m1/verification.md`、
> `implement-f-xml-m1/design.md` §10.1 / §13、当前 `f_xml` 源码。本文件是 Gate P / R 的
> 对照基准；实施完成后由 `verification.md` 记录「改后」值，本文件不改写历史。

## 1. 一致性

| 项 | 值 |
|---|---|
| `cjpm build` | 成功；`f_xml` 自身 20 条 WARNING（`doc/build-warnings.md`） |
| `cjpm test` | 303 passed / 0 failed / 0 skipped（`verification.md` 口径） |
| xmlconf Gate A | `pass=2038`（known=0）、`fail=0`、`unsupported=524`、`observed=24` |
| 可跑集 | 2062（2586 − 524）；五条规则 313 / 95 / 59 / 47 / 10 |
| 公开 API | 约 20 个 `public` 类型 + 6 个 `parse` 重载（`proposal.md` Impact 口径） |

注：`f_xml/README.md` 状态段写「298 条单元测试」，与 `verification.md` 的 303 不一致；
以 303 为准，本变更在 11.1 校正 README。

## 2. 性能

| 场景 | 实测（开发机、单线程） | 备注 |
|---|---|---|
| 事件模式 1 MB | **998 ms**（98305 events） | 2026-10-29 本机实测 |
| 事件模式 10 MB | **9649 ms**（983041 events） | 同上，单次、无预热 |
| 事件模式 50 MB | 未测（按线性 ≈ 48 s） | 本变更补测 |
| DOM 模式 10 MB | 与事件模式同量级 | 只记录 |
| RSS / `VmHWM` | 无断言 | 本变更补测 |

实测口径（临时基准，实施后由 `Perf_test` 取代）：合成流 =
`<root>` + 重复 `<item id="1" a="v">text-1</item>`（32 B/条）+ `</root>`；
`XmlPullParser`（`bufSize = 8192`）的 `while (nextEvent() != None)` 循环，
事件只计数；1 MB / 10 MB 各跑一次、不预热，取单次数值。

与预填值（1 MB ≈ 1.5 s、10 MB ≈ 15.8 s，来自 M1 `verification.md` §4 的另一种模板）
的差异来自输入模板与是否预热；本变更的 Gate P 以本文件这组实测为对照。

原始目标（设计文档 §13.2）：**10 MB < 1 s**。当前差约 9.6×。

## 3. 已做过的优化与结论

| 已试 | 收益 | 结论 |
|---|---|---|
| `peek` / `advance` → `peekFast` / `advanceFast`（码点直返） | — | 保留 |
| 去掉 Lexer 的两层 `ArrayList<Rune>` | — | 保留 |
| 上述两项合计 | ≈ 15% | **量级不变**，证明瓶颈是结构 |

瓶颈定位（M1 `design.md` §13）：

1. 每字符一次 `Option` 分配（仓颉 `Option` 是引用类型）；
2. 三层缓冲：`RuneSource`（16 槽环）→ `LineWindow`（16 槽环）→ `Lexer` 输入栈；
3. 每字符一次 `ByteDecoder.next`（`match` codec + `ensure` + `peek` + `consume`）。

## 4. 字符层现状（代码事实）

| 位置 | 现状 |
|---|---|
| `RuneSource.cj` `BufferedRuneSource` | `Array<Rune>(16)` 环形缓冲，`pull()` 每字符一次 |
| `RuneSource.cj` `ByteDecoder.next` | UTF-8 strict / replace 分支，逐字符判定 + 消费 |
| `RuneSource.cj` `ByteReader` | 固定块字节缓冲，`ensure(count)` 逐次判断；无批量 ASCII 搬运 |
| `LineWindow.cj` | 第二个 `Array<Rune>(16)` 环；`pullNormalized` 每字符一次 `source.advanceFast` |
| `Lexer.cj` | `peekCp` / `advanceCp` 在单帧时直连 `LineWindow`，多帧时走 `?Rune`；扫描方法大量 `peek(0)` / `advance()` |
| `Lexer.cj` `startsWith` | 每次 `runesOf(text)` 新建数组；`startsWith("?>")` 在 PI 循环里每字符一次 |
| `ExpandSink.cj` `SinkFeed` | `ArrayList<Rune>` 逐字符追加；`ExpandReader.next(): ?Rune` |
| `ExpandSink.cj` `SpillDir.createFile` | 候选解析与尝试循环耦合，四级失败分支不可注入 |

## 5. P3 缺口（M1 `verification.md` §3 原文）

| # | 缺口 | 现状 |
|---|---|---|
| 1 | `SpillDir.createFile` 四级全失败 | 只有显式目录 / TMPDIR / 回落目录的成功路径有用例 |
| 2 | 两个解析器实体计数独立 | 由实例字段保证，缺并发 / 交错用例 |
| 3 | `xmlconf_gen.py` SHA-256 不匹配 | 代码存在（`sys.exit(2)` / `return 2`），无自动化 |

## 6. 复现基线

```bash
# 模块根：f_xml
cjpm clean && cjpm build
cjpm test

# 一致性
# 需先准备缓存：python3 tools/xmlconf_gen.py
# 然后看 XmlconfHarness_test.fullSuite 的输出行

# 性能（本变更新增基准后）
F_XML_PERF=1 cjpm test --filter=Perf

# Python 工具（本变更新增）
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

## 7. 验收口径提醒

- 本变更的 Gate：10 MB `min(3) < 1000 ms`、`VmHWM(50 MB) − VmHWM(10 MB) ≤ 24 MB`。
- 一致性不降级：2038 / 524 / 0 原样沿用；现有 303 条用例一条不删、期望不改。
- 公开声明零变更：以 `grep '^public '` 的 diff 为空为准。
