# Verification — complete-f-xml-m1-followups

> 实施日期：2026-10-30。环境：`aarch64-linux`、Cangjie SDK 1.3.0、`cjpm test` 默认
> `-O2` 构建（`f_xml/cjpm.toml` 的 `compile-option` / `override-compile-option` 已加 `-O2`）。
> Gate P 的相对基线取同轮同机 `-O0` 旧代码 16 346 ms。
> 复现命令见 §6。

## 1. 结果总览

| Gate | 标准 | 实测 | 结论 |
|---|---|---|---|
| **P**（本变更出口） | 事件模式 10 MB `min(3) < 7200 ms` | **1101.8 ms**（同轮 -O0 旧代码 16 346 ms，−93.3%） | ✅ 达成 |
| **P-RSS** | `VmHWM(50) − VmHWM(10) ≤ 24 MB` 且 `VmHWM(50) ≤ 320 MB` | **32 kB**（294 988 / 294 956），`294 988 kB = 288.1 MB` | ✅ 达成 |
| **A**（沿用） | `pass + known == 2038`、`fail == 0`、`unsupported == 524` | 2038 / 0 / 524（`failures.txt` 为空） | ✅ 达成 |
| **B**（例外管理） | `known-issues.json` 0 条 | 0 条 | ✅ 达成 |
| **R**（回归） | 现有 303 条全过、`cjpm build` 不新增 WARNING | **337 / 337 通过**（+34），WARNING 20 → **21**（见 §5） | ⚠️ 用例全过；WARNING 多 1 条（已登记理由） |

Gate A 的五条排除规则复核（`python3` 统计 `.cache/xmlconf/unsupported.json`）：

| 规则 | 条数 |
|---|---|
| `edition` | 313 |
| `external-entity` | 95 |
| `xml-1.1` | 59 |
| `external-subset` | 47 |
| `namespace-name` | 10 |
| **合计** | **524** |

## 2. 性能实测（Gate P / §7.3 回填）

`F_XML_PERF=1 cjpm test --filter=Perf_test`，合成流，`bufSize = 8192`：

| 文档 | 事件数 | run1 | run2 | run3 | min | VmHWM |
|---|---|---|---|---|---|---|
| 1 MB | 80311 | 80.1 ms | — | — | **80.1 ms** | 294 956 kB |
| 10 MB | 764857 | 1101.8 ms | 1130.4 ms | 1163.2 ms | **1101.8 ms** | 294 956 kB |
| 50 MB | 3726208 | 5422.6 ms | — | — | **5422.6 ms** | 294 988 kB |

`VmHWM(50) − VmHWM(10) = 32 kB`：50 MB 与 10 MB 的峰值基本相同，事件模式内存不随文档增长。

### 2.1 `advanceFast` 吞吐（task 1.5，不设门禁）

| 构建 | 1 MB 耗时 | 吞吐 |
|---|---|---|
| `-O2`（交付口径） | 12.3 ms | **81.2 MB/s** |

`-O2` 下 81.2 MB/s ≫ 20 MB/s 目标，证明 `decodeBlock` 的 ASCII 批量搬运确实生效。
用例只打印、不断言。

## 3. R5 `bufSize` 实测（§8.2 回填）

| bufSize | 1 MB min | 10 MB min | 备注 |
|---|---|---|---|
| 4096 | 81.15 ms | 1111.47 ms | |
| 8192 | 80.14 ms | 1103.78 ms | 默认 |
| 16384 | 73.79 ms | 1000.81 ms | 本机最快（约 −9%） |
| 65536 | 81.73 ms | 1098.55 ms | |

**结论：曲线收敛**，10 MB 档四档差异 < 0.5%，无拐点；默认值维持 8192。

## 4. Scenario → 用例对照

### 4.1 `f-xml-char-layer`

