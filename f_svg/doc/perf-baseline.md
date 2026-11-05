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

- 口径：1000 条**简单类选择器**（`.c0 { ... }` … `.c999 { ... }`）× 1000 个 `rect` 元素；只统计 `SvgStyleResolver.compute(root)`，不含 CSS 文本解析与渲染。
- 基准测试：`SvgComputedStyle_test.cj` 的 `thousandByThousandBenchmark`。
- 实测：约 81 ms（单次，含 1001 个元素的计算样式构建；匹配是该区间的主体）。
- 规格目标：**匹配阶段** ≤ 20 ms。当前测量口径把级联取值与样式快照构建一并计入，因此是匹配阶段的**上界**，实测未达标：**未达成**。
- 后续优化方向：缩短右端简单选择器到规则候选的重复校验，按属性索引规则，而不是继续加大缓存。

## M2 几何包围盒（参考值）

- 口径：1000 段 `L` / `C` 混合路径，只统计 `SvgGeometry.bounds`，不含路径解析与样式计算。
- 基准测试：`SvgBenchmark_test.cj` 的 `geometryBenchmark`。
- 实测：约 1 ms；规格目标 ≤ 2 ms（单次、`-O2`）——**本次达标**。
- 该指标为参考目标、非 CI 门禁。

## M2 渲染与 PNG（参考值）

- 环境：Linux aarch64，Cangjie SDK 1.3.0，`cjpm test`，`-O2`。
- 基准测试：`SvgBenchmark_test.cj` 的 `renderBenchmarks`，只记录不门禁。
- 512×512 / 50 个半透明形状，`samplesPerPixel=2`（即 **2×2 SSAA**；规格目标按 4×4 SSAA 核算）：约 51 ms。档位不同，不能直接与 4×4 目标比较；按 2×2 记录为参考值。
- 1024×1024 线性渐变 + 圆形裁剪，`samplesPerPixel=1`：约 7569 ms。裁剪蒙版按整幅位图重绘，是当前主要瓶颈；未达设计目标 ≤200 ms。
- 1024×1024 PNG 编码：约 95 ms（设计目标 ≤100 ms，**达标**）。
- 结论：PNG 达标；渐变 + 裁剪需在 M3 引入按指令包围盒裁剪离屏层与增量覆盖率，而不是继续优化单像素路径。

> 以上 M2 数值均为参考、非门禁；每次复验后应更新本文件，而不是把实测值写成硬断言。


## M3 效果与解析 AA（参考值，非门禁）

- 环境：Linux x86_64，Cangjie SDK 1.3.0，`cjpm test`，`-O2`，单次运行、含噪声。
- 口径：`cjpm test --skip-build --filter <基准类>` 的整轮 wall clock，减去同环境空跑约 1.2 s 的进程启动后约值；只用于回归对比，不作 CI 门禁。
- 基准测试：`SvgBenchmark_test.cj` 的 `SvgBenchmarkM3Blur_test` / `SvgBenchmarkM3Pattern_test` / `SvgBenchmarkM3Analytic_test`。

| 场景 | 参数 | 整轮 wall | 约净耗时 |
|---|---|---|---|
| 512×512 高斯模糊 | `stdDeviation=8`，`samplesPerPixel=1` | 1.7 s | ~0.5 s |
| 512×512 图案平铺 | 32×32 tile，`samplesPerPixel=1` | 1.4 s | ~0.2 s |
| 1024×1024 解析 AA 圆 | `antiAlias=Analytic` | 4.2 s | ~3.0 s |

- 解析 AA 统一走逐扫描线按像素列累加覆盖（每像素行 32 条子扫描线），不再有 8×8 子采样分支；1024 画布下仍是 M3 的主要耗时项。
- 同一环境的全量 `cjpm test --skip-build` 约 9.4 s（461 条用例）。
