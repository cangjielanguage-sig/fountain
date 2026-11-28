# f_svg 模块审查报告（模块第 4/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（模块共 301 个 `.cj` + 141 个 `.md`；本部分仅 18 个 `.md`，无 `.cj`）
- **本部分范围**：`f_svg/doc/spec/add-f-svg-m3/{verification,verification-3}.md`、`f_svg/doc/spec/add-f-svg-m4/{design,proposal,tasks,fix-plan,fix-plan-2,fix-plan-3}.md`、`add-f-svg-m4/specs/*/spec.md`（10 份）
- **基线**：工作区快照（master 与 `sts/1.3.x` 同一提交 `120fd2542`，`git diff` 为空 ⇒ 所有问题来源记「存量」）
- **审查重点**：M3 终验与 M4 归档规格的正确性、规格与实现漂移、注入/转义与 XML 边界条款、上限（OOM）与递归条款是否落地、校验链计数与死引用
- **报告版本**：v1（第 4/26 部分，同日重写）。前稿已存在，本次逐条复核其结论：修正 1 处误判——`svg-geometry` 的 `screenCTM` 公式与实现**并不**一致（见 #1）；把字体文件上限从"一般缺陷"降级为健壮性缺口（#8，`svg-security:74` 已把责任划给调用方）；新增 `switch` 兼容性（#2）、基线继承性（#3）、路径段表预算（#5）、测试文件名（#9）、W17 状态（#13）五项；其余保留项均已重新取证。

> 说明：本部分文件全部为 `doc/spec/**` 的规格与验收档案，不含源码。§1/§2 的符号级机械检查按「文档声明/引用的公开符号」执行（逐个在 `src/` 验证存在性、签名与消费点），函数体级死代码与重复实现判定属于本模块其他部分。文档中的承诺一律按"对外契约"核对实现，代码行号仅作证据；`openspec/specs/svg-*` 主规格已不在仓内，因此这些 delta spec 是唯一存世的规格文本，条款漂移按可执行契约处理。

## 发现

### [一般][存量] #1 `screenCTM` 的矩阵顺序在 delta spec 与 design 里都写反了，且唯一 Scenario 用均匀缩放，天然发现不了顺序错误

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-geometry/spec.md:68`（"SHALL 等于 `ctm(element) × viewport.matrix × scale(devicePixelRatio)`"）
  - 同文件 `:70-73`（Scenario：100×100 文档、`viewBox="0 0 50 50"`、`dpr=2`、用户坐标 `(10,10)` → `(40,40)`）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:170`（同一公式）
  - 修正要求：`f_svg/doc/spec/add-f-svg-m4/fix-plan.md:20-26`（C2："当前 `ctm × viewport × scale(dpr)`；渲染器顺序为 `scale(dpr) × viewport × ctm` … 同步修正 design D9 公式"）
  - 对照实现：`f_svg/src/SvgGeometry.cj:243-257`（注释与代码均为 `scale(dpr) → viewport.matrix → ctm`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「规格与实现漂移」；§11「契约与实现不符」
- **证据**：静态确定 —— 实现 `SvgMatrix.scale(dpr,dpr).multiply(viewport.matrix).multiply(ctm(...))`，`:243` 的注释明写"与渲染器的设备矩阵顺序一致"；`fix-plan.md` C2 已判定旧顺序错误并要求改设计，`tasks.md:143`（18.4）也只声称同步了 `doc/f_svg-M4设计.md`，`design.md:170` 与本 delta spec `:68` 都还留着旧公式。
- **描述**：按文档实现，`<g transform="translate(10,10)">` + `viewBox` 缩放 + `dpr=2` 会把 `(0,0)` 映射到 `(10,10)`，渲染器实际画在 `(40,40)`；调用方用 `screenCTM` 做命中测试或坐标换算会整体错位。错误能存活，是因为 Scenario（`:70-73`）里三个因子都是均匀缩放、彼此可交换，两种顺序同为 `(40,40)`，测试与文档"互相印证"了错误的公式。
- **建议**：`spec.md:68` 与 `design.md:170` 统一改为 `scale(devicePixelRatio) × viewport.matrix × ctm(element)`；Scenario 增加带平移的非均匀用例（C2 的 `translate(10,10)` + meet + `dpr=2` → `(40,40)`，并断言无 transform 时等于 `ctm`），使顺序错误可被用例直接打死。

