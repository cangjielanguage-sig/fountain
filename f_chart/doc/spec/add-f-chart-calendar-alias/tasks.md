## 1. 测试

- [x] 1.1 编写 `f_chart/src/CalendarHeatmapAlias_test.cj`，回归文档示例与颜色分档
- [x] 1.2 运行 `cjpm test --no-run` 编译

## 2. 验证

- [x] 2.1 签名 `target/release` 全部 ELF
- [x] 2.2 `cjpm test --skip-build` 全量回归通过
- [x] 2.3 `openspec validate add-f-chart-calendar-alias --strict` 通过

## 3. 归档

- [x] 3.1 归档变更并同步四件套到 `f_chart/doc/spec/`
- [x] 3.2 更新 `f_chart/README.md` 里程碑表为 M1–M106 全部完成
