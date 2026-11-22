# 任务：`SseReader.readLine` 复用实例字节行缓冲

> TDD：先写等价性 / 边界 / 分配用例（Red），再改实现（Green），最后跑门控基准并回填数字。
> 每个任务完成后独立提交；分支 `feature/reuse-sse-line-buffer`（AGENTS.md §5）。
> 本变更只改 `f_httpclient`，不新增依赖、不改配置与路由、不动公开 API。

## T1 前置确认（不改代码）

- [x] 1.1 用 std 文档确认 `String.fromUtf8` 的可用重载：
      仅有 `(Array<Byte>)` 与 `fromUtf8Unchecked(Array<Byte>)`，没有 `(bytes, start, len)` 形式；
      采用 `lineBuf[0 .. end]` 前缀切片（`design.md` §4.3）
- [x] 1.2 确认切片语义与 `fromUtf8` 拷贝：编译器探针实测 `Array<Byte>[a..b]` 是共享存储的视图（切片本身 0 分配），
      `String.fromUtf8` 会把前缀复制进独立的 String，因此不会持有 `lineBuf` 的存储（`design.md` §4.3 / I2）
- [x] 1.3 复核现状语义，逐条记录：`\n` 与 `\r\n`、空行、注释、EOF 半行不剥 `\r`、
      `maxLineBytes` 在 `bytes.size > maxLineBytes` 处抛错（`SseReader.cj:169-172`）
- [x] 1.4 记录基线分配（临时探针，不入库）：旧 `readLine` 在 20000 行短行上的
      摊销分配与耗时，写入 `design.md` §10.3「改造前基线」

## T2 新增测试（Red）

新增 `f_httpclient/src/sse/SseReaderLineBuffer_test.cj`（包 `fountain::f_httpclient.sse`）。

- [x] 2.1 测试基建：`ThrottledStream <: InputStream`，每次 `read` 最多返回 `maxChunk` 字节；
      另加可复位的 `BenchStream` 供基准复用同一字节数组（未修改 `SseReader_test.cj`）
- [x] 2.2 Red：`testShortLinesReuse` —— 1000 行 `data: v<i>` + 空行，序号连续、末尾为 `None`
- [x] 2.3 Red：`testLongLineGrowsBuffer` —— 单行 1000 B（> 初始 256 B），内容与长度精确
- [x] 2.4 Red：`testLineAcrossManyChunks` —— `ThrottledStream(7)` 喂 9000 B 的 `data:` 行，
      断言长度 9000、内容全为 `x`
- [x] 2.5 Red：`testCrlfSplitAcrossChunks` —— 块 `data: a\r` / `\ndata: b\r` / `\n\r\n`，
      断言 `data == "a\nb"`
- [x] 2.6 Red：`testCrAtEofIsPreserved` —— 流 `data: a\r`（无 `\n`），断言 `data == "a\r"`
- [x] 2.7 Red：`testStaleTailDoesNotLeak` —— 先 1000 B 长行、再 `data: b`，断言第二条为 `b`
- [x] 2.8 Red：`testMaxLineBytesExactlyAtLimit` —— `maxLineBytes = 16`，16 B 行不抛
- [x] 2.9 Red：`testMaxLineBytesOverLimit` —— 同配置，17 B 行抛 `SseLineTooLongException`
- [x] 2.10 Red：`testHalfLineAtEof` —— 流 `data: abc`，断言 `data == "abc"`
- [x] 2.11 运行：`cd f_httpclient && cjpm test --filter '*SseReaderLineBuffer*'`，
      确认用例可编译、行为用例通过、仅有基准用例因门控打印 `SKIP:`

> 说明：本变更的「Red」不是编译失败，而是**分配基准的断言在旧实现上必然失败**
> （旧实现每行新建集合）。行为用例在旧实现上应当直接通过，这是等价性的前提；
> 若 2.2～2.10 中有用例在旧实现上失败，先修正用例而不是改实现。

## T3 实现（Green）

- [x] 3.1 `SseReader` 增加 `private static let INITIAL_LINE_BYTES: Int64 = 256`
- [x] 3.2 增加 `private var lineBuf`（init 中按 `min(256, max(0, maxLineBytes))` 创建）与
      `private var lineLen: Int64 = 0`；注释写明「只有 `[0, lineLen)` 有效」
