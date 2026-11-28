# f_svg 模块审查报告（模块第 3/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 20 个文件，全部是 `doc/spec/add-f-svg-m2`、`add-f-svg-m3` 下的 `.md`）
- **本部分范围**：`files/f_svg.part3.txt` 全部 20 行（M2 的 tasks / verification，M3 的 design / proposal / 三份 fix-plan / 11 份 spec / tasks / verification-2）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 所有问题来源记「存量」
- **审查重点**：f_svg 专项中的解析/渲染契约边界，在本部分的落点是「规格承诺 vs 实现」「验收 Scenario 是否可执行」「审计链是否可复现」；本部分不含源码，性能与内存结论只做交叉核对
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `f_svg_v2.md`）

> 说明：本部分 20 个文件全是规格 / 任务 / 校验文档，`review-checklist` §1/§2 的符号级机械检查按「文档引用的文件与公开符号」执行（逐个在 `f_svg/src`、`f_svg/testdata` 验证存在性与签名），函数体级死代码与重复逻辑由本模块的源码部分负责。

## 发现

### [一般][存量] `svg-png` 的 Paeth Scenario 期望值算错（预测器取左，不是取上）

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-png/spec.md:73-76`（`#### Scenario: Paeth 行`）；实现对照 `f_svg/src/SvgPngDecoder.cj:454-476`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例不能用 / 文档承诺与实现相反」+ §11「契约与实现不符」
- **证据**：静态确定 —— Paeth 预测器 `p = a + b - c`，取 `|p-a|`、`|p-b|`、`|p-c|` 最小者。代入 Scenario 的 `left=10, up=20, upLeft=30`：`p = 0`，`pa=10 < pb=20 < pc=30` → 选 **左**，重建值应为 `原始值 + 10`。实现 `SvgPngDecoder.cj:454-476` 正是标准写法（`estimate = left + up - upLeft`，先比 `distanceLeft`）
- **描述**：Scenario 写「重建值等于 `原始值 + 20`（Paeth 选择上方）」，与算法和本仓实现都相反。这是 `svg-png` 里唯一一条逐字节的预测器验收口径：照它补用例必然失败，反过来也可能把错误实现验收通过
- **建议**：改为「选左，重建值 = 原始值 + 10」；若要覆盖「选上 / 选左上」分支，另给两组数值（如 `left=20, up=10, upLeft=30` 选上；`left=30, up=20, upLeft=10` 选左上），并注明 `a / b / c` 的对应关系

### [一般][存量] `svg-png` 把「解压字节数 = height × (1 + rowBytes)」写成全局校验，与同文件 Adam7 要求冲突

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-png/spec.md:92`（校验清单第 6 条）；冲突条款 `:69-71`；实现 `f_svg/src/SvgPngDecoder.cj:143-144`（非交错）与 `:183-184`（Adam7 逐 pass 求和）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」+ 规格内部自相矛盾
- **证据**：静态确定 —— 交错图像的解压流是 7 个 pass 各自 `passHeight × (1 + passRowBytes)` 之和，不等于整幅 `height × (1 + rowBytes)`；实现明确分两条路径计算 `expected`，与 Adam7 条款一致、与第 6 条不一致
- **描述**：按 `:92` 逐字验收会把**所有合法交错 PNG** 判为结构错误（`Syntax`），直接与 `:69-71`、`:78-82` 的 Scenario 对立
- **建议**：`:92` 拆成两条——非交错用 `height × (1 + rowBytes)`；Adam7 用「各 pass `passHeight × (1 + passRowBytes)` 之和」，并说明两式都在解压上限内比较

### [一般][存量] `svg-marker` 缺省值 Scenario 与自身 `?SvgLength` 类型、C7 决策及实现三方相反

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-marker/spec.md:18-21`（`Scenario: 缺省值`）；类型声明 `:9-11`；决策 `f_svg/doc/spec/add-f-svg-m3/fix-plan.md:81-87`（C7）；实现 `f_svg/src/SvgMarker.cj:151-185` 与 `f_svg/src/SvgMarkerExpander.cj:347-353`（`?? SvgLength(3.0)` / `?? SvgLength(0.0)`）
- **来源**：存量（快照模式无基线；`verification-2.md:70-73` 已记录该冲突的处理方式）
- **判据**：review-checklist §13「API / 默认值与源码不符」+ §11「契约与实现不符」
- **证据**：静态确定 —— Requirement 把四个属性定为 `?SvgLength`，「缺省 0 / 3」只能是使用处语义；Scenario 却断言解析后 `markerWidth == 3`、`refX == 0`。C7 明确要求「既有测试改为断言『缺失为 None、读取默认值走使用处』」，`verification-2.md:73` 记录 `SvgMarker_test.typeAndDefaults` 正是按 `None` 断言
- **描述**：同一份规格里「可为空」与「缺省 3/0」并列，Scenario 又用属性相等表达有效缺省值。照 Scenario 写用例必失败；照 Scenario 改实现则要破坏 C7 定下的公开契约（无法区分「缺失」与「显式 0」）
- **建议**：Scenario 拆两段——「属性读取为 `None`」+「渲染时按 `refX=0`、`refY=0`、`markerWidth=3`、`markerHeight=3` 生效」；Requirement `:9-11` 补一句「缺省值指使用处兜底值，属性本身保持 `None`」

