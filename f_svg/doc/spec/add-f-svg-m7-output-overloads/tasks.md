# 任务：add-f-svg-m7-output-overloads

> 严格 TDD：先写失败用例并确认失败原因正确，再写最小实现。既有 1226 条用例零改动。
> 只改 M7 新增文件 `SvgAuthoringBuilder.cj` 与 `SvgBuilderM7_test.cj`。

## 1. 准备

- [x] 1.1 确认 `git status --short` 为空，`cjpm test` 基线 1226 / 1226 全绿

## 2. `write(OutputStream)`

- [x] 2.1 先写 `SvgBuilderM7_test.writeOutputStreamMatchesString`：以 `ByteBuffer` 作为 `OutputStream` 调用 `write`，断言 `buffer.bytes()` 与 `toSvgString()` 逐字节一致；观察 Red（方法不存在）
- [x] 2.2 实现 `write(output: OutputStream)`：`SvgWriter(output)` + `write(document())` + `flush()`；转绿

## 3. `save(File)`

- [x] 3.1 先写 `SvgBuilderM7_test.saveOpenedFile`：`File.create` 打开临时文件，调用 `save(file)`，关闭后读取内容与 `toSvgString()` 一致；观察 Red（重载不存在）
- [x] 3.2 实现 `save(file: File)`：委托 `write(file)`，异常按 `InvalidValue` 包装；补「调用后文件可由调用方继续写入/关闭」的断言；转绿

## 4. 验收与文档

- [x] 4.1 全量 `cjpm test`，确认 1228 条全绿（1226 + 2）
- [x] 4.2 `cjpm build` 确认 `f_svg` 0 warning
- [x] 4.3 更新 `README.md` / `README_en.md` 的 `save` 说明，补 `write(OutputStream)` 与 `save(File)`、所有权语义
- [x] 4.4 追加 `verification.md` 结果并勾选本文件
- [x] 4.5 `openspec validate add-f-svg-m7-output-overloads --strict` 通过
