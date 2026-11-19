## 1. 测试先行

- [x] 1.1 编写 `f_chart/src/WordNetworkChart_test.cj`，覆盖节点/连线数量、半径映射、圆形布局、非法布局、悬空连线、重复 id 与类型
- [x] 1.2 运行 `cjpm test --no-run` 确认缺少 `WordNetworkChart` 导致编译失败

## 2. 实现

- [x] 2.1 新建 `f_chart/src/WordNetworkChart.cj`，实现 `WordNetworkChart <: Chart`
- [x] 2.2 解析 `nodes` / `links` 并校验
- [x] 2.3 实现圆形初始化与确定性力导向迭代
- [x] 2.4 绘制连线、节点与节点内标签
- [x] 2.5 运行 `cjpm test --no-run` 编译

## 3. 验证

- [x] 3.1 签名 `target/release` 全部 ELF
- [x] 3.2 `cjpm test --skip-build` 全量回归通过
- [x] 3.3 `openspec validate add-f-chart-word-network --strict` 通过

## 4. 归档

- [x] 4.1 归档变更并同步四件套到 `f_chart/doc/spec/`
- [x] 4.2 更新 `f_chart/README.md` 里程碑表