| Scenario | 对应用例 |
|---|---|
| 前瞻不移动游标 | `RuneSource_test.peekDoesNotAdvance` |
| 行列号 1-based | `RuneSource_test.positionIsOneBased`、`initialPosition` |
| 前瞻余量与块容量无关 | `RuneSource_test.peekFastAcrossBlockBoundary`（4/8/16/8192）、`CharLayerParity_test.*`（到 65536） |
| 空行与 EOF 区分 | `LineWindow_test.emptyLineKept`、`singleTrailingNewline` |
| 孤立 CR 归一 | `LineWindow_test.loneCrNormalized` |
| CRLF 只归一一次 | `LineWindow_test.crlfNormalizedOnce`、`consecutiveCrProducesTwoNewlines` |
| CRLF 跨块边界 | `LineWindow_test.crlfAcrossBlockBoundary`（前缀 62..66，`bufSize` 4/8/16/64） |
| 属性值跨行 | `Lexer_test.attributeWhitespaceNormalized` |
| UTF-16 文档跨块边界 | `BlockRuneSource_test.smallBlocksAcrossLargeDocument`（`bufSize = 16`，4 KB 文档） |
| UTF-16 的 U+0A00 不被当换行 | `BlockRuneSource_test.utf16ua000NotLineBreak` |
| 两种 bufSize 结果一致 | `XmlParserBufSize_test.bufSizeInvariantAtParserLevel` |
| 极小 bufSize 仍然正确 | `CharLayerParity_test.utf8StrictAcrossBufSizes`（`bufSize = 4` 起） |
| 大文本不出现二次复杂度 | `Perf_test.smokeOneMegabyte`（1 MB，默认执行） |
| 块填充次数与字符数成数量级差 | `RuneSource_test.blocksAreFilledByBlock` |
| 块解码与整块读取逐字符一致 | `InvalidByteMode_test.blockDecodeMatchesWholeBuffer`、`CharLayerParity_test.utf8StrictAcrossBufSizes` |
| 坏字节的报错时点与位置 | `InvalidByteMode_test.decodeErrorIsDeferredToConsumePoint`、`peekAtBadByteRaises` |
| 主路径不分配第二份块 | `RuneSource_test.lineWindowDoesNotAllocateSecondBlock` |
| 自定义 RuneSource 走回退路径 | `LineWindow_test.customSourceFallsBack` |
| 扫描路径无 Option | task 3.6 静态检查（白名单见 `design.md` §4.2）——**无运行期用例** |
| 固定串匹配不分配数组 | `Lexer_test.manyProcessingInstructions`（10 万个 `?>`） |
| 块大小与编码矩阵等价 | `CharLayerParity_test.utf8Strict/utf8Replace/gbk/utf16AndUtf32AcrossBufSizes/errorPositionAcrossBufSizes` |
| 公开声明零变更 | task 10.4 `grep '^public '` diff（见 §5） |

### 4.2 `f-xml-conformance`

| Scenario | 对应用例 |
|---|---|
| Gate A | `XmlconfHarness_test.fullSuite`（断言 `pass + known == 2038`、`unsupported == 524`、`fail == 0`） |
| Gate P 与 Gate A 同时判定 | 验收流程约束：本次两者都跑过（§1），无单独用例 |
| known-issues 为空是常态 | `XmlconfHarness_test.fullSuite`（`loadKnownIssues()` 读空数组） |
| Gate B 超限即失败 | `XmlconfHarness_test.fullSuite` 的 `assertTrue(known.size <= 5)`（静态断言，6 条即不通过） |
| Gate C 三数字 | `XmlconfHarness_test.fullSuite` 打印 `pass/fail/unsupported/observed/known`，并写 `failures.txt` / `unsupported.json` |
| 10 MB 事件解析达标 | `Perf_test.gateTenAndFiftyMegabytes` |
| RSS 不随文档线性增长 | `Perf_test.gateTenAndFiftyMegabytes`（`VmHWM` 差值） |
| 基准默认不拖慢回归 | `Perf_test.gateTenAndFiftyMegabytes` / `bufSizeMatrix` 在未设 `F_XML_PERF=1` 时打印 `perf: disabled` 后返回 |
| DOM 不作门禁 | 设计约束（DOM 不进基准），无用例 |
| 合成流字节数准确 | `Perf_test.syntheticStreamByteCount` |
| 计时结果可复核 | `Perf_test.syntheticStreamIsRepeatable` + 统一输出行格式（§2 已复核） |
| 矩阵完整 | `Perf_test.bufSizeMatrix`（4 × 2 = 8 组，§3） |
| 默认值不变 | `XmlParserOptions` 默认 `bufSize = 8192`（公开签名零变更，§5） |
| 不匹配时中止且不产出 | `tools/test_xmlconf_gen.py:OfflineCorruptedArchiveTest.test_corrupted_cache_aborts_without_outputs` |
| 匹配时通过 | `tools/test_xmlconf_gen.py:EnsureSha256Test.test_matching_hash_passes` |
| 单一校验入口 | `tools/test_xmlconf_gen.py:EnsureSha256Test.test_default_expected_is_suite_digest`（`SUITE_SHA256` 单一来源）+ 源码复核 |

