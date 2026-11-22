# 任务：空内容 multipart part

> TDD：先在 `f_io` 写「分隔符延迟跳过」用例（Red）→ 改 `read` 的跳过时机（Green）→ 再用 `f_http` 空 part 套件验收（parser 不改）。
> 只改 `f_io` 的跳过时机；`f_http` 生产代码 0 改动，公开 API 0 变化。

## 1. 现状与根因固化

- [x] 1.1 探针确认：空 part 的 header 读取恰好结束在 `sectionEnd`，`read` 当次吞掉分隔符；六种形状（单独/首/中/尾/超窗口前后/半窗附近）全部失败（验证：临时用例逐个复现，运行后删除）
- [x] 1.2 确认 `end > 0` 的零长度分支在分隔符未被吞掉时正确工作（验证：`indexOf` 返回 `offset` 时 `buf.size == 0`，`read` 返回 0 且 `partEnd` 为真）
- [x] 1.3 确认 `RotatableBuffer` 在本仓库仅被 `f_http.MultipartFormDataParser` 使用（验证：`rg "RotatableBuffer" --glob '*.cj'` 只命中 f_http/f_io）

## 2. f_io：延迟跳过语义（Red → Green）

- [x] 2.1 Red：新增 `readStopsAtSectionEnd`——section 内容 3 B、请求 8 B，首次 `read` 返回 3 且 `offset` 停在 `sectionEnd`，`indexOf(分隔符)` 仍返回该位置（验证：旧实现下失败，`cjpm test --filter '*RotatableBufferTest*'`）
- [x] 2.2 Red：新增 `nextReadSkipsSeparator`——第二次 `read` 返回下一 section 的前若干字节，且不含分隔符（验证：旧实现下内容错位）
- [x] 2.3 Red：新增 `separatorAcrossHalfWindow`——`halfBufferSize: 8`，分隔符跨半窗，第二次 `read` 内容逐字节正确（验证：旧实现下失败）
- [x] 2.4 Red：新增 `threeSectionsReadSequentially`——连续 3 个 section 逐段读，最后再 `read` 返回 0（验证：旧实现下时序不符）
- [x] 2.5 Green：`read` 入口增加 `offset == sectionEnd` 的跳过逻辑（含跨半窗旋转），删除收尾的两个 `sectionEnd` 分支（验证：2.1–2.4 转绿）
- [x] 2.6 `cd f_io && cjpm test` 全绿（既有 33 + 新增 4 = 37）（验证：Summary 显示 PASSED 37 / FAILED 0）

## 3. f_http：循环退出与空 part 验收

- [x] 3.1 流式文本与落盘文件循环改用 `partEnd || len < buf.size` 退出；文件分支每次写 `buf[0 .. len]`（验证：8192 B 文本与两份落盘文件用例不再把 `--\r\n` 计入内容）
- [x] 3.2 新增 `f_http/src/MultipartEmptyPart_test.cj` 辅助：payload 构造、tuples 取值、文件读取（验证：文件可编译，`cjpm test` 能发现用例）
- [x] 3.3 用例：单独空字段；空字段在首/中/尾；连续两个空字段（验证：值长度为 0，相邻字段逐字符正确）
- [x] 3.4 用例：空字段紧邻超窗口字段（前/后）；空字段后接多文件（验证：超窗口字段长度正确，文件内容逐字节正确）
- [x] 3.5 用例：空文件（`filename` + 0 B）的 `size == 0` 与 `bytes()` 为空（验证：不抛 `FSException`）
- [x] 3.6 删除 `MultipartFormDataParser_test.cj` 中两处「空 part 已知缺陷」注释（验证：`rg "已知缺陷|TODO\(缺陷\)" f_http/src` 无命中）
- [x] 3.7 `cd f_http && cjpm test` 全绿（原 26 + 新增 9）（验证：Summary FAILED 0、ERROR 0，新增用例全 PASSED）

## 4. 回归与契约

- [x] 4.1 `cd f_io && cjpm test`、`cd f_http && cjpm test` 连续两次全绿（验证：无偶发失败）
- [x] 4.2 非空 part 行为不变：既有 26 条 multipart 用例全通过，异常类型不变（验证：`testMissingLeadingBoundary` / `testMissingClosingBoundary` / `testUnsupportedMediaType` 仍抛原异常）
- [x] 4.3 `git diff` 中 `RotatableBuffer.read` 签名与返回元组、`f_http` 生产代码均无 `public` 变化（验证：`git diff -- f_http/src f_io/src | rg "^[+-].*public"` 只命中测试类）

## 5. 产物与提交

- [x] 5.1 镜像 `openspec/changes/fix-multipart-empty-part/` 到 `f_io/doc/spec/fix-multipart-empty-part/`，两份逐文件一致（验证：`diff -r` 无输出）
- [x] 5.2 `openspec validate fix-multipart-empty-part --strict` 通过（验证：输出 `is valid`）
- [x] 5.3 提交到 `fix/multipart-empty-part`，提交信息说明「延迟跳过分隔符」（验证：`git log -1 --stat` 只含预期文件）

## Workflow follow-up

- 推送 `fix/multipart-empty-part`，合并回 `sts/1.3.x-LocalMode`，合并后再跑 `f_io` / `f_http` 回归。
- 执行 `opsx:verify`，通过后 `opsx:archive` 并同步主规格。