### [一般][存量] `svg-filter` 平铺 Scenario 的「四角像素」断言在 2×2 tile / 6×6 区域下数学不成立

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-filter/spec.md:149-152`；周期定义 `:142`
- **来源**：存量
- **判据**：review-checklist §13「验收口径不成立」
- **证据**：静态确定 —— 周期 2 平铺到 6×6 时，四角坐标 `(0,0)`、`(5,0)`、`(0,5)`、`(5,5)` 对应 tile 相位 `(0,0)`、`(1,0)`、`(0,1)`、`(1,1)`，只有左上角与输入 `(0,0)` 同相位（`5 mod 2 = 1`）
- **描述**：断言只有输入四像素同色时才成立，而四像素同色的 tile 又无法区分「正确平铺」与「整块常量填充」，该 Scenario 既写错期望值又失去判别力。`fix-plan-2.md:57-62`（N3：4×4 输入、仅左上 2×2 不透明、断言周期为 4）才是能证伪的写法
- **建议**：改为「2×2 四色 tile，断言 `pixel(x,y) == pixel(x mod 2, y mod 2)` 对全部 36 像素成立」，或把区域改为 4×4 后逐点比对四相位

### [轻微][存量] `svg-security` 的「每条 warning SHALL 含可定位信息」未被滤镜链满足

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-security/spec.md:102`；反例 `f_svg/src/SvgFilterRenderer.cj:312`（`feGaussianBlur 的 stdDeviation 含负值，按 0 处理`）、`f_svg/src/SvgFilterRenderer.cj:345`（`feTile 的输入为空，输出透明`）、`f_svg/src/SvgFilterPrimitives.cj:352,357,364,369`（`feColorMatrix … 按直通处理`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档承诺与实现不一致」，属可审计性契约
- **证据**：静态确定 —— 上述 warning 只有原语名或数值，没有元素路径（`/svg[1]/...`）、`id` 或属性名；同文件 `:121` 的区域告警带 `元素「${filter.tag}」`，说明渲染器并非一律无定位信息，是原语分支漏加
- **描述**：条款写成对全部 warning 的绝对要求，而滤镜原语分支是 M3 新代码；调用方拿到 `SvgRenderer.warnings` 后无法定位到具体元素
- **建议**：要么把 `:102` 收窄为「按告警清单逐项要求定位信息」并列出例外，要么在 `runChain` / `apply` 统一给 warning 加 `filter` 元素路径前缀

### [轻微][存量] `stdDeviation` 负值条款在一个 SHALL 里给了两种互斥行为

- **位置**：`f_svg/doc/spec/add-f-svg-m3/specs/svg-value-types/spec.md:50`；消歧 Scenario `:70-73`；实现 `f_svg/src/SvgFilterRenderer.cj:311-314`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `:50` 写「负数 SHALL 取绝对值**或**回退为 0，并记 warning」，两种行为对 `stdDeviation="-1"` 给出不同像素结果（模糊半径 1 vs 不模糊）；`:72` 的 Scenario 定为「按 0 处理」，实现与 Scenario 一致（`max(0.0, sigma)`）
- **描述**：带「或」的 SHALL 等于没有约束；只读 Requirement 的实现者可能实现取绝对值，与 Scenario、实现、快照断言全部冲突
- **建议**：删除「取绝对值或」，直接写「负数 SHALL 按 0 处理并记 warning」