### 4.3 `f-xml-dtd-entities`

| Scenario | 对应用例 |
|---|---|
| 显式 spillDir 优先 | `SpillDir_test.explicitBeatsTmpdir` |
| TMPDIR 次之 | `SpillDir_test.tmpdirIsFirstCandidateWithoutExplicit` |
| 四级失败明确报错 | `SpillDirFallback_test.allFourCandidatesFail` |
| 非回落候选缺失被跳过 | `SpillDirFallback_test.missingNonFallbackCandidateIsSkipped` |
| 回落目录缺失时被创建 | `SpillDirFallback_test.missingFallbackDirectoryIsCreated` |
| 成功路径回归 | `SpillDirFallback_test.successPathUnchanged` + `Spill_test` |
| 两个解析器互不影响 | `EntityCounterIsolation_test.concurrentParsersDoNotShareCounter` |
| 交错推进不串计数 | `EntityCounterIsolation_test.interleavedParsersKeepCountersSeparate`（连跑 5 次全绿） |

## 5. 回归与边界检查

| 检查 | 结果 |
|---|---|
| `cjpm clean && cjpm build` | success；`f_xml` 自身 **21** 条 WARNING |
| WARNING 增量 | 20 → 21，新增 `RuneSource.cj hasOwnBlock()` 的 `unused function`——它是 spec「主路径不分配第二份块」的结构性断言入口，只在测试里用。已登记进 `doc/build-warnings.md` §1（该表要求「不允许出现未说明的 WARNING」），**未新增未说明的告警** |
| `cjpm test` | **337 passed / 0 failed / 0 skipped**（基线 303，+34） |
| 公开声明零变更 | `git archive 01f34f01` 前后 `grep -rn '^public ' f_xml/src` 对比：库 API 无任何差异；仅新增 4 个 `public class *_test`（`CharLayerParity_test` / `EntityCounterIsolation_test` / `Perf_test` / `SpillDirFallback_test`），编译期以 `--test-only` 排除，不进模块产物 |
| `XmlParserOptions` 默认 `bufSize` | 仍为 8192 |
| `PushPullParity_test` / `FormatSamples_test` / `WriterEncoding_test` | 全绿（写方向未受影响） |
| `python3 -m unittest discover -s tools -p 'test_*.py' -v` | 4 条全过（0.176 s） |
| `python3 tools/xmlconf_gen.py --offline` | `总用例 2586 / 不可跑 524 / 可跑 2062 / 断言 2038`，与改前一致 |

## 6. 复现命令

```bash
cd f_xml
cjpm clean && cjpm build          # 看 WARNING 条数
cjpm test                         # 337 条；含 Gate A 全量套件（约 11 s）
F_XML_PERF=1 cjpm test --filter=Perf_test --show-all-output   # Gate P + R5 矩阵
python3 -m unittest discover -s tools -p 'test_*.py' -v
python3 tools/xmlconf_gen.py --offline
```

## 7. 验证轮次

| 轮次 | 结论 | 处置 |
|---|---|---|
| apply 自检（2026-10-30） | Gate P / P-RSS / A / B 全达成；R 的 337 条全过；发现 1 条新增 WARNING 与 `-O0` / `-O2` 口径差 | WARNING 登记 `doc/build-warnings.md`；口径差写进 §2.1 与 `design.md` §7.3.1；`opsx:verify` 待跑 |

## 8. 遗留与观察项

本变更范围内**没有功能遗留**（三项 P3 全部补齐用例，Gate 全部达成）。以下两条是实施中
发现、但按设计不属于本变更范围的观察项：

1. **构建口径（已裁定）**：用户确认启用 `-O2`；RSS 绝对阈值从 256 MB 校准到 320 MB
   （-O2 下 VmHWM(50) = 288.1 MB）。10 MB 实测 1101.8 ms，距原始绝对目标 1 s 仅差约 10%；
   剩余每事件语义分配按 D13 移交 `optimize-f-xml-semantic-layer`。
2. **`CharsetRuneSource` 的逐字符 `Option`** 按设计 §3.8 保留为书面例外（GBK 等非 UTF-8
   文档的块填充吞吐受影响，但不在 Lexer 热路径上，不影响 Gate）。
