# f_svg 模块审查报告（第 15/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/src`（本部分 11 个源文件，其中 `.cj` 11 个 / `.md` 0 个）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 本部分问题来源全部为「存量（快照模式无基线）」
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑（本部分实际落在**滤镜原语执行链 + 字体注册表**）
- **报告版本**：v1（分部分报告，最终由主 Agent 合并为 `docs/review/2026-11-28/f_svg_v2.md`）
- **本部分范围**：`SvgFilterPrimitives.cj`（可分离高斯/偏移/flood/混合/合成/合并/颜色矩阵/tile/dropShadow 实现）、`SvgFilterPrimitives2.cj`（feFunc/feMorphology/feConvolveMatrix/feTurbulence/feDisplacementMap/feImage 实现与模型）、`SvgFilterRenderer.cj`（滤镜链执行器）、`SvgFont.cj`（字体接口与注册表）、以及 7 个测试文件

## 发现

### [严重][存量] `feGaussianBlur` 的 `stdDeviation` 无上界，核半径与卷积量随属性线性/平方放大，没有任何拒绝路径

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:41-59`（`gaussianKernel`，`radius = Int64(ceil(3.0 * sigma))`、`Array<Float64>(size)`）；放大点 `:77-141`（`convolveHorizontal` / `convolveVertical`，内层 `while (offset <= radius)`）；入口 `f_svg/src/SvgFilterRenderer.cj:300-316`（只对负值取 0，不设上限）
- **来源**：存量（`git blame` → `6aabd4eb6a` 2026-11-05）
- **判据**：review-checklist §5「按不可信长度预分配 / 拒绝路径缺失」、§6.4「已知规模却不设上限」
- **证据**：静态确定 —— 同文件其余原语都有硬上限：`feMorphology` 半径 16（`SvgFilterPrimitives2.cj:22,934-941`）、`feConvolveMatrix` order ≤ 9（`:1015-1045`）、`feTurbulence` octaves ≤ 8（`:1179-1185`），唯独高斯模糊的 σ 一路直通 `ceil(3σ)`；属性侧 `SvgNumberList.parse` 只校验有限性（`f_svg/src/SvgNumberList.cj:93` `requireFinite`），不校验量级
- **描述**：`stdDeviation="10000"` 合法通过解析 → 核长 60001（约 480 KB 数组）+ 每像素 `4×60001` 次乘加：512×512 区域约 6.3×10¹⁰ 次运算（分钟级挂死）；σ 再放大到 1e8 则 `Array<Float64>(6e8)` ≈ 4.8 GB，直接分配失败。`feDropShadow` 走同一条路径（`:516`）。文档可完全控制该属性，构成渲染侧 DoS / OOM
- **建议**：在 `blurFilterBuffer` 入口按区域尺寸设预算（与 `SVG_FE_MORPHOLOGY_SAMPLE_BUDGET` 同风格）：`radius ≤ 某常量` 或 `w*h*(2r+1) ≤ 预算`，超限抛 `SvgException(kind: Limit)`；σ 很大时改用箱式模糊近似（三次 box blur 逼近高斯）保持视觉可接受

### [一般][存量] `named` 保留每个原语的结果（含代码自造的 `result${index}`），峰值内存按原语数线性叠加

- **位置**：`f_svg/src/SvgFilterRenderer.cj:202`（`let named = HashMap<String, SvgFilterBuffer>()`）、`:246-247`（`let name = primitive.result ?? "result${index}"` / `named[name] = result`）
- **来源**：存量（`git blame` → `ec44b3adcb` 2026-11-05）
- **判据**：review-checklist §5「无界容器 / 长期持有」、§7「缩短生命周期」
- **证据**：需实测（峰值 RSS），代码路径静态确定
- **描述**：每个原语返回新缓冲（`SvgFilterBuffer` 每次 `Array<Byte>(w*h*4)`），全部塞进 `named` 并活到整条链结束。`maxPixels` 默认 64 Mi（`f_svg/src/SvgBitmap.cj:230`）⇒ 单个满区域缓冲 256 MB，一条 3 原语链的峰值下限约 1 GB（还没算 blur 的 Float64 中间数组）。而 `result${index}` 这种合成名按 SVG 规范不可被引用，纯属白占内存
- **建议**：只在 `primitive.result.isSome()` 时写入 `named`；预扫一遍 `in`/`in2` 引用集合，未被引用的具名结果在下一个原语执行后释放（`named.remove`），把峰值从 O(#primitive) 压到 O(#活跃引用)

### [一般][存量] 高斯模糊边界不补边：越界抽头直接跳过但不重新归一化，区域边缘整体变暗

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:94-97`（水平）、`:127-130`（垂直），核在 `:53-57` 已按全核归一化
- **来源**：存量（`git blame` → `6aabd4eb6a` 2026-11-05）
- **判据**：review-checklist §11「语义与实现不符」、§10 正确性（边界处理）
- **证据**：静态确定 —— 边界像素只累加在界内的 `2r+1-|offset|` 个抽头，权重和严格小于 1，输出必小于输入
- **描述**：SVG 要求滤波输入按「边缘像素向外复制」无限延展（duplicate 语义），同模块 `feConvolveMatrix` 的 `edgeMode=duplicate` 就是这么做的（`SvgFilterPrimitives2.cj:1146-1147` `clampSvgIndex`）。模糊路径却按「透明外延」处理，导致 `filterUnits="userSpaceOnUse"` 且区域等于元素包围盒时，模糊结果四周出现一圈衰减（`feDropShadow` 的阴影边缘同样受影响）。当默认 `objectBoundingBox` 区域外扩 10% 时，内容区离边界较远，问题被掩盖
- **建议**：`convolveHorizontal` / `convolveVertical` 越界时取 `clampSvgIndex(sourceX, width)` 而不是跳过，即与 `convolveSample` 的 duplicate 分支共用同一取址逻辑

