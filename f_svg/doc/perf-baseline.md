# f_svg 性能基准（M1，参考值）

> 只作回归参考，不作 CI 门禁。门禁是正确性与往返一致性。
> 当前实测未达到设计目标（25 ms / 20 ms），本文件不声称已达成，仅记录差距。

## 方法

- 样本：`.assets/README/module-dependencies.svg`（246,456 字节，仓库自带）。
- 环境：Linux x86_64，Cangjie SDK 1.3.0，`-O2`，`cjpm test` 默认配置。
- 计时：`MonoTime.now()` 包住 `SvgParser.parse(Path)` 与 `writeSvgString`。
- 基准测试：`f_svg/src/SvgRoundTrip_test.cj` 的 `largeSampleSmoke`，样本不存在时打印「已跳过」。

## 实测（单次，含噪声）

| 操作 | 实测 | 设计目标（1 MB 合成文档） |
|---|---|---|
| 解析 + 建模型 | 53.8 ms | ≤ 25 ms |
| 模型 → 字符串 | 24.8 ms | ≤ 20 ms |
| 峰值内存 | 未度量 | ≤ 8× 输入 |

## 说明

- 该样本为真实绘图，元素与属性密度高于设计假设的合成 1 MB 文档；目标值不按样本大小线性外推。
- 解析耗时包含 `f_xml` 建 DOM 与 `f_svg` 单遍模型构建；生成耗时包含模型 → `XmlDocument` 与 `f_xml::XmlWriter` 两次遍历。
- 若后续需要逼近目标，优先减少 `SvgValueCache` 的初始化数量与属性解析次数，而不是改 `f_xml`。

## M2 CSS 匹配（参考值）

- 样本：1000 条 `rect { fill: #010203 }` 规则 × 1000 个 `rect` 元素。
- 基准测试：`SvgComputedStyle_test.cj` 的 `thousandByThousandBenchmark`。
- 实测：约 217 ms（单次，含 1001 个元素的计算样式构建）。
- 设计目标 ≤ 20 ms：**未达成**。倒排桶对同类型规则只能全量返回，当前实际是 1M 次选择器匹配；
  后续优化方向是按属性索引规则、缩短右端简单选择器的重复校验，而不是继续加大缓存。

## M2 渲染与 PNG（参考值）

- 环境：Linux aarch64，Cangjie SDK 1.3.0，`cjpm test`，`-O2`。
- 基准测试：`SvgBenchmark_test.cj` 的 `renderBenchmarks`，只记录不门禁。
- 512×512 / 50 个半透明形状，`samplesPerPixel=2`：约 39 ms（设计目标 ≤50 ms，按 4×4 SSAA 核算，本次用 2×2）。
- 1024×1024 线性渐变 + 圆形裁剪，`samplesPerPixel=1`：约 3979 ms。裁剪蒙版按整幅位图重绘，是当前主要瓶颈；未达设计目标 ≤200 ms。
- 1024×1024 PNG 编码：约 54 ms（设计目标 ≤100 ms）。
- 结论：PNG 达标；渐变 + 裁剪需在 M3 引入按指令包围盒裁剪离屏层与增量覆盖率，而不是继续优化单像素路径。