- [x] 3.3 增加 `private func ensureLineCapacity(need: Int64): Unit`：2 倍增长、
      在 `maxLineBytes / 2` 处收敛到 `maxLineBytes`、只拷贝 `[0, lineLen)`（`design.md` §4.3）
- [x] 3.4 增加 `private func takeLine(stripCr!: Bool): String`：只在 `stripCr` 时剥末尾 `\r`；
      先 `lineLen = 0` 再 `String.fromUtf8` 前缀
- [x] 3.5 替换 `readLine` 函数体：行首复位；`\n` 分支 → `takeLine(stripCr: true)`；
      EOF 分支 → `takeLine(stripCr: false)`；超限判定移到写入前并复位后抛错
- [x] 3.6 保持返回类型 `?String`、`None` 语义、`SseLineTooLongException` 类型与
      `fill()` / `pos` / `len` / `eof` / `lastActivityAt` 的现有用法逐字不动
- [x] 3.7 检查无新增 `public` 符号：构造参数、`next` / `close` / `isClosed` 签名逐字不变
- [x] 3.8 运行：`cd f_httpclient && cjpm test --filter '*SseReaderLineBuffer*'` 全绿

## T4 分配基准（`F_HTTPCLIENT_SSE_BENCH=1`）

- [x] 4.1 `sseBenchEnabled()` 门控 + `sseBenchSettleGc()`（`gc(heavy: true)` 后等 `getGCCount()` 连续 3 次不变）
- [x] 4.2 分配量 = `(getAllocatedHeapSize 增量) + (getGCFreedSize 增量)`，5 样本中位数
- [x] 4.3 `case=line_reuse`：20000 行 `: aaaa\n` 一次 `next()` 读完，在 `-O2` 参考构建下断言 `allocPerLine <= 96`（`-O0` 仅记录，见 design §10.1）
- [x] 4.4 `case=line_fresh`：测试内重现旧算法（`ArrayList<Byte>` + `toArray()` + `fromUtf8`），
      只打印；断言 `line_reuse * 2 < line_fresh`
- [x] 4.5 `case=line_long`：8192 B 行 × 200，打印 `allocPerLine` / `nsPerLine`
- [x] 4.6 `case=event_small`：5000 条 `data: x\n\n` 走 `next()`，打印 `allocPerEvent` / `nsPerEvent`
- [x] 4.7 未设 `F_HTTPCLIENT_SSE_BENCH=1` 时打印 `SKIP:` 并返回，默认 `cjpm test` 不受影响
- [x] 4.8 按 `design.md` §10.2 的 `-O2` 口径运行
      `F_HTTPCLIENT_SSE_BENCH=1 cjpm test --filter '*SseReaderLineBuffer*' --show-all-output`
      （临时给 `f_httpclient/cjpm.toml` 追加 `-O2`，测完回退），输出写入 `design.md` §10

## T5 回归

- [x] 5.1 `f_httpclient/src/sse/SseReader_test.cj` 的 8 条既有用例**一字不改**、通过
- [x] 5.2 `cd f_httpclient && cjpm test` 全绿
- [x] 5.3 `cd f_httpclient && cjpm build` 不新增 WARNING
- [x] 5.4 检查 `git diff f_httpclient/src/sse/SseReader.cj`：只涉及私有常量 / 私有字段 /
      私有辅助函数与 `readLine` 函数体，无 `public` 符号变化
- [x] 5.5 README 的「实现要求」表补第 11 条「行读取复用实例字节缓冲」，仅加说明，不改公开 API 声明

## T6 产物与提交

- [x] 6.1 回填 `design.md` §10 后，确认 `f_httpclient/doc/spec/reuse-sse-line-buffer/` 与
      `openspec/changes/reuse-sse-line-buffer/` 逐文件一致（`diff -ru` 无输出）
- [x] 6.2 分支 `feature/reuse-sse-line-buffer`，按「用例 + 实现」与「基准 + 实测记录」
      分成两次提交（均在有单元测试之后）
- [x] 6.3 提交完成；合并回 `sts/1.3.x-LocalMode` 与推送由交付步骤在 verify 通过后执行
      （本工作树的基线分支是 `sts/1.3.x-LocalMode`，且该分支已在主工作树检出；合并留给用户确认）