### [一般][存量] #2 兼容性契约声称"唯一会改变既有输出的点是 marker 裁剪"，漏掉 `switch` 由"渲染全部子元素"改为"只选第一个满足者"

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/design.md:90`（"这是 M4 唯一会改变既有输出的点：只有内容越出 marker 视口的文档受影响"）
  - 同文件 `:205`（"唯一条件性差异是越出 marker 视口的内容按 SVG 1.1 被裁剪"）
  - `f_svg/doc/spec/add-f-svg-m4/proposal.md:74-75`（兼容性段同样只写 `overflow`）
  - 对照：`f_svg/doc/spec/add-f-svg-m4/tasks.md:141`（18.2 要求 README 写入"`switch` 的条件性输出差异"）、`fix-plan-2.md:58-60`（W9-2 要求"补上『`switch` 由遍历全部子元素改为选第一个满足条件者』"）
  - 实现：`f_svg/src/SvgRenderTree.cj:771`（`SvgSwitch.select` 只分派一个子元素）；`f_svg/src/SvgTag.cj:69`（`switch` 与 `g` / `symbol` 等一起映射为 `SvgContainer`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档与实现/README 不一致」；§14.1「只做了一半的分支」；§11「契约与实现不符」
- **证据**：静态确定 —— `switch` 在 M4 之前已是已知容器（`git log -S '"switch"' -- f_svg/src/SvgTag.cj` 指向初始解析器提交 `2ead235b0`，当前 `:69` 仍把它归入容器分支），子树按普通容器全量遍历；M4 改为 `SvgSwitch.select` 只保留第一个满足条件的子元素。含多个合法分支的 `<switch>` 文档输出必然改变，与"唯一差异"直接冲突；`tasks.md:141` 与 `fix-plan-2.md` 都把这条列为需披露的输出差异。（`design.md:7` 的"新增标签前落入 `SvgUnknownElement`"只针对 `view` 与 15 个 `fe*`，不能用来解释 `switch`。）
- **描述**：兼容性声明少列一条真实的行为变化，会让依赖"M4 只影响越界 marker"的下游放心升级，实际却丢掉 `<switch>` 的其余分支（典型用法正是语言/特性回退列表）。
- **建议**：`design.md:90` / `:205` 与 `proposal.md:74-75` 改为两条差异：①越出 marker 视口的内容被裁剪；②`switch` 由"全部子元素参与渲染"改为"只选第一个满足条件者"。README 侧同时把 `README.md:107` 的能力描述标注为与 M3 的输出差异。

### [一般][存量] #3 三个文本基线属性被写成"可继承、按 spec"，但 SVG 1.1 属性索引三者 Inherited 均为 no；`overflow` 初始值偏离也只在 design 承认、spec 未标注

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/design.md:68`（"继承性按 spec：`dominant-baseline` / `alignment-baseline` / `baseline-shift` / `writing-mode` 可继承"）
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-css/spec.md:12-13`（`dominant-baseline` / `alignment-baseline` 可继承、初始 `auto`；`baseline-shift` 可继承、初始 `baseline`）
  - 同文件 `:10`（`overflow` 初始 `hidden`）；`design.md:69`（承认这是对 SVG 1.1 UA 样式表的简化）
  - 实现：`f_svg/src/SvgComputedStyle.cj:119-121`（三者 `SvgPropertySpec(name, true, …)`，`true` = 可继承）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「关键段落缺失」；§11「契约与实现不符」；外部判据：W3C SVG 1.1 (2nd ed.) Appendix N Property Index——`dominant-baseline`、`alignment-baseline`、`baseline-shift` 的 Inherited 列均为 **no**，`writing-mode` 为 **yes**
- **证据**：静态确定 —— 官方属性索引与 `design.md:68` 的"按 spec"相反；实现与文档一致（都按可继承），因此这是**把偏差说成合规**的文档问题，而非实现漏改。`overflow`：SVG 1.1 初始值为 `visible`（viewport 元素由 UA 样式表给 `hidden`），`design.md:69` 已承认模块把初值定为 `hidden`，但 `svg-css/spec.md:10` 直接以规范口吻写"初始 `hidden`"，未标注偏离。
- **描述**：`<g dominant-baseline="middle">` 下所有后代文本都会继承中线，`<text baseline-shift="sub">` 内的 `<tspan>` 也会继承下移；浏览器与 SVG 1.1 只对显式声明该属性的元素生效，同一文档在本模块与其他渲染器上会出现整段文本上下错位。`overflow` 的取舍本身合理（`design.md:69` 给了理由），问题只在 spec 没把它写成"本模块偏离"。
- **建议**：二选一并同步三处：①贴合 SVG 1.1：`SvgComputedStyle.cj:119-121` 改 `false`，`svg-css/spec.md:12-13` 与 `design.md:68` 改为"不可继承，初始 `auto` / `baseline`"，补"嵌套 tspan 不继承基线"用例；②保留可继承：把 `design.md:68` 的"按 spec"改为"本模块选择可继承（偏离 SVG 1.1）"，并在 `svg-css/spec.md` 增"与 SVG 1.1 的差异"段。`overflow` 同样在 `:10` 补一句"模块初值 `hidden`，`initial` 亦得 `hidden`，与 SVG 1.1 的 `visible` 不同（理由见 design D1）"。

### [一般][存量] #4 `mathematical` 基线被 spec 定义为"x-height 中线"，设计与实现取 `-0.5 × ascent`，按 spec 字面无法验收

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-text/spec.md:7`（"`mathematical` 为 x-height 中线"）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:143`（基线表 `mathematical | -0.5A`）；同文件 `:220`（"基线表无 x-height 度量 … `mathematical` 取 `-0.5A`，在文档中写明近似"）
  - 实现：`f_svg/src/SvgTextBaseline.cj:235`（`case Mathematical => -0.5 * ascent`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「条款不能用」；§14.1「承诺了但没实现」
- **证据**：静态确定 —— M4 设计自述 `SvgFont` 只有 `ascent` / `descent`（`design.md:13`），实现取 `-0.5A`；当前 `SvgTrueTypeFont` 已有 `OS/2.sxHeight`（`SvgTrueTypeFont.cj:116-117` 的 `xHeightValue`），但 `SvgTextBaseline.offset` 的签名只收 `ascent` / `descent` / `fontSize`（`:224-238`），x-height 至今没有进入基线表。`svg-text/spec.md:16-19` 的"无字体度量的回退"Scenario 也不覆盖 `mathematical`，没有用例能暴露该差异。
- **描述**：验收方按 spec 写"取 x-height 中线"的期望值必然失败；按实现写又无法从 spec 推出 `-0.5A`。这是"规格给了当前没有落地路径的口径"，会让后续对齐 SVG 2 的改造缺少依据。
- **建议**：把 `spec.md:7` 改为可执行口径（"取 ascent 中线，即 `-0.5 × ascent`；无 x-height 度量时的确定性近似"），并在 Scenario 增加 `mathematical` 的 y 值断言与相对 `middle` 的次序；若要真按 x-height，`SvgTrueTypeFont.xHeightValue` 已可用，需把它接进 `SvgTextBaseline.offset` 的参数并给 Hershey 回退值。

### [一般][存量] #5 路径长度 API 没有点数/段数预算，小体积 `d` 可放大出大段表，且每次调用整体重建

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-geometry/spec.md:7-11`（只规定"按容差离散为折线"，无点数/段数/内存上限）
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md:7-13`（M4 上限表不含路径测量）
  - 实现：`f_svg/src/SvgPathMeasure.cj:66-103`（`buildSegments` 全量物化 `SvgMeasuredSegment`）、`:105-112`（`totalLength` 每次重建整表）、`:145`（`pointAt` 同样依赖段表）；`f_svg/src/SvgRasterizer.cj:692-706`（`subdivideCubic` 出口 `depth >= 16 || 平坦度 ≤ 容差`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §5「一次性物化 / 递归 + 每层分配 / 无界容器」；§11「缺少边界校验」
- **证据**：静态确定（结构）+ 需实测（峰值内存）—— 单条三次曲线最多 2^16 = 65536 个点（`depth` 封顶 16），每点 2 个 `Float64`，段表每段 6 个 `Float64`（48 B）；`buildSegments` 在 `refine=true` 时把容差再乘 0.05，进一步加深细分。命令数只受 `d` 文本长度限制，`SvgSecurityOptions.maxElements` 不约束单条 `d` 的命令数，`textPath` 渲染与公开 `totalLength` / `pointAtLength` 共用这条路径。
- **描述**：最坏情况下一条三次曲线可产出 65536 段、段表约 3 MiB（另有约 1 MiB 折线点）；1 KiB 的 `d`（数十条曲线）可达上百 MiB，16 KiB 级 `d` 可到 GB 级。公开 API 每次调用都重建整表，重复调用还会放大分配与 CPU；当前没有任何拒绝路径，只在 OOM 时暴露。
- **建议**：给 `buildSegments` 增加"最大点数/最大段数"预算常量，累计后超限抛 `SvgException(kind: Limit)`（在分配前判定）；把该上限登记到 `svg-security` 的 M4 上限表并补负向 Scenario（`d` 含大量高阶曲线 + 小容差 → `Limit`）。同时可让 `totalLength` 与 `pointAtLength` 复用一次段表（接口层缓存或调用方持有），避免每次重建。

### [一般][存量] #6 `feTurbulence` 的 `stitchTiles` 只有模型读写，渲染完全忽略，规格也未声明该限制

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-filter/spec.md:92`（"SHALL 提供 … `stitchTiles`（`noStitch` 缺省 / `stitch`）"）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:106-117`（D5 湍流算法全篇未提 `stitchTiles`）
  - 实现：`f_svg/src/SvgFilterPrimitives2.cj:689-703`（只做属性字符串互转）、`:1172-1180`（`turbulenceFilterBuffer` 签名不含 stitch）、`f_svg/src/SvgFilterRenderer.cj:357`（唯一调用点同样不传）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14.1「配置项被读取却从未使用（接线缺失）」；§11「语义与命名不符」；§3「承诺有行为、实现为空」
- **证据**：静态确定 —— 全仓 `stitchTiles` 只出现在 getter/setter、`SvgBuilder.cj:577` 的值白名单与模型/往返测试中；`turbulenceFilterBuffer` 只消费 `seed` / `numOctaves` / `baseFrequency` / type，没有任何平铺拼接分支；spec 也没有为它写 Scenario，`tasks.md:50` 的湍流用例只覆盖两类噪声、seed、`baseFrequency`、`numOctaves`。
- **描述**：`stitchTiles="stitch"` 被解析、保存、写回，但对渲染没有任何影响，也没有 warning，属"静默无效的公开属性"。默认 `noStitch` 与实现一致，默认输出不受影响；但对需要无缝平铺的素材，调用方会误以为库已支持拼接。
- **建议**：二选一——(a) 在 `svg-filter` 明确"`stitchTiles` 仅为模型属性，渲染按 `noStitch` 处理"，并在渲染入口对 `stitch` 追加一次性 warning；(b) 实现周期化噪声（按滤镜区域取整频率，使相邻 tile 连续），补"同 seed、`stitch` 下左右 tile 边界连续"的像素用例，并在 `svg-security` 记录成本。

### [一般][存量] #7 `tasks.md` 把 `openspec validate --strict` 记为"已运行并通过"，同一处备注又说本机无 CLI，`fix-plan-3.md` 也称通过

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/tasks.md:145`（"`[x]` 运行 `openspec validate add-f-svg-m4 --strict`（通过）"）、`:146`（"本机无 `openspec` CLI，CLI 校验在具备环境的归档流程中补跑"）
  - `f_svg/doc/spec/add-f-svg-m4/fix-plan-3.md:11`（"`openspec validate add-f-svg-m4 --strict` 通过"）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 结论相反」；§11「错误处理缺失或静默」（验收证据失真）
