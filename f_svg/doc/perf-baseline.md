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
- 同一环境的全量 `cjpm test --skip-build` 约 9.4 s（512 条用例）。

## M4 滤镜、TTF 与路径测量（参考值，非门禁）

- 环境：Linux x86_64，Cangjie SDK 1.3.0，`cjpm test`，`-O2`，单次运行、含噪声。
- 基准测试：`SvgBenchmarkM4_test.cj` 的 `m4Benchmarks`，只记录不门禁。
- 口径：单次调用，含输入缓冲构造与结果分配；数值仅用于回归对比。

| 场景 | 参数 | 单次耗时 |
|---|---|---|
| 512×512 卷积 | `order=3`，锐化核，`divisor=1` | 约 151 ms |
| 512×512 湍流 | `numOctaves=2`，双频 `baseFrequency` | 约 96 ms |
| 20 万次 TTF 字形解析 | 最小 TrueType 字形，`fontSize=20` | 约 288 ms |
| 1000 段路径长度 | 1000 个 `L` 段，`tolerance=0.25` | < 1 ms |
| 512×512 / 100 个旋转裁剪元素 | 每个元素一个旋转嵌套 `svg` 视口 | 约 948 ms |

- 卷积与湍流均按滤镜区域尺寸线性增长；TTF 字形每次解析未缓存，调用方应在字体对象外自行缓存。
- 旋转裁剪的四边形蒙版只在设备 AABB 内光栅化，同一元素的多个 quad 共用交集缓冲；
  上表 100 个元素的口径为单次完整文档渲染，用于回归对比。
- 以上数值为参考、非 CI 门禁；每次复验后更新本文件，而不是写成硬断言。

## M5 快照逐字节基线（SHA-256）

- 口径：`testdata/render/*.rgba`，M1–M3 13 张（含 3 张动画帧）与 M4 4 张，共 17 张；逐字节比对容差 0。
- 用途：M5 未使用新特性的文档输出必须与 M4 逐字节一致；下表是回归基准，不随渲染结果更新。
- 采集命令：`sha256sum testdata/render/<name>.rgba`。

| 快照 | SHA-256 |
|---|---|
| animation-0 | 11d601db9988862894c32c6ada82c161abcb7acc630ef2e36abb3f22bf1d069a |
| animation-05 | f98f3a6405f31fdf7b1f7cb295197e257a1245574f7703248f2d3b192293b799 |
| animation-1 | dbcbdc0efb09a1dbc12a7b802d90952e767e3752784cdf63c2410ec7ce57e86d |
| basic | c7b1e7fbf92a755511d860c6fcbadd380e109e68c9779e4292108d150d0dd15a |
| clip | 10e28c90626551215a1acbd85cfc8f8ea392012ffdabecea08e960537db3082c |
| gradient | c9819dcb996e7b3e3790eb530f423a38b04c031806753f327d965ca825fed3b8 |
| stroke | cf26874a3fae5cb0efe6ac9d706ca3b704057190448b87c49f4a3fba1e610651 |
| text | b20ab78f251af927075c1361ba0a7a8e54afae4cd861756ff47abe78a7340bcc |
| m3-filter | 4302d98ce2e735b1646a2a2ee2a03a1148dddb27adb9f8c01c881d8197ec446a |
| m3-image | ab94d45a27672bb52d670744f49e4e17522558c606387f04b30fdeea26b3502b |
| m3-marker | ccadf9ba93553075feb4770fcaddd82fa9b6c3468c98e759e0cbb7edacea6b4b |
| m3-pattern | 7c8fe19bee3f4e0591c634fbbcfb13bb61a77b1b4a522b1cf4cdbd2fd792395d |
| m3-textpath | 0e453ccae6683b75a8a9fe27853ff235ec741f5e5c765be2d6281f3a1d450dda |
| m4-clip | 379ed1e7733f865cedd8ab91137b84accf28331c0e2252fc4907c3b4564cf1bb |
| m4-filter | 9f8f4026e00bc1422627d5de791a1db25b6226231e72127a1dd0e637128701c0 |
| m4-text | 26bc330fe963050a21955d5aa82b2944852e79634cf542a0f7049e0c7b7e65e8 |
| m4-view | f880f5614b4f2b9e8ce9bca81e1dd7856e0671f03e911a0ad55e41884b4b12be |

- 基线测试结果：`cjpm test` TOTAL 710 / PASSED 710 / FAILED 0，单次 wall 约 11.9 s（Linux x86_64，`-O2`）。
- `cjpm build`：`f_svg` 自身 0 warning（依赖模块 `f_xml` 有 22 条既有 warning，不属本模块）。

## M5 元素级 API（参考值，非门禁）