### [轻微][存量] 三份 fix-plan 引用的 `verify-report*.md` 均不存在，复验结论之间也没有前向指针

- **位置**：`f_svg/doc/spec/add-f-svg-m3/fix-plan.md:3`、`fix-plan-2.md:3`、`fix-plan-3.md:3`；对照 `verification-2.md:139-145`（结论 `CRITICAL=2`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：静态确定 —— `find f_svg -iname "verify-report*"` 只命中 `add-f-svg-m6/verify-report{,-2,-3}.md` 与 `add-f-svg-m7/verify-report.md`；m3 目录下实际为 `verification.md`、`verification-2.md`、`verification-3.md`。`verification-2.md` 文首文末都未指向 `verification-3.md`，而 `fix-plan-3.md:3` 已按「CRITICAL=0」继续
- **描述**：修复计划的输入（CRITICAL 7 / WARNING 22、CRITICAL 2 / WARNING 5 等分级）无对应报告可查，第二轮与第三轮结论之间没有链接，第三方复核只能猜「哪份是最终裁定」
- **建议**：三处引用改成实际文件名；`verification-2.md` 顶部加一行「已被 `verification-3.md` 取代（CRITICAL=0）」

### [轻微][存量] `tasks.md` 对开发分支的约定自相矛盾

- **位置**：`f_svg/doc/spec/add-f-svg-m3/tasks.md:4`（「全部工作位于 `feature/f-svg-m3` 分支」）vs `:9`（「从当前 `f_svg` 工作分支切出」）vs `:183`（15.9「在 `feature/f_svg` 上分阶段提交（M3 与 M1/M2 同分支，无需额外合并）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「结论相反」
- **证据**：静态确定 —— 同一文件给出两种不兼容的执行方式（独立特性分支 vs 直接在 `feature/f_svg` 提交），首段规则与实际交付路径相反
- **描述**：M2 的 `tasks.md:4` 是同一模板，M3 复制后未改首段；按 `:4` 复核提交记录会误判「未按规范分支开发」
- **建议**：`:4` 改为 `feature/f_svg`，或删掉分支条款只保留「每阶段独立提交」

