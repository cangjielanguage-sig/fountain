# add-f-svg-m4 第三轮只读终验报告

终验时间：2026-11-06
终验范围：`f_svg/doc/spec/add-f-svg-m4/verification.md` 第 7、8 节，`verification-2.md`，`openspec/changes/add-f-svg-m4/specs/*`，`openspec/specs/svg-*`，`f_svg/src`，全部 `*_test.cj`。
约束：未修改源码、未归档、未执行任何 git 写操作；只新增本报告。

## 0. 结论摘要

| 项目 | 结论 |
|---|---|
| C5-2 | **仍存在（OpenSpec delta 侧）**：实现已是 16 + 采样预算，但 `openspec/changes/add-f-svg-m4/specs/svg-security/spec.md` 仍写 `min(4096, max(区域宽, 区域高))`，且缺少预算场景 |
| NEW-C1 | **已清除**：viewBox 内容矩阵、计算样式描边/滤镜、marker 视口 `ref` 平移均已按报告修复；另有嵌套 marker 的边界缺口（WARNING） |
| W1-2 | **仍存在**：`f_svg/doc` 副本已改，`openspec/changes/add-f-svg-m4/tasks.md:145-146` 仍是 `[x]` + “保留未勾选”的矛盾说明 |
| W2-2 | **已落地**：loca 中段截断、单次渲染共享预算、`requiredExtensions=""` 均补；字体“不读文件”仍是间接证明 |
| W7-2 | **已落地**：按设备 AABB 光栅化、同元素多 quad 共用覆盖率缓冲；100 元素基准复跑 930 ms |
| W9-2 | **已落地**：中英文 README 均已补 `switch` 条件性差异 |
| NEW-W1 | **已落地（功能）**：文本 `renderBounds` 并入装饰线，紧视口用例通过；引入 2 个 WARNING（渐变 bbox、重复 layout） |
| NEW-W2 | **已落地**：`bounds` / `renderBounds` 增加可选 `styles`，渲染树传入；样式化 tspan 用例通过 |
| NEW-W3 | **部分落地**：实现、`f_svg/doc` 副本、设计文档已改；`openspec/changes` 的 `svg-text` 仍写“按字形起点取样” |
| NEW-W4 | **仍存在**：`verification.md` 的 145/12 只对 `f_svg/doc` 副本成立；权威 `openspec/changes` 统计为 144/11 |
| C1–C4 | **无回退**：C1 13 个 M1–M3 逐字节用例全绿；C2/C3/C4 代码自第二轮后未再变更，相关测试全绿 |
| M1–M3 快照 | **逐字节一致**：13 个 `.rgba` 与 `a39db449` 比较无差异，13 个 `compareSceneExact` 全部通过 |
| 性能/内存 | W7-2 相对第二轮显著改善；NEW-W1 引入每个文本一次额外 layout（WARNING），并把装饰线并入 `command.bounds`，影响 objectBoundingBox 渐变基线（WARNING） |

实跑：

- `cjpm test`：`TOTAL: 704 / PASSED: 704 / FAILED: 0`，约 11.55 s。
- `cjpm build`：成功；22 条 warning 全部来自 `f_xml/src`，`f_svg/src` 自身 0 warning。
- 基准复跑：512×512 卷积 153 ms、湍流 96 ms、20 万次 TTF 字形解析 321 ms、1000 段路径 0 ms、512×512 / 100 个旋转裁剪元素 930 ms（文档记录 948 ms，同量级）。

## 1. 逐条核验

### C5-2：实现已收紧，OpenSpec 规格未同步——仍未真正清除

实现证据：

- `f_svg/src/SvgFilterPrimitives2.cj:22-24`：`SVG_FE_MORPHOLOGY_MAX_RADIUS = 16.0`、`SVG_FE_MORPHOLOGY_SAMPLE_BUDGET = 64 * 1024 * 1024`。
- `f_svg/src/SvgFilterPrimitives2.cj:931-951`：先检查缩放半径有限且 `<= 16.5`，再计算 `width × height × (2rx+1) × (2ry+1)`，两道检查都在 `:953` 的循环前。
- `f_svg/src/SvgLimitsM4_test.cj:79-106`：32×32 + radius 20、512×512 + radius 512、256×256 + radius 16 均抛 `Limit`；64×64 + radius 4 的正常用例仍通过。
- 设计文档 `f_svg/doc/f_svg-M4设计.md:288-289` 已登记两条上限。

