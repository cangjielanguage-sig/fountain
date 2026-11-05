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