### [轻微][存量] M3 规格没有单一事实源：归档未完成、复核对象路径已消失，且同名 Requirement 在 m3 / m6 两份副本中已给出相反结论

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m3/tasks.md:184`（`- [ ] 15.10 归档本变更`，全文件唯一未勾选项）
  - `f_svg/doc/spec/add-f-svg-m3/verification-2.md:3`（复核对象写作 `openspec/changes/add-f-svg-m3/specs/*`、`openspec/specs/svg-*`）
  - `f_svg/doc/spec/add-f-svg-m3/fix-plan-2.md:80`（引用 `openspec/changes/add-f-svg-m3/specs/svg-render-pipeline/spec.md`）
  - 冲突面：`f_svg/doc/spec/add-f-svg-m3/specs/svg-security/spec.md:40-43`（`begin="click"` 动画「被忽略并记 warning」）vs `f_svg/doc/spec/add-f-svg-m6/specs/svg-security/spec.md:46-47`（「动画不活动，`fireEvent` 才触发」）
  - `f_svg/doc/spec/add-f-svg-m3/verification-2.md:90`（称 `svg-render-pipeline/spec.md:19`/`:34` 仍只写「透明占位」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移 / 路径失效」+ §2「跨文件同语义规格副本」+ §14.1「规格未合并、索引未登记」
- **证据**：静态确定 ——
  1. `openspec/changes/` 只有 `add-f-a2a`；`openspec/changes/archive/` 只有 5 个 `2026-11-20-fix-*`；`openspec/specs/` 只有 5 个非 svg capability，**没有任何 `svg-*`**，上述两条复核对象路径全部不存在；
  2. 实现已按 m6 语义落地：`f_svg/src/SvgTimeline.cj:366` 提供 `public func fireEvent(animationId, event)`，`SvgAnimationControlM6_test.cj:93-115` 直接调用；m3 副本的「忽略并 warning」与当前行为不符；
  3. 两份 `svg-security/spec.md` 是同一 Requirement 集合的两个演进版本（m6 在 m3 文本上追加 provider 段落并改写事件语义），仓内无任何「以哪份为准」的声明；
  4. `verification-2.md:90` 的 W14 结论与本目录副本不符：`svg-render-pipeline/spec.md:19`/`:34` **已含**「设置 `SvgRenderOptions.background` 时按 M2 用背景色填充占位」，说明双副本在复核时已漂移；
  5. 同一副本的闭集清单也已过期：`svg-document-model/spec.md:33` 的「8 种 `fe*`」不含实现里已有的 `SvgFeDropShadow`（`f_svg/src/SvgFilterPrimitive.cj:300`、`f_svg/src/SvgTag.cj:43`）；
  6. 同类问题在 M2 已被记录且未收口：`add-f-svg-m2/verification.md:247-251`（W16 重复规格目录）、`:262`（SUGGESTION 6 要求统一单一事实源）。
- **描述**：每个里程碑各自维护一份「全量 Requirement 文本」，增量从未合并到主规格，归档任务也未执行。后果：(a) 同一 Requirement 有两套冲突验收口径，结论取决于读哪份；(b) 复核报告的输入不可达，`verification-2.md` 声明的对照范围无法复现；(c) `tasks.md:13.1`/`15.7` 把「按 `verification.md` §2.2 判定列记录」当作收口依据，而该判定列本身是在无主规格的前提下产生的
- **建议**：选定唯一事实源（建议 `openspec/specs/svg-*`，把 m3 的 ADDED/MODIFIED 合并进去），其余副本顶部加一句 supersede 指向；把 `verification-2.md:3`、`fix-plan-2.md:80` 的路径改为实际存在的位置；`tasks.md:15.10` 要么执行归档，要么改成显式「不归档，规格已合并到 X」

### [轻微][存量] `add-f-svg-m2/verification.md` 开头的「当前状态」与正文结论矛盾且已过期

- **位置**：`f_svg/doc/spec/add-f-svg-m2/verification.md:6`（`cjpm test 341/341`、`CRITICAL = 0`）vs `:9`（`330 / 330`）vs `:328`（`341 / 341`）vs `:334`（第二轮又新增 `N1–N3（CRITICAL）`）vs `:348,363`（最终 `346`、`348 / 348`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 结论相反」
- **证据**：静态确定 —— 同一 §0 内 341 与 330 并存；§0 宣称 `CRITICAL = 0`，而 §7 记录第一轮之后又发现 3 个 CRITICAL；最终数字 348 只出现在文末
- **描述**：这份 366 行报告是「归档后校验」入口，读者通常只读 §0，会误判 M2 的最终质量门
- **建议**：§0 改为「最终状态：348/348，CRITICAL=0（含第二轮 N1–N3、第三轮 W1–W2 的修复）」，历史数字移入对应小节

### [轻微][存量] 「圆 vs 4× 超采样差 ≤ 2/255」旧判据仍留在任务表与设计文档

- **位置**：`f_svg/doc/spec/add-f-svg-m3/tasks.md:146`（12.2，已勾选）、`f_svg/doc/spec/add-f-svg-m3/design.md:206`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `specs/svg-rasterization/spec.md:53` 明确「4× 点采样自身的量化误差可达约 `15/255`，不得作为 `2/255` 的判据」，`fix-plan-2.md:32-33` 也要求基准改为 64×；两处旧表述未随 spec 同步
- **描述**：任务记录声称的验收标准比现行规格松 7 倍以上，按任务表复核会得出「已达标」的错误结论
- **建议**：`tasks.md:12.2` 改为「圆对 64× 参考图逐像素 ≤ 2/255」，`design.md:206` 同步；若要保留历史，标注「已被 fix-plan-2 C6 取代」

## 优化可行性方案

无。本部分 20 个文件全部是规格 / 任务 / 校验文档，不含可测量的 CPU 或堆内存执行路径，本轮不对任何实现提出性能或内存改造建议（§7 / §8 计 0）。

## 待验证假设

无。本部分没有性能 / 内存对象，也没有需要补测才能成立的猜测；文档侧的 11 条结论均已用「文件行号 + 源码行号 + 全文检索 + 两副本 diff」静态取证，无需补数据。

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_svg.part3.txt` 一一对应（20 行 → 20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/doc/spec/add-f-svg-m2/tasks.md` | .md | ✅ | 157 项全勾；16.7 已改为指向 verification / fix-plan |
| 2 | `f_svg/doc/spec/add-f-svg-m2/verification.md` | .md | ✅ | 见发现「§0 摘要过期」；C1–C9 / W* / N* 结论抽查与现行代码一致 |
| 3 | `f_svg/doc/spec/add-f-svg-m3/design.md` | .md | ✅ | D1–D13 抽查一致（D8 gzip、D10 marker、D11 有符号面积均落地）；见发现「4× 判据残留」 |
| 4 | `f_svg/doc/spec/add-f-svg-m3/fix-plan-2.md` | .md | ✅ | 见发现「verify-report 死引用」「`fix-plan-2.md:80` 路径失效」「4× 判据」 |
| 5 | `f_svg/doc/spec/add-f-svg-m3/fix-plan-3.md` | .md | ✅ | 见发现「verify-report 死引用」 |
| 6 | `f_svg/doc/spec/add-f-svg-m3/fix-plan.md` | .md | ✅ | 见发现「verify-report 死引用」「marker 缺省值（C7）」；W6/W8 等「记录不改」与现状一致 |
| 7 | `f_svg/doc/spec/add-f-svg-m3/proposal.md` | .md | ✅ | 文件清单、spec 影响面与实际目录一致；348 用例基线与 design / tasks 一致 |
| 8 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-css/spec.md` | .md | ✅ | `image-rendering` 四值与 `SvgImageRendering` 枚举（`src/SvgImageResource.cj:22-26`）一致 |
| 9 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-document-model/spec.md` | .md | ✅ | `parseAuto` / `parseGzip` / `writeGzip` 均存在；`:33` 的 8 种 fe* 闭集已过期（见归档/单一事实源条目） |
| 10 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-filter/spec.md` | .md | ✅ | 缺省区域与 units 自洽；见发现「平铺四角断言」 |
| 11 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-marker/spec.md` | .md | ✅ | 见发现「缺省值 Scenario」 |
| 12 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-paint-and-clip/spec.md` | .md | ✅ | tile 4 Mi / 深度 64 与 svg-security 表一致；`x/y` 未写成属性相等，无同类矛盾 |
| 13 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-png/spec.md` | .md | ✅ | 见发现「Paeth Scenario」「Adam7 解压尺寸」 |
| 14 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-rasterization/spec.md` | .md | ✅ | 字段顺序与默认值与 `src/SvgBitmap.cj:198-241` 逐项一致；`:53` 的 64× 判据未同步到 tasks / design |
| 15 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-render-pipeline/spec.md` | .md | ✅ | `:19`/`:34` 已含 background 占位语义（与 verification-2 W14 的描述不符，见单一事实源条目） |
| 16 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-security/spec.md` | .md | ✅ | 见发现「warning 定位性」「m3/m6 事件动画结论相反」；上限表 7 项与 png / filter / marker 三份 spec 数值一致 |
| 17 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-text/spec.md` | .md | ✅ | `path` 优先于 `href` 与 design D9 / 假设 3 一致；rotate 语义自洽 |
| 18 | `f_svg/doc/spec/add-f-svg-m3/specs/svg-value-types/spec.md` | .md | ✅ | 七个新枚举均在源码存在；见发现「stdDeviation 二义」 |
| 19 | `f_svg/doc/spec/add-f-svg-m3/tasks.md` | .md | ✅ | 133/134 勾选；见发现「分支矛盾」「15.10 未勾选」「4× 判据残留」 |
| 20 | `f_svg/doc/spec/add-f-svg-m3/verification-2.md` | .md | ✅ | §0 / §2 / §5 计数互相一致；`CRITICAL=2` 已被第三轮取代且无前向指针 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完（逐行对齐 `files/f_svg.part3.txt`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性与契约 5 条：Paeth 期望值、Adam7 尺寸、marker 缺省值、feTile 四角、filter warning 定位性；本部分无源码，语言特性与分层不适用，可读性并入各条建议 |
| §1 死代码 | 0 | 无源码；改为对文档引用的文件与公开符号做存在性机械核对：tasks 1.4 的 13 个 `.cj`、14 个测试类、5 组 `testdata/render/m3-*`、`allowDataImages`、`maxDecompressedBytes`、`SvgRenderOptions` 九个 M3 字段、7 个新枚举、8 个 `SvgFe*` + `SvgFeMergeNode` 全部命中；无「引用了不存在的代码符号」（文档文件名偏差已并入单一事实源条目） |
| §2 重复逻辑 | 1 | 对 m3 与 m6 的同名 spec 逐文件 `diff`：`svg-security`、`svg-render-pipeline` 等是同一 Requirement 集合的多份演进副本且语义已分叉，合并为「单一事实源」一条；m3 内部 11 份 spec 按主题比对，无同一契约写两遍 |
| §3 空实现 | 0 | 20 个文件无空章节；「记录不改」的 W6/W8/W15/W16/S1–S6 均写明取舍；`tasks.md:184` 的未勾选项不是空实现，按 §14 计入 |
| §4 栈溢出 | 0 | 文档不执行递归；文中所有深度 64 条款（use / 嵌套 svg / 渐变 / pattern / marker / mpath）都有对应实现与 guard，属源码部分 |
| §5 OOM | 0 | 文档只声明上限表（16 Mi / 64 Mi / 4 Mi / 32 MiB / 64 MiB / maxPixels）；7 项数值与 png / pattern / gzip / image 各处一致，无推导错误 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，`doc/perf-baseline.md` 不在本清单；不产生热点结论 |
| §6.2 大粒度锁 | 0 | 纯文档，无锁描述 |
| §6.3 并发串行 | 0 | 纯文档，无并发描述 |
| §6.4 低效算法 | 0 | `svg-rasterization/spec.md:76-83` 已把 8×8 / 子扫描线收敛为「有符号面积」，规格侧定义正确；实现落差属源码部分 |
| §7 降堆内存方案 | 0 | 文档不持有对象，无可量化峰值 |
| §8 降 CPU 方案 | 0 | 文档只承载「参考、非门禁」的基准口径，无耗时数据 |
| §9 local mode 可行性 | 0 | 纯文档，无函数内临时对象；无可证明的峰值收益 |
| §11 现有代码的 BUG（存量） | 4 | 四条与实现冲突（Paeth、Adam7、marker 缺省值、warning 定位性），均给出文档行号 + 代码行号；其余为文档内部或文档之间的不一致（§13） |
| §12 并发安全与锁粒度 | 0 | 纯文档；`SvgRenderGuard` 的可重入与异常安全只在 `verification-2.md:116-118` 记录过，属源码面 |
| §14 功能完备性与 README 覆盖 | 1 | 仅「M3 规格未合并、归档任务未勾选、`openspec` 侧无 `svg-*`」一条；README 覆盖需以 `README.md` 为基准，属本模块 README 部分 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.md` 全部读完，无缺 |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 11 条（0 严重 / 4 一般 / 7 轻微），是否纳入修复待用户决定。

## 总评

本部分 20 个文件是 M2/M3 的规格与验收档案，不是运行时代码，因此没有注入、逃逸、OOM 一类执行风险；真正的风险是**验收口径失真**与**事实源分散**。

先说好的部分：M3 的可执行承诺绝大多数与实现一致——7 项资源上限逐项在代码中命中且都在分配前判定，7 个新枚举、`parseAuto` / `parseGzip` / `writeGzip`、`linearRGB` 双次转换、`Analytic` 逐像素列有符号面积、`feMerge` 缺省输入、`image` 的 background 占位语义、8 种原语均在 `src/` 有对应实现且行号可指，`SvgRenderGuard` 也已在公开入口自建。文档的自省程度同样少见：`verification-2.md` 主动记录了自己没修干净的 C4/C6，并把文档一致性单列成一条 WARNING 级别的发现。

问题分两类。第一类是**规格写错而代码是对的**：Paeth Scenario 把预测器算反、Adam7 的行长校验与自身条款互斥、marker 缺省值 Scenario 与 `?SvgLength` 契约相反、feTile 的「四角」断言数学不成立、`filter` 原语 warning 缺定位信息。这五条都是逐字节或可审计级别的验收依据，必须改文档：不改，下一轮按文档补用例就会写出失败断言，或把错误实现验收通过。第二类是**审计链**：`verify-report*.md` 死引用、`tasks.md` 分支约定自相矛盾、M3 归档任务未执行而 `doc/spec` 副本仍以「现行契约」口吻陈述（`feDropShadow` 已扩、`SvgRenderOptions` 已扩、m6 的 `begin="click"` 语义已变），以及 M2 报告开头的过期摘要。

阻塞项：无。四条「一般」不阻塞代码功能，但建议在下一里程碑开始前用一个纯文档 PR 修掉；「M3 规格以哪份为唯一事实源」需要用户拍板，审查方不代为决定。