未清除的证据（关键）：

- `openspec/changes/add-f-svg-m4/specs/svg-security/spec.md:11` 仍为
  `feMorphology 的像素半径任一维超过 min(4096, max(区域宽, 区域高))`。
  这正是 `verification-2.md:89-92` 判定为仍可造成数小时 DoS 的旧上限。
- 同一文件的场景表仍是 11 条，缺少 `形态学运算预算超限`；`f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md:11-12,32-35` 才是修正后的 16 + 预算版本。
- `verification.md:374` 声称“`svg-security` delta 与 M4 设计上限表同步”，实际只同步了 `f_svg/doc` 副本；提交 `1a0be980` 只改了 `f_svg/doc/spec/.../svg-security/spec.md`，没有改 `openspec/changes/...`。
- 因此按 OpenSpec 流程归档时，主规格会写入已被复验否决的 4096 上限，而不是实现的 16 + 预算。C5-2 的实现已安全，但规格契约未闭环。

### NEW-C1：已清除（主路径）

证据：

- `f_svg/src/SvgRenderTree.cj:811-817` 将 `markerViewBoxMatrix(instance.marker)` 作为 `contentTransform` 传入。
- `f_svg/src/SvgRenderTree.cj:1024-1098`：
  - 子元素包围盒先乘 `contentTransform * childTransform`，再与 `0..width / 0..height` 比较；
  - `styles.get(child)` 缺失时返回 `false`（回退裁剪）；
  - `filter` / `clip-path` / `mask` / `clip` / `stroke` 均从计算样式判断；
  - 文本、未知元素返回 `false`。
- `f_svg/src/SvgRenderTree.cj:801-810` 的 `reference = contentTransform.apply(refX, refY)`，再用于 `viewportMatrix`；与 `SvgMarkerExpander.cj:393-400` 的 `markerContentMatrix` 一致。
- 用例：`SvgOverflowM4_test.cj:144-208` 覆盖 viewBox 放大、viewBox + 非零 ref、样式化描边、样式化滤镜；`:210-231` 覆盖快路径；`0da7c023` 单独补了非零 ref 用例。

结论：`verification-2.md` 4.1 指出的坐标系与呈现属性问题已修复。剩余缺口见新 WARNING（子元素自身的 `marker-*` 未计入包围盒）。

### W1-2：仍存在（OpenSpec 副本）

- `f_svg/doc/spec/add-f-svg-m4/tasks.md:145-146` 已改为“已由主流程执行核对并通过”，矛盾句已删除。
- `openspec/changes/add-f-svg-m4/tasks.md:145-146` 仍是：
  `[x] 18.6 ...（通过）`，下一行却写“该项保留未勾选”。
- 两份 `tasks.md` 已经分叉；权威变更目录仍保留矛盾说明，且 18.5 仍写 691 条（实际 704）。

### W2-2：已落地（字体用例仍为间接证明）

- `SvgTrueTypeTables_test.cj:121-133`：文件完整、只把 `loca` 声明长度从 8 改为 6；目录解析通过（length == 6），随后 `SvgTrueTypeFont.parse` 在表级检查抛 `Syntax`。这次确实触达表级读取器。
- `SvgFilterNoiseM4_test.cj:227-253`：单次 `SvgRenderer.render` 内先 `<image>` 解码 4 像素，再 `feImage` 解码另一张 4 像素，共享 `SvgDecodeBudget(4)`，断言 `Limit`。
- `SvgDocumentApiM4_test.cj:209-220`：`requiredFeatures=""`、纯空白、`systemLanguage=""`、`requiredExtensions=""` 均视为满足。
- `SvgSecurity_test.cj:185-215`：内存 `parse(Array<Byte>)` 成功、不存在路径 `load(Path)` 抛 `Syntax`、渲染只产生“未找到字体”warning。
- 注意：最后一条仍不是文件系统探针，无法在测试层面证明渲染器绝对没有尝试读文件；静态检查 `SvgTextRenderer` / `SvgRenderTree` 未发现 `File` / `readFrom`，行为正确。

### W7-2：已落地

