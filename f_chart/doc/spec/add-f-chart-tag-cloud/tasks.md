## 1. 测试先行

- [x] 1.1 编写 `f_chart/src/TagCloud_test.cj`，覆盖文档示例、字号边界与其他类型拒绝
- [x] 1.2 运行 `cjpm test --no-run` 确认 `tag-cloud` 被误判为 `UnsupportedChart`

## 2. 实现

- [x] 2.1 修改 `WordCloudChart`，接受 `tag-cloud` 与 `word-cloud` 两种类型
- [x] 2.2 运行 `cjpm test --no-run` 编译

## 3. 验证

- [x] 3.1 签名 `target/release` 全部 ELF
- [x] 3.2 `cjpm test --skip-build` 全量回归通过
- [x] 3.3 `openspec validate add-f-chart-tag-cloud --strict` 通过

## 4. 归档

- [x] 4.1 归档变更并同步四件套到 `f_chart/doc/spec/`
- [x] 4.2 更新 `f_chart/README.md` 里程碑表