### [一般][存量] `feDropShadow` 的区域外扩量没有按 `primitiveUnits` 换算，`objectBoundingBox` 下阴影被区域裁掉

- **位置**：`f_svg/src/SvgFilterRenderer.cj:75-83`（`localX -= shadowMargin` 等）＋ `:419-450`（`dropShadowRegionMargin` 只用 `shadow.dx.value` / `stdDeviation` 原值）；对照 `:516-521`（真正执行时 `dx*scaleX`、`σ*scaleX`）
- **来源**：存量（`git blame` → `359da01ac7` 2026-11-06）
- **判据**：review-checklist §11「契约与实现不符」、正确性（边界）
- **证据**：静态确定 —— `dropShadowRegionMargin(filter)` 签名里没有 `objectBounds` / `scaleX`，无法感知 `primitiveUnits`
- **描述**：`primitiveUnits="objectBoundingBox"` 时 `dx="0.1"` 的实际偏移是 `0.1 × bbox 宽 × CTM`（渲染端已乘 `primitiveScaleX`，`:519`），而区域外扩只加 0.1 用户单位。包围盒 200 px 时阴影外扩少 20 px，右侧/下侧阴影被区域直接裁断。`:75-76` 的注释「objectBoundingBox 与 userSpaceOnUse 的 local 坐标都在用户空间，可共用同一外扩量」是错误前提：坐标空间相同，但**数值单位不同**（一个是 bbox 比例，一个是用户单位）
- **建议**：`dropShadowRegionMargin` 增加 `primitiveObjectUnits` 与 `objectBounds` 参数，把 `dx/dy/σ` 先乘 `objectBounds.width/height`；或让 `region` 直接复用 `apply` 里算好的 `primitiveScaleX/Y`

### [一般][存量] `stdDeviation` 语义在 5 处各写一遍，缺省值与负值处理不一致（0 与 2 两种）

- **位置**：`f_svg/src/SvgFilterRenderer.cj:300-316`（blur 分支：缺省 0、负值取 0）、`:419-445`（区域外扩：缺省 2、负值回退 2）、`f_svg/src/SvgFilterPrimitives.cj:497-515`（dropShadow：缺省 2、负值回退 2）、`f_svg/src/SvgFilterPrimitive.cj:212-232`（`SvgFeGaussianBlur.stdDeviation`：解析失败给空列表）、`:331-348`（`SvgFeDropShadow.stdDeviation`：解析失败给 `[2.0]`）、`f_svg/src/SvgFilterPrimitives2.cj:296-306`（`readSvgNumberList`：解析失败给 `None`）
- **来源**：存量（各 `git blame` 落在 2026-11-05 ~ 11-07 的不同提交）
- **判据**：review-checklist §2「换控制流 / 跨层复制」「近似重复：其中一块少了边界判断」
- **证据**：静态确定 —— 三处渲染端代码逐行同构（`deviations.size==1 / >=2 / 负值` 三段判断），只是缺省值一个 0 一个 2
- **描述**：同一个属性「1 或 2 个非负标准差」被解释 5 次，其中缺省值分两派（0 与 2）。当前靠「blur 缺省 0」「dropShadow 缺省 2」的巧合跟规范对齐（`feGaussianBlur` 缺省 0、`feDropShadow` 缺省 2），但改其中一处极易漂移——例如将来给 blur 支持 `feDropShadow` 式缺省，就会静默改变所有 `stdDeviation` 缺失的文档输出
- **建议**：在 `SvgFilterPrimitives.cj` 提 `internal func gaussianSigmas(deviations: SvgNumberList, defaultSigma: Float64): (Float64, Float64)`，渲染端三处统一调用；模型层统一用 `readSvgNumberList` + 显式缺省参数

### [一般][存量] `feDropShadow` 的 `flood-color` 在渲染层重复解析，绕过类型化属性并与 `feFlood` 行为不一致

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:522-535`（`match (shadow.attr("flood-color")) { ... tryParseSvgPaint(text) ... }`）；对照 `f_svg/src/SvgFilterRenderer.cj:323-328`（`feFlood` 直接用 `flood.floodColor.color`）与 `f_svg/src/SvgFilterPrimitive.cj:354-367`（`SvgFeDropShadow.floodColor` 已实现同一解析 + 黑色缺省）
- **来源**：存量（`git blame` → `9858013907` 2026-11-07）
- **判据**：review-checklist §2「跨层复制」「字面量复制」、§11「契约与实现不符」
- **证据**：静态确定 —— 两处都是 `tryParseSvgPaint` + 黑色兜底，但只有渲染层这版会追加 warning `"feDropShadow 的 flood-color「…」不合法，回退黑色"`，模型属性静默回退
- **描述**：同一属性两套解析。若将来 `SvgPaint` 的解析扩展（如 `currentColor`、`context-fill`），渲染层这份拷贝不会跟着变；反之模型层加了 warning 也不会传到这里。此外 `feDropShadow.floodColor` 是公开 API，用户读到的值与渲染用的值可能不同源
- **建议**：改为 `match (shadow.floodColor.color)`，warning 移到模型层属性 getter（或在渲染端判断 `shadow.attr("flood-color").isSome() && 解析失败`），与 `feFlood` 分支合并

### [一般][存量] `feTurbulence` 的坐标换算既无上界也无零除保护，可产生 NaN / 越界整数转换

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:1210-1218`（`octaveFrequencyX = frequencyX / scaleX`；`Float64(x) * octaveFrequencyX`；`seed + octave * 1013`）、`:1250-1251`（`Int64(floor(x))`）、`:1236`（`UInt8(Int64(round(clampSvgUnit(value) * 255.0)))`）；`scaleX/scaleY` 来源 `f_svg/src/SvgFilterRenderer.cj:145-150`
- **来源**：存量（`git blame` → `2cae19b829` 2026-11-06）
- **判据**：review-checklist §11「边界 / 空值未处理」「除零」、§5「按不可信长度预分配」同类
- **证据**：需实测（`Float64 → Int64` 对 NaN/越界值的具体行为），路径静态确定
- **描述**：三条触发路径都只需文档属性：① `primitiveUnits="objectBoundingBox"` ＋ 零宽或零高包围盒（水平/竖直线、`<rect width="0">`）⇒ `scaleY == 0`，`frequencyY / 0` 得 `Inf`，`0 * Inf` 得 NaN；② `transform="scale(0,…)"` 同理；③ `baseFrequency="1e30"`（有限、通过 `isFiniteSvgNumber`）⇒ `x*1e30` 远超 `Int64` 范围。之后 `Int64(floor(NaN))` / `Int64(floor(1e33))` 按语言默认溢出策略会抛异常，而 `apply` 全程不捕获——整份文档渲染失败，且抛出的不是 `SvgException`，调用方的 `catch (SvgException)` 兜不住。另 `seed` 接近 `Int64` 上界时 `seed + octave*1013` 也会整型溢出
- **建议**：`scaleX/scaleY <= 0` 时直接按 0 频率处理并 warning；`baseFrequency` 上限（如 1e4）与 `seed` 收敛（如取模 2¹⁶）后再进噪声；把 `Int64(浮点)` 转换统一包成 `safeSvgInt(value, fallback)`，避免非 `SvgException` 逃逸