- `f_svg/src/SvgRenderer.cj:706-735`：每个 quad 先计算设备 AABB 并夹到画布内。
- `f_svg/src/SvgRenderer.cj:737-846`：只为交集区域分配 `coverage`，每个 quad 的 mask 只分配 AABB 大小；同一指令的多个 quad 共用同一张 `coverage`，按乘法累积。
- `SvgOverflowM4_test.cj:233-249`：嵌套旋转视口共用蒙版仍按交集裁剪。
- `SvgBenchmarkM4_test.cj:82-103`：100 个旋转裁剪元素的整文档基准；本次复跑 930 ms，`perf-baseline.md:81` 记录 948 ms。
- 残余：`applyQuadCoverages` 每条指令仍会遍历一次整幅画布做交集外 alpha 清零，且没有按 `clipQuads` 身份缓存；这是 `verification.md:395` 已记录的限制，不是本轮新增回归。

### W9-2：已落地

- `f_svg/README.md:269-271`：明确两处条件性差异——marker 内容越界裁剪、`switch` 从遍历全部子元素改为选第一个满足条件者。
- `f_svg/README_en.md:263-266`：同步英文说明。

### NEW-W1：功能已落地，但引入两个副作用

功能证据：

- `f_svg/src/SvgGeometry.cj:110-132`：`renderBounds` 在文本 layout 后调用 `decorationOutline`，把装饰线路径包围盒并入 `bounds`。
- `f_svg/src/SvgRenderTree.cj:374-379`：渲染树用该 `bounds` 生成 Text 命令。
- `SvgOverflowM4_test.cj:251-276`：0..21 紧视口下，下划线在视口外被裁掉，字形仍在。

副作用（新 WARNING）：

1. **objectBoundingBox 渐变基线被装饰线扩大**：`SvgRenderer.cj:442`（fill）与 `:478`（stroke）直接用 `command.bounds` 建立渐变坐标；Text 命令的 `bounds` 现在包含下划线/上划线。带 `text-decoration` 且使用垂直/斜向 `objectBoundingBox` 渐变的文本，其字形填充/描边的渐变几何会相对 NEW-W1 之前发生变化；`SvgTextDecorationM4_test.cj:109-140` 只测了装饰线本身的逐字渐变，没有测文本 fill/stroke 的渐变。
2. **每个文本多一次 layout**：`SvgGeometry.cj:114` 调 `layout`，`:116-121` 调 `decorationOutline`，后者经 `SvgTextRenderer.cj:501` → `decorationRuns` → `:524` 再次 `layout`。即使文本没有装饰线，也固定多做一次完整排版；渲染阶段 `SvgRenderer.cj:265` 的 `outline` 与 `:288/:311` 的装饰绘制还会各做一次。单个文本从约 3 次 layout 增至约 4 次。

### NEW-W2：已落地

- `f_svg/src/SvgGeometry.cj:33-47`、`:100-134`：`bounds` / `renderBounds` 增加可选 `styles`，默认 `None`，公开调用保持兼容。
- `f_svg/src/SvgRenderTree.cj:374-379`：传入 `Some(context.styles)`。
- `SvgTextBaselineM4_test.cj:57-86`：`style="baseline-shift:super"` 的 tspan，命令 `bounds` 等于带 `styles` 的 layout 结果，且与无样式 layout 不同。

### NEW-W3：部分落地（权威 delta 未同步）

- 实现：`SvgTextRenderer.cj:514-570` 每个字形生成独立 `SvgDecorationRun`，`bounds` 为该字形装饰线包围盒；`SvgRenderer.cj:288-314` 用 run.bounds 绘制。测试 `SvgTextDecorationM4_test.cj:109-140` 断言第二个字形重新从渐变起点开始。
- `f_svg/doc/spec/add-f-svg-m4/specs/svg-text/spec.md:46`、`f_svg/doc/f_svg-M4设计.md`、`tasks.md:80` 已统一为“按字形包围盒取样”。
- **未同步**：`openspec/changes/add-f-svg-m4/specs/svg-text/spec.md:46` 仍是“渐变按字形起点取样”。按权威 delta 归档后，规格与实现/测试仍不一致。

### NEW-W4：仍存在（计数只对副本成立）

- `verification.md:383` 写“43 Requirement / 145 Scenario（`svg-security` 12 条）”。
- 实际统计：
  - `openspec/changes/add-f-svg-m4/specs/*`：43 Requirement / **144 Scenario**，`svg-security` **11** 条；
  - `f_svg/doc/spec/add-f-svg-m4/specs/*`：43 / **145**，`svg-security` **12** 条（多出“形态学运算预算超限”）。