- **证据**：静态确定 —— 同一门禁同时存在"已通过"与"无法执行"两种状态；`fix-plan-3.md` 声明通过，`tasks.md:146` 声明 CLI 不存在。`openspec` 目前只剩 `add-f-a2a` 与 5 个 `2026-11-20-fix-*` 归档，无法补跑 `add-f-svg-m4`（变更目录已不在）。
- **描述**：归档复核无法判断 `--strict` 到底有没有跑过；"通过"作为验收证据不成立，另一处又称"人工逐条核对通过"，两者不可互相替代（人工核对不能证明 schema/格式合规）。
- **建议**：`tasks.md:145` 改为"主流程人工逐条核对 Requirement/Scenario（通过）；`openspec validate --strict` 因本机无 CLI 未执行，标记为待补"，并删除 `:146` 与 `fix-plan-3.md:11` 的"通过"表述；若确有执行记录，补上时间与命令输出。

### [轻微][存量] #8 `SvgTrueTypeFont.load(path)` 整文件物化，规格未给字体文件字节上限

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md:44`（上限为表数 64、单表 16 MiB、点数 10000、复合深度 8，均为"读取表数据前"检查）、`:74`（"`load` 只读取传入路径 … 安全责任由调用方承担"）
  - 实现：`f_svg/src/SvgTrueTypeFont.cj:330-337`（`load` → `SvgFontFileAccess.read` → `parse(bytes)`）、`:29-34`（`File.readFrom(path)` 直接整文件读入）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §5「一次性物化 / 按不可信长度物化」；§14「承诺与实现不符」
- **证据**：静态确定 —— `File.readFrom` 在表级上限执行之前就把整个文件读成 `Array<Byte>`，规格与实现都没有文件字节上限；M3 的 `SvgPngDecoder.decode(stream)` 有 64 MiB 流上限，字体路径没有对应项。
- **描述**：调用方把数 GiB 的"字体"传给公开入口时，进程先按文件大小整体物化，再进入表校验；表级上限无法防住这一层。由于 `svg-security:74` 明确把责任划给调用方、渲染链路也从不调用 `load`，本项按健壮性缺口处理，不定为安全漏洞。
- **建议**：在 `svg-security` 的 TTF 上限表补"字体文件字节数 ≤ N（建议与 base64 上限 32 MiB 对齐）"，在 `SvgFontFileAccess.read` 读取前按文件长度判定、超限抛 `SvgException(kind: Limit)`；`parse(bytes)` 入口做同一校验以覆盖内存来源。

### [轻微][存量] #9 `tasks.md` 点名的 12 个测试文件不存在：8 个实际带 `M4` 后缀，4 个没有任何同名文件

- **位置**（均为 `f_svg/doc/spec/add-f-svg-m4/tasks.md`）：
  - `:26` `SvgClipProperty_test.cj`、`:30` `SvgVectorEffect_test.cj`、`:42` `SvgFilterPrimitives2_test.cj`、`:57` `SvgFilterLighting_test.cj`、`:71` `SvgTextBaseline_test.cj`、`:78` `SvgTextDecoration_test.cj`、`:84` `SvgTextWritingMode_test.cj`、`:98` `SvgTrueTypeFont_test.cj` —— 实际为 `src/{SvgClipProperty,SvgVectorEffect,SvgFilterPrimitives2,SvgFilterLighting,SvgTextBaseline,SvgTextDecoration,SvgTextWritingMode,TrueType}M4_test.cj`
  - `:107` `SvgView_test.cj`、`:110` `SvgSwitch_test.cj`、`:112` `SvgAnchor_test.cj`、`:117` `SvgPathMeasure_test.cj` —— 仓内没有任何同名文件
- **来源**：存量（`git log --all -- f_svg/src/<name>` 对这 12 个名字均为 0 条提交；`SvgDocumentApiM4_test.cj` 等有 M4 期提交，说明查询方式有效）
- **判据**：review-checklist §13「链接 / 路径失效」；§14.1「任务勾选与证据不符」
- **证据**：静态确定 —— 逐个 `ls` 均 MISSING；`grep -o "[A-Za-z0-9]*_test\.cj" tasks.md` 共 15 个名字，只有 `SvgScene_test.cj`、`SvgTrueTypeTables_test.cj`、`SvgValueTypesM4_test.cj` 对得上。`SvgView` / `SvgSwitch` / `SvgAnchor` 的覆盖在 `SvgDocumentApiM4_test.cj`（含 `SvgSwitchM4_test` 类、`views()` / `anchors()` 断言），`SvgPathMeasure` 在 `SvgGeometryApiM4_test.cj` 与 `SvgBenchmarkM4_test.cj`；功能未缺失，只是落点不可核对。
- **描述**：18 节任务除 18.8 全部勾 `[x]`，勾选依据是"先写 `X_test.cj`"；按文档复核会找不到文件，无法判断 Red 阶段是否真的存在。`fix-plan.md:73` 的 W1 正是"复核 tasks 勾选：无证据的项改为 `[ ]` 或补用例后勾选"，tasks 里没有留下复核痕迹。
- **建议**：把 12 处名字改成实际文件（8 个补 `M4` 后缀），4 个改成真实落点；或在每节备注写"用例落在 X 文件 Y 方法"，让勾选可机械复核。

### [轻微][存量] #10 交叉引用失效：`verify-report*.md` 共 4 处、`design.md` 引用自身不存在的"§8"、归档后的 `openspec/changes|specs` 路径不可达

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/fix-plan.md:3`（`verify-report.md`）、`fix-plan-2.md:3`（`verify-report-2.md`）、`fix-plan-3.md:3`（`verify-report-3.md`）
  - `f_svg/doc/spec/add-f-svg-m3/verification.md:9`（"见 `verification-2.md`、`verify-report-3.md`"，实际是 `verification-3.md`）
  - `f_svg/doc/spec/add-f-svg-m4/design.md:226`（"实施顺序按设计文档 §8"；本文件无编号章节）
  - `f_svg/doc/spec/add-f-svg-m3/verification.md:3`、`verification-3.md:3`（"校验对象"整段指向 `openspec/changes/add-f-svg-m3/**` 与 `openspec/specs/svg-*`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「链接 / 路径失效」「关键段落缺失」
