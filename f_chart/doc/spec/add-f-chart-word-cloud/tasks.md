## 1. 测试先行

- [x] 1.1 编写 `f_chart/src/WordCloudChart_test.cj`，覆盖词项数量、字号边界、旋转循环、颜色覆盖、空词表、非法字号/权重与类型
- [x] 1.2 运行 `cjpm test --no-run` 确认缺少 `WordCloudChart` 导致编译失败

## 2. 实现

- [x] 2.1 新建 `f_chart/src/WordCloudChart.cj`，实现 `WordCloudChart <: Chart`
- [x] 2.2 实现 `wordCloudFontSize` 开方映射与货架式布局
- [x] 2.3 绘制词项、旋转与颜色覆盖
- [x] 2.4 运行 `cjpm test --no-run` 编译

## 3. 验证

- [x] 3.1 签名 `target/release` 全部 ELF
- [x] 3.2 `cjpm test --skip-build` 全量回归通过
- [x] 3.3 `openspec validate add-f-chart-word-cloud --strict` 通过

## 4. 归档

- [x] 4.1 归档变更并同步四件套到 `f_chart/doc/spec/`
- [x] 4.2 更新 `f_chart/README.md` 里程碑表