- 因此计数更新只落在副本，没有落在 OpenSpec 变更目录；同时 `verification.md:366` 的“本轮计划内 WARNING=0”仍与第 8 节保留的已知限制并存。

### C1–C4：无回退

- **C1**：`SvgScene_test.cj:124-230` 的 `compareSceneExact` 对 13 个 M1–M3 快照逐字节比较；`exactMismatchDetected` 仍验证单字节篡改会失败。本次 704 条全绿。
- **C2**：`SvgGeometry.cj:190-194` 仍为 `scale(dpr) * viewport.matrix * ctm(element)`；`SvgGeometryApiM4_test.cj:149-205` 的 transform + viewBox meet + DPR 2 用例通过。自第二轮后 `screenCTM` 未改。
- **C3**：`SvgTrueTypeFont.cj` / `SvgTrueTypeTables.cj` 自 `cd287be0` 后无代码改动；`SvgTrueTypeM4_test.cj` 与 `SvgTrueTypeTables_test.cj` 的恶意 endPts、非法 tag、表级越界、cmap 子表长度用例全绿。
- **C4**：`SvgVectorEffect.cj:26-72` 未改；两份 `svg-value-types/spec.md:50` 都已是 `NoEffect` / `NonScalingStroke`。

### M1–M3 快照：13/13 逐字节一致

- 13 个文件：`basic`、`gradient`、`stroke`、`clip`、`text`、`animation-0/05/1`、`m3-filter`、`m3-pattern`、`m3-image`、`m3-textpath`、`m3-marker`。
- `git diff a39db449..HEAD -- <13 个 .rgba>` 为空；快照文件 mtime 仍为 2026-11-05（M3 阶段），本轮未重新生成。
- 13 个 `compareSceneExact` 用例全部 `[ PASSED ]`；当前工作区干净。

## 2. 新发现

### CRITICAL

**N1. 权威 OpenSpec delta 未同步 C5-2，归档会重新引入被否决的形态学上限**

- `openspec/changes/add-f-svg-m4/specs/svg-security/spec.md:11` 仍规定 `min(4096, max(区域宽, 区域高))`；同一文件没有“形态学运算预算超限”场景（`:26-30` 只有旧半径场景）。
- 实现与 `f_svg/doc` 副本、设计文档都已是 16 + `64 Mi` 预算；权威 delta 与实现相差 256 倍的半径上限，并且正是第二轮判定仍可造成小时级 DoS 的版本。
- 影响：本次修复的规格交付物不完整；若按 `openspec/changes` 归档，主规格会记录一个实现并不采用、且已被安全复验否决的上限。运行时当前是安全的，但变更验收不能闭环。
- 处理建议：把 `f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md:11-12,32-35` 的修改同步到 `openspec/changes/add-f-svg-m4/specs/svg-security/spec.md`，再做一次全量测试。

### WARNING

**N2. NEW-W1 把装饰线并入 `command.bounds`，改变了文本 objectBoundingBox 渐变基线**

- `SvgGeometry.cj:110-132` 的 `renderBounds` 现在把装饰线并入 `bounds`；`SvgRenderer.cj:442` / `:478` 用该 `bounds` 建立 fill/stroke 渐变。
- 带 `text-decoration` 且使用垂直/斜向 `objectBoundingBox` 渐变的文本，字形渐变几何相对 NEW-W1 之前发生变化；现有装饰线渐变用例只检查装饰线，不检查文本 fill/stroke。
- 建议：为“绘制用 bounds（不含装饰线）”和“裁剪/滤镜用 bounds（含装饰线）”拆分字段，或让 `drawPaint` 对 Text 使用字形路径包围盒。

**N3. NEW-W1 使每个文本固定多一次 layout**

- `SvgGeometry.cj:114` 先 `layout`；`:116-121` 的 `decorationOutline` 经 `SvgTextRenderer.cj:501` → `decorationRuns` → `:524` 再 `layout`，无论是否有装饰线都会执行。
- 渲染阶段 `SvgRenderer.cj:265` 的 `outline` 与 `:288/:311` 的装饰绘制仍各需 layout；单个文本约 4 次 layout，较修复前约 3 次增加 33%。
- 建议：让 `renderBounds` 复用同一次 layout 生成装饰线，或先判断当前文本是否存在装饰线再调用 `decorationOutline`；补一个多文本基准。