- **证据**：静态确定 —— `find openspec f_svg/doc -name "*verify-report*"` 为空，`add-f-svg-m4/` 下实际是 `verification.md` / `-2` / `-3` / `-4`；`openspec/changes` 只有 `add-f-a2a` 与 5 个 `2026-11-20-fix-*`，`openspec/specs` 无任何 `svg-*`。`design.md` 标题为 Context / Goals / 架构 / Decisions / 关键契约 / Risks / Migration Plan / 假设，没有 §8；`tasks.md:12` 用的是完整文件名 `f_svg/doc/f_svg-M4设计.md`。
- **描述**：每份修复计划第一行的"依据"都指向不存在的文件，复验链断在第一跳；M3 报告的"规格来源"与"主规格对照"两栏也不可达。归档变更引用原件在历史上可理解，但当前读者无法据此复核，且同一问题在 M3/M4 两个目录重复出现。
- **建议**：4 处统一改为 `verification*.md`；`design.md:226` 写全路径与真实小节号（或改为"按 `f_svg/doc/f_svg-M4设计.md` §8"）；两份 M3 报告把"校验对象"改为 `f_svg/doc/spec/**` 相对路径，并在顶部标注"归档副本，openspec 原件已迁出"。

### [轻微][存量] #11 `verification.md` 有两个 `## 6`、3 个 `CRITICAL=0` 标记，§0 还自引用本文件

- **位置**：`f_svg/doc/spec/add-f-svg-m3/verification.md:515`（`## 6. 首轮校验说明（历史…）`）、`:523`（`## 6. 修复结果（本轮）`）、`:521`（`CRITICAL=7（首轮结论…）`）、`:569` / `:604` / `:632`（`CRITICAL=0`）、`:11`（"与 `verification.md` 的 466 一致"）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「关键段落缺失 / 结构失效」；§10 可读性
- **证据**：静态确定 —— 同一文件出现两个编号 6，`§0:9` 又写"见 §6、§7"，指代不明；`CRITICAL=` 是流水线 grep 标记，取第一条会得到与结论相反的 `CRITICAL=7`；`:11` 在 `verification.md` 内引用"`verification.md`"，属自引用笔误。
- **描述**：多轮修复记录叠加在同一文件，结构与机器标记未收敛，归档复核容易误读为"结论反复"。最后一段结论（533 全绿、CRITICAL=0）本身正确。
- **建议**：第二个 `## 6` 改为 `## 7. 修复结果（第一轮）` 并顺延后续编号，同步"见 §6、§7"的引用；机器标记只保留文件末尾一条，历史结论改为表格行；`:11` 改为"与首轮基线（本文件 §0）一致"。