### [一般][存量] 数字列表属性 getter 直接把内部缓存数组交给调用方（引用逸出，缓存不会失效）

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:351-361`（`tableValues` 返回 `list.values`）、`:525-535`（`kernelMatrix`）、`:489-497`（`radius` 返回缓存内的 `SvgNumberList`）、`:651-661`（`baseFrequency`）
- **来源**：存量（`git blame` → `e30f1afd13` 2026-11-06）
- **判据**：review-checklist §10「仓颉语言特性：值 / 引用语义」、§11「契约与实现不符」
- **证据**：静态确定 —— `SvgNumberList` 是 `struct`，但字段 `public let values: Array<Float64>`（`f_svg/src/SvgNumberList.cj:47-52`）是引用类型；`SvgValueCache` 只在 `attributesVersion` 变化时重算（`f_svg/src/SvgElement.cj:33-40`），数组内容被外部改写不会触发版本变化
- **描述**：`let kv = matrix.kernelMatrix; kv[0] = 99.0` 会直接改掉缓存里的数组，之后 `kernelMatrix` 读到的已是脏值，而 `attributesVersion`、序列化文本都没变。渲染结果因此依赖「调用方是否手滑改过数组」，且无法通过 `setAttr` 之外的手段复原。同类问题在 `radius`/`baseFrequency` 上是把整个缓存 `SvgNumberList` 交出去（其 `values` 同样可写）
- **建议**：getter 返回 `list.values.clone()`（256 项以内的开销可接受），或把缓存值改成不可变视图；文档层面在 README 声明「返回副本」

### [一般][存量] 字体别名解析丢弃请求的 stretch，`@font-face` 别名 family 的 `font-stretch` 会选错字面

- **位置**：`f_svg/src/SvgFont.cj:158-175`（`delegate.resolveDetailed(targetName, weight, style, stretch: 100.0)`）
- **来源**：存量（`git blame` → `8230d8b455` 2026-11-07）
- **判据**：review-checklist §11「契约与实现不符」、§10 正确性
- **证据**：静态确定 —— 别名分支把调用方传入的 `stretch` 丢掉，硬编码 100.0，并把委托结果的 `stretch` 原样返回
- **描述**：注释写明「别名 family 先映射到目标 family，再委托 base 解析」，但委托时把请求的 stretch 换成 100。目标 family 同时注册 80% 与 120% 两个字面、文档写 `font-stretch: 120%` 时，会拿到 100 的最近邻（80% 字面，`nearestStretch` 平局取先注册者，`:213-233`），再以「请求 120 / 命中 80」合成 1.5 倍缩放——`SvgTextRenderer` 正是用 `resolved.stretch` 决定是否合成（`f_svg/src/SvgTextRenderer.cj:417-424`）。结果既不是 120% 字面，也多做了一次水平缩放，字宽/字重都不对
- **建议**：透传 `stretch: target`；若确实要「别名不参与 stretch 匹配」，则应在 `SvgFontMatch` 里显式区分「未参与匹配」与「命中 100%」，而不是用 100.0 冒充

### [一般][存量] `feTurbulence` 的 `stitchTiles` 已建模但渲染端从不读取（承诺了未实现）

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:689-704`（`stitchTiles` 属性，读写齐全）；渲染端 `:1172-1247`（`turbulenceFilterBuffer` 全文无 `stitchTiles` 引用）
- **来源**：存量（`git blame` → `e30f1afd13` 2026-11-06）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」
- **证据**：静态确定 —— 全仓 grep `stitchTiles` 仅命中属性定义、`SvgBuilder.cj:577` 的值映射与 3 个测试断言，`f_svg/src` 内无任何渲染侧读取
- **描述**：**承诺源**：`f_svg/doc/f_svg-M4设计.md:18` 与 `:107`（`feTurbulence` 能力列 `stitchTiles`）、`f_svg/doc/spec/add-f-svg-m4/specs/svg-filter/spec.md:92`（"SHALL 提供 … `stitchTiles`"）。**缺失证据**：渲染实现里没有任何 `stitchTiles` 分支，噪声始终按非 stitch 生成。用户按文档写 `stitchTiles="stitch"` 得到与 `noStitch` 完全相同的输出（平铺 seams 依旧存在），且无 warning
- **建议**：要么在 `turbulenceFilterBuffer` 实现 stitch（周期化梯度格点，按 tile 尺寸对齐 baseFrequency），要么在文档与 README 的能力表把 `stitchTiles` 标为「仅建模、不影响渲染」并加 warning，避免"写了不生效"