- 环境：Linux x86_64，Cangjie SDK 1.3.0，`cjpm test`，`-O2`，单次运行、含噪声。
- 场景：1000 个 `rect.a` 组成的文档（每元素宽高 5），`querySelectorAll("rect.a")` 与单个元素 `getBBox()`。
- 基准测试：`SvgPerfM5_test.cj` 的 `thousandElementQueries`。

| 操作 | 单次耗时 |
|---|---|
| `querySelectorAll("rect.a")`（1000 结果） | 约 0.9 ms |
| 单次 `getBBox()`（挂载元素，含样式树重算） | 约 51 ms |

- `getBBox` 按契约不做跨调用缓存，每次从根重算计算样式；1000 元素文档下耗时随之线性增长。
- 以上数值为参考、非 CI 门禁。

## M6 命中查询与交互（参考值，非门禁）

- 环境：Linux x86_64，Cangjie SDK 1.3.0，`cjpm test`，`-O2`，单次运行、含噪声。
- 场景：1000 个 `rect`（5×5）文档，`getIntersectionList` 查询 50×50 区域。
- 基准测试：`SvgDomApiM6_test.cj` 的 `largeDocumentPerformance`（CI 上限 5 s，仅防退化）。

| 操作 | 单次耗时 |
|---|---|
| `getIntersectionList`（1000 元素） | 约 60–120 ms |

- 每次查询重算一次样式树；不做跨调用缓存，与 M5 `getBBox` 口径一致。
- 命中测试 `SvgHitTest` 同样每次重算样式树；`maxElements` 在递归前累计并抛 `Limit`。

## Local mode 试点：解析覆盖率累加器（参考值，非门禁）

- 环境：Linux aarch64，Cangjie SDK `1.3.0-alpha.20261118001016`，`-O2`，单次渲染，含噪声。
- 场景：`fill=red` 的圆（半径随画布约 0.4 倍宽），`antiAlias = Analytic`、`samplesPerPixel = 1`；只计 `SvgRenderer.render`，不含解析。
- 口径：耗时与 peak RSS 来自关闭采样的独立进程；`local 峰值` / `堆峰值` 来自同一几何下每 1 ms 采样 `getAllocatedLocalObjectSize()` / `getAllocatedHeapSize()` 的独立进程，取过程最大值（采样本身会暂停仓颉线程，故不计入耗时）。peak RSS 取 `/proc/self/status` 的 `VmHWM`。
- 基准工程：临时 cjpm 工程以 path 依赖引用本模块，`main` 内直接调用公开 `SvgRenderer`；未写入仓库。

| 尺寸 | 累加器档位 | local 峰值 | 堆峰值 | 耗时（3 次） | peak RSS |
|---|---|---|---|---|---|
| 1024×1024 | local（8 MiB，门限内） | 8,388,816 B | 约 155–164 MB | 115 / 118 / 129 ms | 174–189 MB |
| 1024×1024 | 堆（对照） | 192 B | 约 180 MB | 128 / 136 / 147 ms | 180–200 MB |
| 2048×2048 | 堆（门限外） | 192 B | 约 256 MB | 616 / 630 / 734 ms | 约 238 MB |
| 2048×2048 | local（32 MiB，首轮档位，已弃用） | 33,554,640 B | 约 263 MB | 541 / 659 / 669 ms | 约 277 MB |
| 3840×2160 | 堆（门限外，未变） | 192 B | 约 265 MB | 1086 / 1377 / 1395 ms | 216–231 MB |

- `local 峰值` 与理论值吻合：1024² × 8 = 8 MiB；2048² 与 4K 按 8 MiB 门限走堆，只有每行 `events` 的少量字节。
- 对照行的「堆」是把门限临时置为 0 后同一份代码重跑，用来隔离「累加器放 local / 放堆」的差别；`events` 两种情况下都走 local（见 design D3）。
- 本机 1024² 档位的堆峰值与 peak RSS 均下降（约 25 MB / 15 MB）；首轮 32 MiB 档位在 2048² 的 peak RSS 反而上升约 40 MB——local region 的 32 MiB 与 GC 堆峰值叠加，而不是替换堆里的同一块内存。因此复审把门限下调到 **8 MiB**：1024² 及以下走 local，2048² 与 4K 走堆。
- 与 `cjLocalRegionMaxSize`（默认 256 MB，全线程合计）的关系：8 MiB 门限允许最多 32 个解析覆盖率渲染并发占满默认上限；需要更高并发时应调大该环境变量，或降低单次画布尺寸。
- ohos 目标不支持 `--enable-local-mode`（鸿蒙侧 SDK 报 `invalid option`），本模块在 `aarch64-linux-ohos` / `x86_64-linux-ohos` 上不构建，与 `f_base` / `f_data` 的 local-mode 基线一致。
- 以上数值为参考、非 CI 门禁；不做吞吐量承诺。逐元素等价由 `SvgAnalyticLocalMode_test.cj` 覆盖，重复渲染确定由既有 `combinedDeterminism` 覆盖。