### [轻微][存量] #12 W15 标题写"21 个 Scenario 仅部分覆盖"，与 §2.1/§2.2 的 14 不一致

- **位置**：`f_svg/doc/spec/add-f-svg-m3/verification.md:403`（W15 标题"21 个 Scenario"）；同文件 `:51`（§2.1 合计"部分 14"）、`:57-171`（§2.2 判定列，14 行"部分"）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 结论相反」
- **证据**：静态确定 —— §2.2 的"部分"行逐个数为 14（`:68,69,76,77,89,95,104,125,128,131,134,141,155,168`），与 §2.1 的 14 一致；W15 正文列 10 组、按条目数为 20，与标题 21 和 §2.1 的 14 三者互不相同。文档没有说明统计粒度（Scenario 数 vs 缺口方面数），21 是首轮结论（§0:15 已标为历史）。同类的还有 §0:15 的"失败 2 个"与 §2.1 的"失败 0"，也只靠 `§0:9` 一句"历史结论"区分。
- **描述**：W15 作为"剩余缺口"的汇总入口给出第三个数，复核者无法判断 21 个缺口是否都已处置，也无法用计数反推哪些 Scenario 仍只部分覆盖。
- **建议**：统一粒度并写明口径，例如"14 个 Scenario 仅部分覆盖（与 §2.2 判定列一致），共 20 个缺口方面（见下列 10 组）"，删除与 §2.2 重复的罗列；§0 的 21 保留但明确标注"首轮数字"。