### [轻微][存量] 四个 `fromNameOrWarn` 在生产路径上零调用，仅被测试引用（接线缺失 + 可见性建议）

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:66-81`（`SvgTransferFunctionType`）、`:112-127`（`SvgMorphologyOperator`）、`:167-182`（`SvgEdgeMode`）、`:276-291`（`SvgTurbulenceType`）；同类 `:230-245`（`SvgChannelSelector`）
- **来源**：存量（`git blame` → `e30f1afd13` / 更早的 `6aabd4eb6a`）
- **判据**：review-checklist §1「仅测试使用 → 可见性建议」、§14.1「接线缺失」
- **证据**：静态确定 —— 全仓 grep 五个符号只命中 `f_svg/src/SvgValueTypesM4_test.cj:152,162,166,170,173`；生产 getter 一律走 `fromName(...) ?? 缺省`（如 `:336-344`、`:474-482`、`:587-595`、`:636-644`），非法值静默回退
- **描述**：`fromNameOrWarn` 的设计意图是「非法值 + warning」，但没有任何解析/构建路径调用它，于是 `type="wat"` 静默变 identity、`operator="wat"` 静默变 erode，用户拿不到诊断。`f_svg/doc/spec/add-f-svg-m3/verification.md:479` 已记录同类问题（`SvgBlendMode` / `SvgCompositeOperator` / `SvgMarkerOrient`）
- **建议**：二选一——在 `SvgBuilder` 的属性分派里接上这些 helper（非法值进 `warnings`），或删除并在 README 声明「非法枚举值静默回退」；不要保留只服务测试的分支

### [轻微][存量] 卷积核与颜色矩阵的「非有限值」校验在属性路径上不可达，对应测试实际走的是长度不符分支

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:1053-1057`（`kernel` 有限性循环）、`:355-360`（Matrix 20 值有限性）、`:368-371`（saturate）、`:383-386`（hueRotate）；测试 `f_svg/src/SvgFilterPrimitives2M4_test.cj:319-323`
- **来源**：存量（`git blame` → `e30f1afd13`）
- **判据**：review-checklist §1「恒假分支」、§11「测试覆盖与实现不符」
- **证据**：静态确定 —— 解析侧 `SvgNumberList.parse` 用 `requireFinite` 拒绝 NaN/Inf（`f_svg/src/SvgNumberList.cj:93`，`"1e999"` 亦抛 `InvalidValue`，见 `SvgNumberList_test.cj:112-115`）；写回侧 `writeSvgNumberArray` 经 `SvgNumberList.toString()` → `formatSvgNumber` 对非有限值抛 `InvalidValue`（`f_svg/src/SvgNumber.cj:33-35`）。所以 `kernel.values` 永远有限
- **描述**：`invalid.setAttr("kernelMatrix", "0 0 0 0 nan 0 0 0 0")` 在 `readSvgNumberList` 里就抛 `SvgException` 被吞成 `None`，`kernelMatrix` 得到空数组，命中 `:1047-1051` 的「长度不符」warning——测试只断言 `warnings.size > 0`，所以「非有限值」这条分支从未被覆盖，实际是被测路径与用例名不符
- **建议**：把有限性校验前移到 `readSvgNumberList`（解析即报具体原因），或删除这四处不可达分支；测试改用 `SvgNumberList([Float64.NaN])` 直接调用 `convolveFilterBuffer` 才能真正打到该分支，并断言 warning 文案

### [轻微][存量] 过时注释：文件中部仍写着「原语实现与元素模型在后续任务中补齐」

- **位置**：`f_svg/src/SvgFilterPrimitives2.cj:294`
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 维护性」、§11「语义与注释不符」
- **证据**：静态确定 —— 紧随其后的 `:296-1456` 已是完整的元素属性、`feFunc*`、`feMorphology`/`feConvolveMatrix`/`feTurbulence`/`feDisplacementMap`/`feImage` 实现
- **建议**：删除该行，或改成「以下为原语属性模型与实现」的分节注释

### [轻微][存量] 未知原语静默直通且不记 warning

- **位置**：`f_svg/src/SvgFilterRenderer.cj:368`（`case _ => input.copy()`）
- **来源**：存量（`git blame` → `ec44b3adcb` 2026-11-05）
- **判据**：review-checklist §3「case _ 兜底把错误吃掉」、§10 错误处理
- **证据**：静态确定 —— 同一函数里「输入引用不存在」都会 `warnings.add`（`:213-215`），这里唯一不给诊断
- **描述**：`SvgFilterPrimitive` 是 `public abstract class`（`f_svg/src/SvgFilterPrimitive.cj:180`，非 sealed），下游可以定义自己的子类；一旦接入 `SvgFilter`，该原语会被静默当作直通，用户无法知道某段滤镜没生效
- **建议**：`case _ =>` 里 `warnings.add("不支持的滤镜原语「${primitive.tag}」，按直通处理")` 后再 copy

