## 1. 测试先行

- [x] 1.1 编写 `f_chart/src/GaugeChart_test.cj`，覆盖色带、指针、数值文本、默认量程/角度、无阈值、越界与非法参数
- [x] 1.2 运行 `cjpm test --no-run` 确认缺少 `GaugeChart` 导致编译失败

## 2. 实现

- [x] 2.1 新建 `f_chart/src/GaugeChart.cj`，实现 `GaugeChart <: Chart`
- [x] 2.2 实现 `gaugeAngleForValue`、`gaugeArcPath` 与阈值校验
- [x] 2.3 绘制色带、指针、中心数值与指标名
- [x] 2.4 运行 `cjpm test --no-run` 编译

## 3. 验证

- [x] 3.1 签名 `target/release` 全部 ELF
- [x] 3.2 `cjpm test --skip-build` 全量回归通过
- [x] 3.3 `openspec validate add-f-chart-gauge --strict` 通过

## 4. 归档

- [x] 4.1 归档变更并同步四件套到 `f_chart/doc/spec/`
- [x] 4.2 更新 `f_chart/README.md` 里程碑表