### [轻微][存量] #13 W17 的最终状态在两份 M3 报告里相反：`verification.md` 记"已修复"，`verification-3.md` 记"部分落地"

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m3/verification.md:586`（`| W17 | 已修复 | …`）
  - `f_svg/doc/spec/add-f-svg-m3/verification-3.md:17`（"W17 | **部分落地** … `openspec/changes` 副本仍是旧文本，见 NEW-W2"）、`:157-162`（NEW-W2 具体说明）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「文档过期」；§11「与规格冲突」
- **证据**：静态确定 —— 同一变更的两份终验文档对同一条目给出相反状态；`verification.md` §7 的修复表没有记录"openspec 副本"这一半，`verification-3.md` §1 把它列为未落地并给出具体行号。`openspec/changes/add-f-svg-m3/` 现已不存在，残留既无法复核也无法修复。
- **描述**：归档结论同时存在"已修复"与"部分落地"，读者无法判断 W17 是否闭环；结合 #11 的重复编号，`verification.md` §7 看起来像最终结论，实际被 `verification-3.md` 推翻。
- **建议**：以 `verification-3.md` 为准，把 `verification.md:586` 改为"已修复（`f_svg/doc` 副本）；`openspec/changes` 副本随归档删除，不再适用"，并在 §7 表下注明"最终状态以 `verification-3.md` §1 为准"。

### [轻微][存量] #14 `design.md` 对新增滤镜原语给出三种计数口径（15 标签 / 11 类+光照 / 7 个分派），实际分派为 8 个

- **位置**：`f_svg/doc/spec/add-f-svg-m4/design.md:7`（"15 个新 `fe*` 标签"）、`:56`（架构图"11 类原语+光照"）、`:110`（"`runPrimitive` 增加 7 个分派"）、`:108-109`（列出 6 + 2 = 8 个原语）；对照 `proposal.md:7`（"7 类滤镜原语"）与实现 `f_svg/src/SvgFilterRenderer.cj:350-366`（8 个 case）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 结论不一致」；§2「同一口径两处不一致」
- **证据**：静态确定 —— 8 个原语 case 分别为 `SvgFeComponentTransfer` / `Morphology` / `ConvolveMatrix` / `Turbulence` / `DisplacementMap` / `Image` / `DiffuseLighting` / `SpecularLighting`；"7 个分派"把两种光照合为一类但未说明；"11 类原语+光照"与 M3 的 8 个原语 + M4 的 8 个也对不上。
- **描述**：三处计数无法互推，按设计核对"新原语是否全部接线"时得不到唯一清单（实际 8 个均已注册）。这不是行为缺陷，但会削弱自检。
- **建议**：统一为"新增 8 个原语元素 / 15 个新标签 / 7 个原语类别（两种光照合为一类）"，`:56` 的架构图改为"滤镜原语（M3 8 + M4 8）"。

### [轻微][存量] #15 `textPath side="left"` 的"左移"与同一规格 Scenario 的"向下偏移 10"方向矛盾，实现与测试都取 +y（向下）

- **位置**：
  - `f_svg/doc/spec/add-f-svg-m4/specs/svg-text/spec.md:112`（"`side="left"` SHALL 让字形沿路径法线**左移** `0.5 × fontSize`"）与 `:118-121`（Scenario 复述"沿路径法线左移 10"）
  - 同文件 `:221-224`（MODIFIED Scenario：同一输入"水平路径、`side="left"`、字号 20" → "字形中心相对路径**向下**偏移 10"）
  - 实现：`f_svg/src/SvgTextPathLayout.cj:147-156`（`Left` 取 `+sideOffset`，法线 `(-sin θ, cos θ)`；θ=0 时为 `(0,+1)`）；测试 `f_svg/src/SvgTextPathExtensionM4_test.cj:63-72`（断言 `left[0].originY == 10`、`right[0].originY == -10`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」「条款不能用」；§10 可读性
- **证据**：静态确定 —— 同一 ADDED Requirement 的正文与 Scenario 给出"左移"，MODIFIED Scenario 与实现/测试给出"向下"；在 y 向下的用户坐标系里，沿 +x 前进的"左"是 `-y`，两组描述至少有一组是笔误。偏移量（10）两侧一致，只有方向冲突。
- **描述**：验收方按正文写"上方偏移"会失败，按 MODIFIED Scenario 写"下方偏移"会通过；后续若与 SVG 2 的 `side` 语义对齐，现有测试会挡住改动。当前像素结果由实现与测试共同锁定，属契约精度问题而非行为缺陷。
- **建议**：明确写出法线方向而不使用"左/右"这种相对词，例如"按实现取 `n = (-sin θ, cos θ)`，`side="left"` 为 `+n`、`right` 为 `-n`，水平路径即向下/向上"，并让 `:112`、`:121`、`:224` 用同一句话；若目标是与 SVG 2 一致（水平路径的 `left` 在上方），需同时改实现与测试，并在兼容性说明中标注。

## 优化可行性方案

本部分文件全部为 `.md`，不含可测量的 CPU / 堆内存执行路径，因此**没有**带基线的优化方案（§7 / §8 计 0）。#5 与 #8 是"补上限"的缺陷修复，已计入「发现」而非本节；任何收益估算都缺改前/改后数据，统一放入「待验证假设」。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 路径长度段表的最坏放大倍数（#5） | `f_svg/src/SvgPathMeasure.cj:66-103`、`SvgRasterizer.cj:692-706` | 单条曲线实际点数分布、段表峰值 RSS | 构造 1 KiB / 16 KiB 的病理 `d`（大坐标 + 小容差），测 `totalLength` 的分配量与峰值 RSS；同时给 `-O2` 下耗时 |
| 2 | `side="left"` 取 +y 是否符合 SVG 2 的 side 语义（#15） | `svg-text/spec.md:112`、`:224`；`SvgTextPathLayout.cj:147-156`；`SvgTextPathExtensionM4_test.cj:63-72` | SVG 2 `textPath side` 的法线定义、参考实现输出 | 查 SVG 2 规范文本；用 resvg / Chrome 渲染同一水平路径 + `side="left"`，比较偏移方向 |
| 3 | 基线属性按可继承实现后与浏览器/其他渲染器的像素差异（#3） | `svg-css/spec.md:12-13`、`SvgComputedStyle.cj:119-121` | 同输入下差异像素数与分布 | `<g dominant-baseline="middle"><text>A<tspan>B</tspan></text></g>` 分别用本模块与 Chrome headless / resvg 渲染，比对差异像素 |
| 4 | 文档声称的测试规模与"全绿"（M3 525/533、M4 710） | `add-f-svg-m3/verification.md:598`、`:626`、`tasks.md:144` | 本轮未跑构建（铁律），无实测 | WSL `source cangjie.sh && cjpm test`，记录 `TOTAL / PASSED / FAILED`，与文档数字对照 |
| 5 | `glyphPath` 每次重新解析 `glyf`、滤镜卷积/湍流在 512×512 的成本 | `SvgTrueTypeFont.cj:459`、`SvgFilterPrimitives2.cj:1006-1041`、`:1172-1200` | 自耗时占比、P95 | `cjprof record` 渲染 10 万字 TTF 文本与 512×512 卷积/湍流（`-O2`），对照缓存/优化版本；给绝对值、中位数、离散度 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_svg.part4.txt` 一一对应，18 行全部读完。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/doc/spec/add-f-svg-m3/verification-3.md` | .md | ✅ | 第三轮终验：C4/C6 复验、N1–N4/W2/W14/W19 落地、NEW-W1–W4；抽检 `SVG_MAX_REFERENCE_DEPTH = 64`（`SvgRenderGuard.cj:21`）与文档一致；W17"部分落地"与 `verification.md:586` 矛盾（#13）；"校验对象"的 `openspec/*` 路径失效（#10）；525 条未复跑（待验证 4） |
| 2 | `f_svg/doc/spec/add-f-svg-m3/verification.md` | .md | ✅ | 首轮 466 → 512 → 525 → 533 的修复记录；抽检 C3 除法防护（`SvgPngDecoder.cj:92`、`SvgBitmap.cj:98`）与文档一致；两个 `## 6` 与 3 个 `CRITICAL=0`（#11）；W15 的 21 vs 14（#12）；W17 记"已修复"（#13）；§0 与 §2.1 的失败数只靠"历史"标注区分 |
| 3 | `f_svg/doc/spec/add-f-svg-m4/design.md` | .md | ✅ | D1 继承性"按 spec"与 SVG 1.1 相反（#3）；D3"唯一改变输出"漏 `switch`（#2）；D5 计数三口径（#14）；D7 `mathematical = -0.5A`（#4）；D9 公式写反（#1）；`:226` 的"§8"无对应（#10）；D10 特性表与 `SvgSwitch.cj:24-41` 逐项一致；D12 `languages` 默认 `["en"]` 与 `SvgBitmap.cj:235` 一致 |
| 4 | `f_svg/doc/spec/add-f-svg-m4/fix-plan-2.md` | .md | ✅ | C5-2（半径 16 + 64 Mi 采样预算）与 NEW-C1（`markerContentFits` 用完整内容矩阵、读计算样式）自洽；W9-2 要求 README 披露 `switch` 差异，是 #2 的证据；NEW-W4 的 143/10 → 144/11 与 `fix-plan-3.md:10` 的 145/12 递进一致；`:3` 引用不存在的 `verify-report-2.md`（#10） |
| 5 | `f_svg/doc/spec/add-f-svg-m4/fix-plan-3.md` | .md | ✅ | N2（装饰线并入 bounds 破坏渐变几何）、N3（文本重复 layout）、N5（子元素 marker 越界）、N6（字体不读文件）与实现/测试落点对应；N1/N4 已完成；`:11` 的 validate "通过"与 `tasks.md:146` 矛盾（#7） |
| 6 | `f_svg/doc/spec/add-f-svg-m4/fix-plan.md` | .md | ✅ | C1–C5 + W1–W12 计划齐全；C2 明确要求修正 design D9 但未落地（#1）；C5 的上限后被 `fix-plan-2` 收紧（演进自洽）；`:3` 引用不存在的 `verify-report.md`（#10）；W1 的"复核勾选"在 tasks 无痕迹（#9） |
| 7 | `f_svg/doc/spec/add-f-svg-m4/proposal.md` | .md | ✅ | A/B/C 三包与 10 个 delta 能力一一对应；`SvgRenderOptions` 只加 `languages`、默认 `["en"]` 与实现一致；"7 类滤镜"是 #14 的计数来源；兼容性段漏 `switch`（#2）、漏 `feMorphology` 上限（后续轮补充，历史演进可接受） |
| 8 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-css/spec.md` | .md | ✅ | 8 个属性的注册与初始值与 `SvgComputedStyle.cj:116-123` 逐项一致；`overflow: scroll/auto → hidden` 由 `SvgStyleResolver.cj:657-664` 实现；三个基线属性继承性与 SVG 1.1 相反（#3）；`overflow` 初值偏离未在 spec 标注（#3） |
| 9 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-document-model/spec.md` | .md | ✅ | `views()` / `view(id)` / `anchors()` 与 `SvgDocument.cj:117`、`:142`、`SvgAnchor.cj:19` 对应；15 个 `fe*` 标签与 `tasks.md:36` 的"15 个新元素"一致；无发现 |
| 10 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-filter/spec.md` | .md | ✅ | 8 个原语的参数/降级语义与 `SvgFilterRenderer.cj:350-366` 的 8 个分派、`SvgFilterPrimitives2.cj:1179-1186` 的 `numOctaves > 8 → Limit` 一致；`stitchTiles` 有属性无行为（#6）；组合/确定性 Scenario 与 design D5 一致 |
| 11 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-geometry/spec.md` | .md | ✅ | 长度 API、`forView`（`SvgRenderTree.cj:340` 调用）、`ctm` 累乘链与实现一致；`screenCTM` 公式写反且 Scenario 无法暴露（#1）；无点数/段数预算（#5） |
| 12 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-paint-and-clip/spec.md` | .md | ✅ | `clip` 四边/`auto`/与 `clip-path` 顺序、`overflow` 对 4 类视口元素、`pattern` `viewBox` 三组条款与 design D2–D3 自洽；"pattern `visible` 不跨 tile"两处一致；无发现 |
| 13 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-rasterization/spec.md` | .md | ✅ | `non-scaling-stroke` 的 `sqrt(|det|)` 换算与 design D4、`proposal.md:19` 一致；非均匀缩放下 Scenario 自报 x 向设备宽 `4√2`，与公式自洽（"按设备空间解释"的措辞对非均匀 CTM 偏宽，未单列缺陷）；无发现 |
| 14 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-render-pipeline/spec.md` | .md | ✅ | `switch` 求值（空白/逗号分词、`-` 边界前缀匹配）、`languages` 只影响 `systemLanguage`、效果顺序（marker/pattern → 内容 → filter → clip → clip-path → mask → 透明度）与 `SvgSwitch.cj:45`（`select`）、`SvgRenderTree.cj:771` 一致；无发现 |
| 15 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-security/spec.md` | .md | ✅ | 上限表（order 9 / octaves 8 / 半径 16 / 64 Mi 采样预算 / TTF 表数 64、单表 16 MiB、点数 10000、深度 8）与 `fix-plan-2/3` 一致；`load` 失败抛 `Syntax` 与 `SvgTrueTypeFont.cj:330-337` 一致；缺文件字节上限（#8）、缺路径测量上限（#5） |
| 16 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-text/spec.md` | .md | ✅ | 基线表/装饰线/竖排/`textPath` 四组条款；`unitsPerEm` 与 `advance` 缩放、`fs/14` 厚度、`0.10fs` 下划线、`0.55A` 删除线与实现一致；`mathematical` 口径（#4）；`side="left"` 方向矛盾（#15） |
| 17 | `f_svg/doc/spec/add-f-svg-m4/specs/svg-value-types/spec.md` | .md | ✅ | 5 组枚举的取值/字符串形式与 `SvgVectorEffect.cj:26`（class + 静态属性，避免与 `Option.None` 冲突）、`SvgOverflow` / `SvgBaselineShift` / `SvgTextDecoration` 定义一致；回退表与 `SvgStyleResolver` 的非法值 warning 路径一致；无发现 |
| 18 | `f_svg/doc/spec/add-f-svg-m4/tasks.md` | .md | ✅ | 1.4 的 14 个新文件全部存在；17.1–17.4 的 `m4-*.svg/.rgba` 全部存在；8.2/12.3 引用的 `m3PatternExact` / `m3TextPathExact` 在 `SvgScene_test.cj:199` / `:209`；18.2 要求 README 写 `switch` 差异（#2）；18.6 的 validate 结论矛盾（#7）；12 个测试文件名对不上（#9）；18.8 未勾选属待用户确认的共享分支操作 |

合计：`.cj` 0 个 / `.md` 18 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码，值/引用语义、`Option` 惯用法、`mut` 不适用；文档层面的契约不符分别计入 §5（2 条）、§13（12 条）、§14（1 条），不在此重复计数。注入/转义专项已单独核对：元素写回路径在 `SvgElement.cj:424` / `:434` 调用 `escapeSvgAttribute` / `escapeSvgText`（`:705`、`:718`，`& < > "` 全覆盖），本部分未发现转义缺失或外部实体相关承诺 |
| §1 死代码 | 0 | 18 个文件全为 `.md`，无声明可判。改为核对文档声明的公开符号是否都有消费点：`SvgView`/`SvgAnchorInfo`/`SvgViewportTransform`/`SvgTrueTypeFont`/`SvgBaselineShift`/`SvgTextDecoration`/`SvgWritingMode`/`SvgOverflow`/`SvgVectorEffect`/5 组滤镜枚举全部命中定义与使用；唯一"声明了但无效果"的是 `stitchTiles`，按 §14 计入 #6；`tasks.md` 点名的 14 个新源文件全部存在 |
| §2 重复逻辑 | 0 | 已逐对比对 18 份文档：`screenCTM` 公式在 `design.md:170` 与 `svg-geometry/spec.md:68` 重复且同错，已并入 #1（重复导致错误扩散，不单列）；`proposal` / `design` / `tasks` 的 Goals-NonGoals 与任务清单属变更模板，不判重复；三轮 `fix-plan` 是流程演进，非同一实现两份 |
| §3 空实现 | 0 | 未发现空函数或空分支：8 个新原语、基线/装饰/竖排、TTF、view/switch/anchors 都有实现。`stitchTiles` 不是空函数而是无消费点，按 §14.1 计入 #6，本行不重复计；`tasks.md` 18 节均指向存在的文件或已定位的落点（#9 仅文件名不符） |
| §4 栈溢出 | 0 | 文档涉及的递归都有显式上界：TTF 复合字形深度 8（`SvgTrueTypeFont.cj:49-51`）、pattern/marker 引用 64（`SvgRenderGuard.cj:21`）、`maxDepth` 默认 512（`SvgOptions.cj:66`）；`SvgPathMeasure` 为迭代实现，曲线细分深度封顶 16（放大分配，已计入 §5，不是栈溢出） |
| §5 OOM | 2 | #5（路径测量无点数/段数预算，每次调用重建整表）、#8（`load` 整文件物化、无文件字节上限）。两者均给出量化结构或上限建议；具体峰值内存待实测（待验证 1） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；`glyphPath` 重复解析、卷积/湍流、`textPath` 逐段扫描三条线索转「待验证假设」#5，不作结论 |
| §6.2 大粒度锁 | 0 | 纯文档，无锁路径；`design.md:60` 声明派生数据只存在于本次渲染，无共享可变状态 |
| §6.3 并发串行 | 0 | 文档无 `spawn` / `Future` / 线程池 / 定时任务描述 |
| §6.4 低效算法 | 0 | 结构性线索（`SvgPathMeasure.totalLength` 每次重建、`sample` 线性扫描段表）缺输入规模与耗时数据，只进待验证假设，不写成缺陷 |
| §7 降堆内存方案 | 0 | 文档无持有对象；#5/#8 是补上限的缺陷修复，未包装成优化方案；无基线不做收益断言 |
| §8 降 CPU 方案 | 0 | 同上；`tasks.md:136` 的基准标注"参考、非门禁"，无绝对值与中位数，不足以支撑结论 |
| §9 local mode 可行性 | 0 | 纯文档，无函数内临时大对象；渲染产物必须作为位图返回（逃逸），"函数返回即释放"前提不成立；且无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 0 | 本轮文件全为 `.md`，仅在取证时读实现：`screenCTM` 实现顺序与 `fix-plan.md:20-26` 的修正一致（错的是文档，#1）；C3 除法防护（`SvgPngDecoder.cj:92`、`SvgBitmap.cj:98`）、`SVG_MAX_REFERENCE_DEPTH = 64`、`SvgSwitch` 特性表、`SvgTrueTypeFont.load` 的 `Syntax` 包装均与文档相符；`stitchTiles` 的"属性无消费"已计入 §14/#6，不重复计 |
| §12 并发安全与锁粒度 | 0 | 纯文档；`SvgRenderOptions` 只加不可变字段 `languages`，渲染器按调用构造；`SvgTrueTypeFont` 字段均为 `private let`（`:93-117`），无跨线程可变缓存 |
| §13 文档一致性（.md） | 12 | #1 公式相反、#2 兼容性漏 `switch`、#3 继承性与 SVG 1.1 相反、#4 `mathematical` 口径、#7 validate 结论矛盾、#9 测试文件路径失效、#10 `verify-report*` / "§8" / `openspec` 死引用、#11 `## 6` 重号与标记重复、#12 21 vs 14、#13 W17 状态相反、#14 原语计数三口径、#15 `side` 方向矛盾。其余条款逐条落到实现行核对：8 个属性注册与初始值、15 个 `fe*` 标签、10 个 delta 能力、7 组枚举字符串、4 项上限、`languages` 默认值均一致 |
| §14 功能完备性与 README 覆盖 | 1 | #6（`stitchTiles` 有属性无行为、无 Scenario）。README 覆盖属其他子轮，未越界判断；`#2` 的 `switch` 差异披露计入 §13 |
| 文件覆盖（§13 等） | 18/18 | 18 个 `.md` 全部逐行读完，无缺 |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 15 条（0 严重 / 7 一般 / 8 轻微），是否纳入修复待用户决定。

## 总评

本部分是 M3 终验与 M4 验收档案，不含运行时代码，因此不存在直接可触发的注入、逃逸或崩溃；风险集中在**"规格与实现不同源"**与**"验收证据不实"**两类。

M4 的十个能力域（滤镜、文本、pattern、clip/overflow、TTF、view/switch/anchors、路径长度、CTM）在代码里都已落地，抽查的签名、缺省值、上限常量与效果顺序基本一致，说明实现完成度不低。但规格正文有四处把行为写反或写成另一种定义：`screenCTM` 矩阵顺序（#1）、兼容性声明漏 `switch`（#2）、三个基线属性"按 spec 可继承"（#3）、`mathematical` 基线口径（#4）；另有一处方向措辞自相矛盾（#15，`side="left"` 的"左移"与"向下"）。这些都是"照文档写用例必失败、照实现写又与文档冲突"的验收级错误；其中 #1 尤其隐蔽——唯一的 Scenario 用可交换的均匀缩放，把错误公式"验证"成了通过。

两条上限缺口是 M4 新能力的直接后果：#5 的路径测量无点数/段数预算（单条曲线最多 65536 点，公开 API 每次重建段表），#8 的字体 `load` 整文件物化且无字节上限。前者可由不受信 SVG 触发（`d` 的命令数不受 `maxElements` 约束），建议优先补预算并登记到 `svg-security`；后者责任已划给调用方，按健壮性补一条上限即可。#6 的 `stitchTiles` 则是"公开属性静默无效"，默认值下不影响输出，但需要按"实现或声明限制"二选一收口。

审计链问题（#7 的 validate 结论矛盾、#9 的 12 个测试文件名、#10 的死引用、#11 的重复章节号、#12/#13 的计数与状态相反、#14 的计数三口径、#15 的 `side` 方向措辞）不影响使用，但会让后续复核对"哪一轮是最终裁定、哪些缺口还开着"产生误判；建议作为一个纯文档 PR 集中清理，合并模块报告时与第 3 部分的同类条目并为 2–3 条。

`严重` 为 0：本部分无运行时代码，未发现崩溃、并发或数据计算错误；文档中的递归与大部分 OOM 上限齐全。性能与内存只有 5 条待验证假设（段表放大、`side` 法线语义、继承偏差像素、测试计数未复跑、字形/滤镜耗时），均无基线，不进修复清单。阻塞项：无。

**范围外提示**（`.cj` 与 `README*` 属其他子轮，只记一句）：`f_svg/README.md:107` 把 `switch` 只选第一个满足条件者写成能力表一行，未标注为与 M3 的输出差异（`tasks.md:141` 与 `fix-plan-2.md:58-60` 均要求标注）；`f_svg/src/SvgFilterPrimitive.cj:177`、`SvgGzip.cj:96` 仍留 M3 骨架期 `TODO`（对应实现已完成）。