### [轻微][存量] `positiveMod` 与 `positiveSvgMod` 两份同语义实现，守卫条件不同

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:477-487`（有 `modulus <= 0 → 0` 守卫）、`f_svg/src/SvgFilterPrimitives2.cj:1153-1160`（无守卫）
- **来源**：存量
- **判据**：review-checklist §2「换控制流 / 只改名字」
- **证据**：静态确定 —— 逐行比对：两者都是 `value % modulus`，负则 `+ modulus`，唯一差异是前者多一条 `modulus <= 0` 早退
- **描述**：现有调用方都保证 `modulus > 0`（`tileFilterBuffer` 的 tile 尺寸、`convolveSample` 的缓冲宽高），暂无行为差异；但两份实现意味着将来只修一处（例如都改成 `@OverflowWrapping` 或都加零守卫）就会留下不一致
- **建议**：合并到 `SvgFilterPrimitives2.cj` 保留带守卫的一版并改名 `positiveSvgMod`，`tileFilterBuffer` 改调用它

### [轻微][存量] 4 字节像素搬运循环写了 4 份

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:156-159`（`offsetFilterBuffer`）、`:432-435`（`tileFilterBuffer`）、`f_svg/src/SvgFilterPrimitives2.cj:1446-1449`（`feImageFilterBuffer`）、`f_svg/src/SvgFilterRenderer.cj:107-111`（空滤镜链复制整幅位图）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制」「只改类型名」
- **证据**：静态确定 —— 四处都是 `target[base]=src[base]; +1; +2; +3` 四行展开；`SvgFilterBuffer.fromBitmap`（`f_svg/src/SvgFilterBuffer.cj:55-58`）与 `writeTo`（`:86-89`）已有第 5、6 份
- **描述**：改一处格式（例如将来引入预乘 alpha 或改字节序）必须同步 6 个位置，漏改就是「同一张图里 tile 与 offset 结果对不上」这类难查的偏色
- **建议**：在 `SvgFilterBuffer` 加 `internal func copyPixel(from: Int64, to: Int64, source: SvgFilterBuffer)` 或直接复用 `Array<Byte>.copyTo`（`pixels[targetBase..targetBase+4] = source.pixels[sourceBase..sourceBase+4]`），四处统一调用

### [轻微][存量] `tileContentBounds` 计算的 x/y/w/h 只有「是否为空」被使用，额外三个值无消费者

- **位置**：`f_svg/src/SvgFilterPrimitives.cj:444-475`（返回 `[minX, minY, w, h]`）；唯一调用方 `f_svg/src/SvgFilterRenderer.cj:344`（`tileContentBounds(input).size == 0`）
- **来源**：存量
- **判据**：review-checklist §1「读了不用」、§6.4「只判存在却全量扫描」
- **证据**：静态确定 —— 全仓只有这一处调用，且只取 `.size`
- **描述**：函数做完整包围盒扫描（4 个 min/max 更新）却只回答「有没有非透明像素」；调用方因此每次 `feTile` 都要扫满整块区域才能开始平铺
- **建议**：改为 `internal func tileHasContent(input): Bool`，命中第一个 alpha > 0 即返回；若将来需要包围盒裁剪 tile 周期，再单独留 `tileContentBounds`

### [轻微][存量] 测试文件命名与内容不符，个别变量名与实际方向相反

- **位置**：`f_svg/src/SvgFilterPrimitive_test.cj`（同文件含 `SvgFilterPrimitive_test` `:62`、`SvgFilterChainM3_test` `:253`、`SvgFilterPrimitiveUnitsM3_test` `:327`、`SvgColorMatrixValidationM3_test` `:397`）；`f_svg/src/SvgFilterRenderer_test.cj`（含 `SvgFilterBuffer_test` `:32`、`SvgFilterRenderer_test` `:65`、`SvgFilterRegionOrderM3_test` `:261`、`SvgFilterAttributeM3_test` `:285`、`SvgFilterPercentRegionM3_test` `:326`）；`SvgFilterPrimitive_test.cj:79-81`（变量 `horizontalOnly` 实际传 `(0.0, 2.0)`，是**垂直**方向）
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 维护性」
- **证据**：静态确定 —— 文件名与 `@Test` 类名一一对不上；`:79-81` 断言 `x=6` 处 alpha 为 0、`y=6` 处大于 0，正是垂直模糊的特征
- **建议**：按类名拆分/重命名文件；变量改名 `verticalOnly`（或把参数改成 `(2.0, 0.0)` 与名字对齐）

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分没有做改前/改后对照，所有收益均为预期值。

### [CPU] 线性光 ↔ sRGB 转换用 256 项查表替代逐像素 `pow`

- **现状**：`f_svg/src/SvgFilterRenderer.cj:372-416`。`toLinearRgb` / `toSrgb` 对每个像素的 R/G/B 各调一次 `pow`（`linearChannel` `:398-406`、`srgbChannel` `:408-416`），512×512 区域即 3×262144 次 `pow`；输入域只有 256 个可能值
- **方案**：模块级 `let SVG_LINEAR_LUT / SVG_SRGB_LUT: Array<Byte>`（256 项，编译期或首次使用时构建），转换退化为 `lut[pixels[i]]`
- **预期**：把每像素 3 次超越函数调用换成 3 次数组索引；`linearRGB` 文档的滤镜链入口/出口各一次全图遍历，理论上该段耗时降到「纯内存搬运」量级（具体比例待测）
- **代价**：多 512 B 常驻；`pow` 的舍入需与现实现逐值对齐（256 项可穷举验证，误差 0）
- **验证**：`cjpm bench -O2` 同输入 512×512 `color-interpolation-filters="linearRGB"` + `feOffset dx=0`，改前/改后各 10 轮取中位数；并逐值断言 256 项 LUT 与现行 `pow` 结果相同
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 模糊的中间表示从 Float64 降到 Float32 / 整数，峰值从 68 B/px 降到约 20 B/px

