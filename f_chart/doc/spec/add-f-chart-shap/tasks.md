## 1. 测试先行

- [x] 1.1 编写 `f_chart/src/ShapChart_test.cj`，覆盖条形数量、正负分类、排序、零基线、数值标签、空数据、缺字段与非法类型
- [x] 1.2 运行 `cjpm test --no-run` 确认缺少 `ShapChart` 导致编译失败

## 2. 实现

- [x] 2.1 新建 `f_chart/src/ShapChart.cj`，实现 `ShapChart <: Chart`
- [x] 2.2 解析 `features` 与 `series[0].data`，校验字段并稳定排序
- [x] 2.3 绘制水平条、零基线、特征名与数值标签
- [x] 2.4 运行 `cjpm test --no-run` 编译

## 3. 验证

- [x] 3.1 签名 `target/release` 全部 ELF
- [x] 3.2 `cjpm test --skip-build` 全量回归通过
- [x] 3.3 `openspec validate add-f-chart-shap --strict` 通过

## 4. 归档

- [x] 4.1 归档变更并同步四件套到 `f_chart/doc/spec/`
- [x] 4.2 更新 `f_chart/README.md` 里程碑表