**N4. W1-2 / NEW-W4 只修了 `f_svg/doc` 副本，OpenSpec 变更目录仍是旧内容**

- `openspec/changes/add-f-svg-m4/tasks.md:145-146`：`[x]` 与“该项保留未勾选”并存，18.5 仍写 691 条。
- `openspec/changes/add-f-svg-m4/specs/svg-text/spec.md:46` 仍是“渐变按字形起点取样”。
- 权威 delta 统计为 144 Scenario / `svg-security` 11 条，与 `verification.md:383` 的 145/12 不一致。
- 影响：归档记录、任务勾选和计数三处过度声明；与 N1 同一根因（修改了副本而非变更目录）。

**N5. NEW-C1 的 `markerContentFits` 未计入子元素自身的 `marker-*`**

- `SvgRenderTree.cj:1024-1098` 对 `SvgShape` 只检查路径包围盒、`stroke`、`filter`、`clip-path`、`mask`、`clip`，没有检查 `marker-start` / `marker-mid` / `marker-end`。
- `SvgRenderTree.cj:731` 的 `addMarkers` 对 marker 内容里的子形状同样生效；嵌套 marker 可以绘制到子形状路径包围盒之外。
- 若子形状本身落在 marker 视口内、其嵌套 marker 越界，`markerContentFits` 会返回 `true` 并跳过父 marker 裁剪，造成与 NEW-C1 同类的“越界内容不被裁剪”。
- 建议：`markerContentFitsIn` 对带任一 `marker-*` 的形状直接返回 `false`，并补嵌套 marker 用例。

**N6. W2-2 的“字体不读文件”仍是间接证明**

- `SvgSecurity_test.cj:185-215` 只断言内存 `parse` 成功、不存在路径的 `load` 抛 `Syntax`、渲染出现“未找到字体”warning；没有文件系统探针或可注入的字体加载器，无法区分“没有读”与“尝试读失败后降级”。
- 静态检查未发现渲染链调用 `File` / `readFrom`，当前行为正确；该条属于测试强度残余，不影响功能结论。

## 3. 性能与内存

- **W7-2**：覆盖率缓冲从整幅画布（约 5 B/px）降到“所有 quad 设备 AABB 交集”（≤ 画布），单 quad 的 mask 也只分配 AABB；第二轮 4.2 的“约 6 GB 临时分配”已消除。复跑 100 元素基准 930 ms，与记录的 948 ms 同量级。
- **W7-2 残余**：`applyQuadCoverages` 每条指令仍做一次整幅画布 alpha 清零，且同一组 `clipQuads` 跨指令不缓存；这是 `verification.md:395` 已记录的限制，不是本轮新增。
- **NEW-W1**：额外 layout（N3）是唯一明确的新增 CPU 回归；装饰线路径为临时对象，未发现持续性内存增长。
- **C5-2**：上限检查在任何大缓冲分配前执行，未引入内存放大。采样预算按 `width × height × kernel` 计算，未乘 4 个通道；最坏 64 Mi 预算对应约 2.7 亿次通道采样（约数秒/原语），仍是有限值，但若文档包含大量形态学原语，累计耗时值得在安全基准中关注。
- **C3 / C2 / C4**：本轮无实现改动，未引入性能或内存变化。

## 4. 终验限制

1. worktree 的 `.git` 指向 `/storage/...` 前缀路径，默认 git 不可用；本次用 `GIT_DIR=/mnt/linux_share/.../.git/worktrees/f_svg` + `GIT_WORK_TREE` 只读查询提交与快照差异，未执行任何写操作。
2. 本机无 `openspec` CLI，`openspec validate --strict` 仍未执行；规格计数为人工 `grep` 统计。
3. 未使用堆 profiler，内存结论为静态分析 + 基准观测。
4. 本轮未修改源码、未归档、未合并分支。

## 5. 结论

- C5-2、NEW-C1 的实现修复均有效；C5-2 因权威 OpenSpec delta 未同步而不能判定为真正清除。
- W7-2、W9-2、NEW-W2 完整落地；W2-2 落地（字体用例为间接证明）；NEW-W1 功能落地但有两个副作用；W1-2、NEW-W3、NEW-W4 只落在 `f_svg/doc` 副本。
- C1–C4 无回退；M1–M3 13 个快照全部逐字节一致。

CRITICAL=1