- **现状**：`f_svg/src/SvgFilterPrimitives.cj:61-75`（`bytesToFloat`：每像素 4 个 Float64 = 32 B）＋ `:77-141`（卷积输出又一整份 32 B）＋ 输入缓冲 4 B，峰值约 **68 B/px**。按 `maxPixels` 默认 64 Mi（`f_svg/src/SvgBitmap.cj:230`）计算，单次模糊峰值约 4.3 GB
- **方案**：`Array<Float32>`（34 B/px 峰值）或「水平方向先转 Float、垂直方向边算边累加」的单缓冲实现；亦可改三次 box blur 近似，全程只保留两份 UInt8 缓冲
- **预期**：峰值降到 1/2 ~ 1/17；σ 较大时顺带把 O(w·h·r) 降到 O(w·h)
- **代价**：Float32 累积在 σ 大时有量化误差（需与 Float64 结果逐像素比对，容差 1/255）；box blur 近似改变输出（视觉等价性需人工/黄金图确认）
- **验证**：`getAllocatedHeapSize()` + RSS 峰值，512×512 与 2048×2048 两档，σ=8/32；对照现行实现的逐像素差异分布
- **证据状态**：`已有基线（`doc/perf-baseline.md:62`：512×512 σ=8 约 0.5 s 净耗时、单次运行；`doc/perf-baseline.md:80`：512×512 order=3 卷积约 151 ms）`，无改后对照

### [CPU / 堆] `bilinearSvgSample` 每像素分配 4 个数组

- **现状**：`f_svg/src/SvgFilterPrimitives2.cj:1332-1374`。每次采样 `Array<Byte>(4)`（`:1333`）+ `columns` / `rows` / `weights` 三个 4 元素数组（`:1340-1347`）⇒ 每个输出像素 4 次堆分配；`displacementFilterBuffer`（`:1290-1329`）逐像素调用它，512×512 即 104 万次分配
- **方案**：改标量写法（4 个局部变量 × 4 个抽头内联展开），返回值改成写入调用方缓冲的 `addSample` 或返回 `(Byte, Byte, Byte, Byte)` 元组
- **预期**：去掉每像素 4 次分配与随之而来的 GC 压力；`feDisplacementMap` 的耗时与分配量应同步下降
- **代价**：可读性略降；需保持越界抽头按权重 0 处理的语义不变
- **验证**：`cjprof heap` 看分配量，`cjpm bench -O2` 512×512 `feDisplacementMap scale=10` 改前/改后中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `feTile` 的存在性检查提前返回

- **现状**：`f_svg/src/SvgFilterPrimitives.cj:444-475` 全量扫描计算包围盒，调用方只判空（`f_svg/src/SvgFilterRenderer.cj:344`）
- **方案**：新增 `tileHasContent`，命中首个 `alpha > 0` 即返回（见「发现」同名条目）
- **预期**：无内容区域仍 O(n)，有内容区域从 O(n) 降到 O(1)~O(n/2)；`feTile` 前置检查的耗时基本消失
- **代价**：无（调用方不需要包围盒）
- **验证**：`cjpm bench -O2` 1024×1024 `feTile`，改前/改后中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `named` 只保留被引用或显式命名的结果

- **现状**：同「发现」第 2 条，`f_svg/src/SvgFilterRenderer.cj:202,246-247`，峰值 = 原语数 × 区域 × 4 B
- **方案**：先扫 `filter.primitives` 收集所有 `inSource` / `in2` 引用名，执行时只保留「显式 `result` 且被后续引用」的缓冲，其余用完即丢
- **预期**：典型 3~5 原语链的峰值缓冲数从 N 降到 1~2（`SourceGraphic` + 当前结果）
- **代价**：需要一次 O(N) 预扫；若文档 `in` 引用链是动态拼接（不可能，属性静态）则无风险
- **验证**：`getAllocatedHeapSize()` 峰值 + 512×512/4096×4096 两档、5 原语链；同时跑现有 `chainDeterminism` 用例确认像素不变
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 整缓冲复制改用批量拷贝

- **现状**：`f_svg/src/SvgFilterRenderer.cj:106-112`（空滤镜链逐字节复制整幅位图）、`SvgFilterBuffer.copy`（`f_svg/src/SvgFilterBuffer.cj:67-73`）、`offsetFilterBuffer` / `tileFilterBuffer` / `feImageFilterBuffer` 的逐像素循环
- **方案**：对整幅/整行区间用 `pixels[a..b] = other[a..b]`（底层 `memcpy`），逐像素循环只保留给需要坐标变换的原语
- **预期**：空滤镜链从 4×w×h 次逐字节索引降到一次块拷贝；大画布下该段耗时接近内存带宽
- **代价**：无（语义完全等价）
- **验证**：`cjpm bench -O2` 2048×2048 空滤镜链 + `feOffset dx=0`，改前/改后中位数；逐像素断言输出一致
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 高斯模糊是滤镜链的主要自耗时项（`convolveHorizontal/Vertical`，含 `bytesToFloat`/`floatsToBuffer`） | `f_svg/src/SvgFilterPrimitives.cj:61-141` | 自耗时占比与调用路径 | `cjprof record` 跑 512×512、σ=8、`samplesPerPixel=1`，取 top-N self time |
| 2 | `toLinearRgb`/`toSrgb` 的 `pow` 在该段占 90% 以上 | `f_svg/src/SvgFilterRenderer.cj:372-416` | 分段计时 | 在 `apply` 里对 `toLinearRgb`/`toSrgb` 各打一次计时，512×512 与 2048×2048 |
| 3 | `bilinearSvgSample` 的每像素 4 次分配使 GC 占 `feDisplacementMap` 耗时的可观比例 | `f_svg/src/SvgFilterPrimitives2.cj:1332-1374` | 分配量与 GC 时间 | `cjprof heap` + 512×512 `scale=10`，对照分配次数与 GC 次数 |
| 4 | `named` 保留中间缓冲把峰值推到 maxPixels 量级（默认 64 Mi ⇒ 单缓冲 256 MB） | `f_svg/src/SvgFilterRenderer.cj:202,246-247` | 峰值 RSS | 4096×4096 画布 + 5 原语链，`getAllocatedHeapSize()`/RSS 采样 |
| 5 | 模糊的 Float64 中间数组适合 local mode（`bytesToFloat` 产物与卷积输出都不逃逸出 `blurFilterBuffer`） | `f_svg/src/SvgFilterPrimitives.cj:31-38` | 改前/改后峰值内存 | 开 `--experimental --enable-local-mode`，同输入比对 `getAllocatedLocalObjectSize()` 与 RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgFilterPrimitive_test.cj` | .cj | ✅ | 4 个测试类；命名/变量名问题见「发现」#17 |
| 2 | `f_svg/src/SvgFilterPrimitives.cj` | .cj | ✅ | 模糊/偏移/flood/混合/合成/merge/颜色矩阵/tile/dropShadow 全部实现 |
| 3 | `f_svg/src/SvgFilterPrimitives2.cj` | .cj | ✅ | 枚举、`feFunc*`、9 个原语属性模型与实现；见 #1/#5/#7/#8/#10/#12/#13/#15 |
| 4 | `f_svg/src/SvgFilterPrimitives2M4_test.cj` | .cj | ✅ | 含 `m4*` 测试夹具（被 `SvgFilterNoiseM4_test` 复用）；nan 用例走错分支见 #12 |
| 5 | `f_svg/src/SvgFilterRenderer.cj` | .cj | ✅ | 区域换算、链执行、原语分派、linearRGB 转换 |
| 6 | `f_svg/src/SvgFilterRenderer_test.cj` | .cj | ✅ | 5 个测试类；命名问题见 #17 |
| 7 | `f_svg/src/SvgFilterTileChainM3_test.cj` | .cj | ✅ | tile 周期/空输入 warning，与实现一致 |
| 8 | `f_svg/src/SvgFilter_test.cj` | .cj | ✅ | 元素模型属性与缺省值，与 `SvgFilterPrimitive.cj` 一致 |
| 9 | `f_svg/src/SvgFont.cj` | .cj | ✅ | 字体接口 + 注册表；别名 stretch 问题见 #9 |
| 10 | `f_svg/src/SvgFontDetailsM6_test.cj` | .cj | ✅ | stretch/small-caps/size-adjust/装饰线用例，与实现一致 |
| 11 | `f_svg/src/SvgFontFeatureApplyM6_test.cj` | .cj | ✅ | liga/clig/hlig/kern 用例，与实现一致 |

合计：`.cj` 11 个 / `.md` 0 个 / 共 11 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：模糊边界、dropShadow 区域外扩、turbulence 坐标、别名 stretch；语言特性：数字列表引用逸出；可读性：过时注释、测试命名。安全性：滤镜区域有 `maxPixels` 预检查、`feImage` 只走 `SvgImageResource`（`data:`/provider），本部分无注入面；未发现凭据/日志泄漏 |
| §1 死代码 | 3 | 已逐个核对本部分全部 `private`（`gaussianKernel`/`bytesToFloat`/`floatsToBuffer`/`convolveHorizontal`/`convolveVertical`/`colorMatrixFor`/`positiveMod`/`filterAxis`/`primitiveSecondInput`/`transparentBuffer`/`applyFilterPrimitive`/`toLinearRgb`/`toSrgb`/`linearChannel`/`srgbChannel`/`dropShadowRegionMargin`/`transferChannel`/`readDisplacementFloat`/`convolveSample`/`positiveSvgMod`/`clampSvgIndex`/`perlinSvgNoise`/`svgGradientDot`/`svgNoiseHash`/`bilinearSvgSample`/`nearestStretch`/`key`/`stretchKey`/`m4ColorLevel`/`joinTestStrings`/`m6*`）与 `internal`（`blurFilterBuffer`/`offsetFilterBuffer`/`floodFilterBuffer`/`blendFilterBuffer`/`compositeFilterBuffer`/`mergeFilterBuffers`/`colorMatrixFilterBuffer`/`tileFilterBuffer`/`tileContentBounds`/`dropShadowFilterBuffer`/`readSvgNumberList`/`writeSvgNumberList`/`writeSvgNumberArray`/`componentTransferFilterBuffer`/`morphologyFilterBuffer`/`convolveFilterBuffer`/`turbulenceFilterBuffer`/`displacementFilterBuffer`/`feImageFilterBuffer`/`SVG_FE_MORPHOLOGY_*`/`attachImages`/`hasFamily`/`resolveDetailed`/`normalizeSvgFontFamily`/`parseCssLocalFontFamilies`/`splitSvgFontFamilies`/`trimAsciiQuotes`/`SvgFontMatch`）符号，全部有仓内调用者；`stitchTiles`/四个 `fromNameOrWarn` 属未接线（#10/#11）；不可达校验见 #12；`tileContentBounds` 的死输出见 #16 |
| §2 重复逻辑 | 3 | 已把本部分 40+ 个函数体压成「输入→输出→副作用」两两比对：`positiveMod`/`positiveSvgMod` 完全同义（#15）；`stdDeviation` 解释 5 份（#5）；`flood-color` 解析 2 份（#6）；像素搬运 4 份（#16）。`linearChannel`/`srgbChannel` 是互逆公式不算重复；`SvgFontRegistry.key`/`stretchKey` 键格式不同不算重复；测试夹具 `solidBuffer`/`m4Buffer`/`m4FillRect` 相似但属测试准备代码，按清单误报边界不计数 |
| §3 空实现 | 1 | `case _ => input.copy()` 静默直通（#14）；其余 `case _ => ()` 均为「非目标子节点忽略」，解析阶段已有 warning（`SvgFilter_test.nonPrimitiveChildWarns`）。无空函数体、无 TODO/FIXME |
| §4 栈溢出 | 0 | 本部分无递归：`resolveDetailed` 只向 `base` 单向委托，`derived` 每次新建实例，链深由调用方构造且无环；滤镜链是 `while` 迭代。无自引用结构遍历 |
| §5 OOM | 2 | σ 无上界（#1，严重）；`named` 线性叠加（#2，一般）。区域本身有 `maxPixels` 预检查且先做除法再分配（`SvgFilterRenderer.cj:127`） |
| §6.1 热点瓶颈 | 0 | 未提供 profile；`doc/perf-baseline.md` 只有单次整轮数据（512² σ=8 约 0.5 s、卷积 151 ms、湍流 96 ms），无自耗时占比 ⇒ 已列入「待验证假设」#1~#3，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享可变全局状态 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 Future、无任务提交，滤镜链为单线程顺序执行 |
| §6.4 低效算法 | 1 | `tileContentBounds` 只判存在却全量扫描（#16，并给出提前返回方案）；卷积/形态学/湍流均有核尺寸与采样预算上限，复杂度受控 |
| §7 降堆内存方案 | 2 | 模糊 Float64 中间表示（68 B/px）、`named` 生命周期；另见「优化可行性方案」 |
| §8 降 CPU 方案 | 3 | 256 项 gamma LUT、`bilinearSvgSample` 去分配、裁剪/复制批量化 |
| §9 local mode 可行性 | 1 | `blurFilterBuffer` 内两个 Float64 数组不逃逸，是唯一候选；无峰值内存对照 ⇒ 只进「待验证假设」#5，未写成建议 |
| §11 现有代码的 BUG（存量） | 12 | 本轮读到的 4 个实现文件的边界/空值/错误处理/资源已逐函数核对；无文件句柄与 CFFI；存量条目见「发现」全部 17 条（来源均为存量） |
| §12 并发安全与锁粒度 | 0 | 无静态可变全局状态；`SvgFilterRenderer.warnings` 与 `SvgFontRegistry` 的各 `HashMap` 都是实例字段，仓内创建点均在单次渲染内（`SvgRenderer.cj:141` 每渲染 `attachImages`，`SvgFontRegistry.defaultRegistry` 每次新建）⇒ 线程封闭。未声明线程安全：`SvgFontRegistry.register` 必须在发布前完成，属待确认契约（不计数） |
| §14 功能完备性与 README 覆盖 | 2 | `stitchTiles` 承诺未接线（#10）；`fromNameOrWarn` 未接线（#11）。README 本部分无 `.md`，公共 API 覆盖由其他部分核对；另有两点**范围外提示**：①`in="SourceAlpha"` 未支持（全仓 grep 零命中，`named` 只注册 `SourceGraphic`），真实文档里 feDropShadow/形态学常用 SourceAlpha，会退化成透明 + warning；②各原语子区域（`x`/`y`/`width`/`height`）在模型层不存在（`SvgFilterPrimitive` 只有 `in`/`result`），`feImage`/`feTile` 只能铺满滤镜区域 |
| 文件覆盖（§13 等） | 11/11 | 本部分无 `.md`，§13 文档一致性不适用；11 个 `.cj` 全部读完 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 9 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 2 / 4 |

存量缺陷 17 条，是否纳入修复待用户决定。

## 总评

这部分是 f_svg 滤镜链的「执行内核」：原语实现本身写得相当克制——每个原语都「读入缓冲、返回新缓冲」，不原地改；`feMorphology`/`feConvolveMatrix`/`feTurbulence` 都主动设了核尺寸、采样预算、octaves 上限；区域先做除法判定再分配（`SvgFilterRenderer.cj:126-132`）；非法值普遍回退 + warning；测试覆盖也扎实（颜色矩阵、合成算子、edgeMode、morphology 半径、turbulence 确定性、区域百分比在用户空间求值等都有对应用例）。

主要风险集中在两处：

1. **资源拒绝路径不完整**。高斯模糊是整个模块唯一没有上限的核（严重 #1），σ 直接来自文档，`ceil(3σ)` 同时决定分配与计算量；这条路径与同文件其它原语的防护风格明显不一致，属于该补的一块。再加上 `named` 无差别保留中间缓冲（#2）与 Float64 中间表示 17 倍膨胀（优化方案），大画布 + 多原语时峰值内存会到 GB 级。
2. **同一语义散落多份**。`stdDeviation` 五处、`flood-color` 两处、像素搬运六处、`positiveMod` 两份，其中 `stdDeviation` 已经开始漂移（缺省 0 / 2 两派），是典型的「改一处忘一处」隐患；`feDropShadow` 的区域外扩漏乘 `primitiveUnits`（#4）就是这种分散带来的实际 bug——同一属性在「算区域」和「做偏移」两处用了不同单位假设。

`SvgFont.cj` 的问题更轻：别名解析丢弃 stretch（#9）会让 `@font-face` + `font-stretch` 的组合选错字面并多做一次合成缩放，其余（alias 未注册 warning、`registeredFamilies` 只记 family、`nearestStretch` 平局取先注册者）都与注释自洽。

阻塞项：只建议把 #1 与 #4 作为本轮必修（前者是 DoS/OOM 面，后者是可见的渲染裁切）；#2/#7/#9 可排期；#5/#6/#8/#10/#11 属结构治理与接线，可与后续滤镜增强一起做；其余轻微项（注释、命名、重复实现）随手清理即可。
