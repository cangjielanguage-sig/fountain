# Fountain JIT · M1 字节码规格

> 版本 v0.18.18（评审稿） · 2026-09-16（v0.3：一致性修订 + 冻结决策 ③；v0.4：区间 / Decimal 算术 / 数值互转 / Duration·DateTime 算术 / 插值串 / 类型化局部变量（明确赋值 + 空安全）/ 句柄 Marshal 与逃逸（§8.1）/ 统一函数包装 call\<T\>（§8.2）/ 源码入口与只编译一次去重（§8）/ 调用契约与线程模型（§8.3）/ 小数字面值与超 Int64 整数字面值 → Decimal、显式数值转换（§11.9）/ 句柄类型映射标准库（§3.2，Decimal = std.math.numeric.Decimal §9.12），激活窗口分配机制；v0.4.1：宿主句柄槽实现冻结——ID 形态（决策 ④）；v0.4.2：`call<T>` 逃逸槽自动回收（§8.1 规则 6）；call 清理 try/finally 化、16 中途边界与三缓解手段 + capacityLimit、ctx 内存机制与 Marshal 自实现依据、helper 封闭白名单与准入准则（§4/§6/§8.1/§8.2/§9.6）；v0.5：容器变更（List add/insert/set/remove、Map put/remove，0xA1/A3 启用 + 0xAB–AF）、常量容器写保护（错误码 20）、变更型函数 deopt 禁令（§9.15）、for-in 全类型规范降低（含 Map 键快照 MAP_KEYS，§5/§11.9）；v0.6：字符串切片/替换（STR_SUB/STR_REPLACE，0xB8/B9）、正则字面量 `/…/flags`（新类型 Regex = token 8 / LocalType 9 / 常量 kind 10，加载期一次编译、跨调用复用，REGEX_IS_MATCH/FIND = 0xBA/BB）、for-in 源语言形式与仓颉对齐（含 where）、多重赋值/变量交换降低——同时赋值语义（§5）；v0.7：被编译代码格式声明（lambda 源入口，§8.0）、`recursive` 自递归关键字（降低为 CALL_FUNC）、LocalType 10/11（List/Map 仅参数槽）、FuncEntry.retType（签名入字节码，verMinor=4）；v0.8：编译器门面 Compiler 类与预定义函数注册（§8.4——user helper 通道 hid[0x0100,0xFFFF]、编译期名字解析与未注册错误 SourceCompileException、分发边界），verMinor=5；v0.9：嵌套闭包（词法绑定 + 按值捕获快照）、recursive 绑定最近层词法闭包、立即调用 IIFE、源码注释（§8.5；无 .fbc 格式变更）；v0.10：first-class 闭包值（闭包表达式求值/变量绑定与调用，§8.6——closure_new/CALL_CLOSURE/LOAD_CAP、token 9、LocalType 12、ctx.fnTable、词法绑定模型统一升级为闭包值模型，verMinor=6）；v0.11：正则操作符 `~` / `!~` / 全局与第 n 替换（§11.9，H58/H59，优先级高于加减左结合，verMinor=7；错误即终止（fail-fast）语义显式化（§0/§2/§5，CALL_HELPER_V 自动 CHECK_ERR 明确）；ctx 非托管内存配对释放 finally 义务（§8.2）+ M1 无单元卸载注记（§8.1）+ T27 内存安全）；v0.12：recursive 值化——`let x = recursive` 自引用闭包值（闭包层 = LOADL 0；顶层 = 隐藏适配器 FuncEntry + closure_new，§8.0/§8.6），嵌套闭包经变量捕获递归调用任意外层（§8.5）；无 opcode/helper/格式变更；v0.12.1：全文档审计修正——分配型清单补 H54 closure_new（§1/§6/§8.1）、§0 I8/简化 3/适用范围随 v0.10–v0.12 同步、§2 -1 行随 §9.15 扩展同步、§8.0 源入口参数禁用 Closure（Marshal 表无行，恒不可供给）、§8.3 取消及时性边界、T13 计数 13 种；M2 CALL_HOST 议题清单（八项困难 + 三档演进路径）备案于 §6；v0.13：单元卸载——JitFunction.unload（状态机 Ready→Unloading→Unloaded、活跃调用排空、资产清点与释放顺序、常量同 ID 契约限定单元存活期，§8.7）、调用已卸载单元 → 19（§2/§8.2 入口断言）、T29；无 opcode/helper/格式变更；v0.13.1：目录审计修正——§8 JitFunction 骨架补生命周期成员 ⑤（unload/isUnloaded）、§8.2 调用六步补第 0 步入口断言、A 常量槽释放措辞精确化（唯一释放点 = 单元卸载，§8.7）；v0.14：字符串字面量形态（§8.8）——多行 `'''`/`"""`（仓颉基础规则）、原始串（`#`×n 定界，仓颉一致）、`>|` 每行锚定扩展（前缀一律忽略）、换行规范化（CRLF/CR→LF）、插值适用边界（原始串不适用）；无 opcode/helper/格式变更；T42；v0.14.1：`>|` 锚定放宽——无 `>|` 的行（含空白/非空白）**整行原样保留**（`MissingMarginMarker` 取消）；v0.14.2：`>|` 标记不进入字符串内容显式化——纯定位语法，切分时被消耗，产物不含该标记（单独 `>|` 行 → 空串）；v0.14.3：`>|` 有效标记收紧——仅行内**首个非空白位置**的 `>|` 才生效（前导仅缩进空白；非空白符之后的 `>|` 是字面内容、既不截断也不触发锚定模式）；v0.14.4：非标记情形固化显式示例——`>>|`/`a>|b`/`|>|` 中 `>|` 前有任意非空白字符即为字面内容（不消耗、不截断、不触发锚定模式，行为同 v0.14.3）；v0.14.5：并发安全补强——§8.3② 增适配器注册表同步行、§8.4 增 user helper impl 并发调用义务、§8.7 增 unload vs compile（Unloading 期间）阻塞重编语义（并发与序贯等价）；v0.14.6：cause 通道调用私有明确——§8.4（并发失败调用的 code/site/cause 互不串扰）；v0.15：String 重复 `s * n`（STR_REPEAT 0xBC/H60）、DateTime 差 `dt1 − dt2 → Duration`（DT_DIFF 0xBD/H61，自 M2 提前）、n 位置运行期自动窄化（F64/DEC → Int64，含 `d / n`；仅限 n 位置）；verMinor=8；T43；v0.15.1：if 值/语句双用法类型规则——形式按使用位置判定；值用法（典型 = 变量赋值）要求全分支类型逐位一致、语句用法不受限（前端语义，无字节码变更）；v0.16：Map for-in 双快照降低——`MAP_KEYS`（0xAF/H49）升级为单遍 `toArray()` 拆分（键列表 + 值列表挂起）、新 `MAP_VALUES`（0xBE/H62）登记值列表；迭代视图完全冻结（零逐键查找、无 5 场景）、每执行 2 槽；verMinor=9；T45；v0.16.1：Map for-in 改**惰性单遍迭代器**（取代同轮 v0.16 双快照）——0xAF `MAP_KEYS`→`MAP_ITER_BEGIN`（H49 重定义、移出分配型）、0xBE `MAP_VALUES`→`MAP_ITER_STEP`（`u8 mode`；H62 重定义）；新增错误码 **23**（迭代中修改同一 map，对齐 std CME）；**无新增 helper 槽位**（M2/M3 编号不变）；每执行 0 槽；v0.16.2：§8.5 逃逸括注精确化——「向上返回」移出禁止例（与 §8.6 对齐：禁止仅跨桥/存容器；链内返回为允许面；纯显式化、无行为变更）；v0.16.3：§11.9 替换段 `/` 个数澄清——`//` = 无 flags 字面量闭合符 + 开启符相邻（非独立符号）；带 flags 字面量（`/[a-z]/i/s/r/g`）与 Regex 变量（`let re = /\s/` → `re/s/r/g`）均为单 `/`；LHS 括注更新为「字面量常量或 Regex 局部变量」（§11.7）；v0.16.4：示意记法修正——表格与 §5 摘要的 `re//s/r/g` 改为 `re/s/r/g`（`re` = Regex 表达式占位符，分隔符恒单 `/`；无 flags 字面量代入后闭合符与分隔符相邻呈 `//`，如 `/\s//s/r/g`，非分隔符翻倍）；v0.16.5：std API 事实核对修正——`HashMap` 无 `put` 方法：写键 = `add(key, value): Option<V>`（覆盖并返回旧值；不存在 → None）、删键 = `remove(key): Option<V>`（返回被删值；不存在 → None）；§6 变更型 helper 映射句、§9 附则 15、§11.9 迭代段、T19/T45 相关表述同步；其余 std 引用（ArrayList 签名、`HashMap.iterator()`、CME 转码）核对无误；无格式/语义变更）；v0.17：① **Regex 互操作开放**——可作参数/返回（§8.0 参数面、§11.7 LocalType 9 与 retType、§8.2 Marshal/解包表 +Regex、§3.3/§11.9 同步）；新增 **`fountain::f_regex` 字符串扩展 `regexStr.regex()`** 运行期构造 Regex（新 opcode `STR_TO_REGEX`=0xBF、helper H69 `str_to_regex`；非法/空 pattern → 14；分配型）；**verMinor=10**（新增 opcode/helper）；② **`recursive` 自动尾递归优化**——尾位置自递归降为「实参逆序 `STOREL` + `LOOP_BACK <入口>`」帧复用回边（不增长栈、安全点照常；无新 opcode——纯前端降低）；T46/T47；v0.18：**容器自建开放**——空字面值 `[]`/`{}` = 运行时构造（既有 A0/A2 **原地启用** `MAKE_LIST`/`MAKE_MAP` + helper H70/H71；分配型、可变、不进常量表；非空字面值维持常量模型）+ **List/Map 可声明为局部**（LocalType 10/11 全槽位）；**verMinor=11**；T48；并修正 §3.2 类型表遗留表述（Regex 来源）；v0.18.1：**字面值变量返回明确化**——任意（M1）字面值类型声明的变量均可作返回值（含**非空容器字面值常量**：交付宿主 = 共享只读对象（零拷贝）、ID 跨调用稳定、D 路径对路径 A 为 no-op；闭包除外）；§3.3/§8.0/§8.1/T48 同步；无格式变更）；v0.18.2：capacityLimit 调整语义统一——§9.6 缓解手段 1 与 §8.1 API 注释对齐（运行中调大即时生效、调小不追溯已占用槽；删除旧「须在加载前调整」矛盾句）；无格式变更）；v0.18.3：措辞修正——§6/§9.6「表达全局上限」→「句柄表全局上限触顶」（原措辞「表·达」连写易误读为「表达」，§9.6 并缺主语「句柄」；纯措辞、无行为变更）；v0.18.4：hwCap 初值统一——**有分配单元恒 1024**（2^10；取代「无分配循环精确上界/含循环静态估计」双轨，编译器不再做槽需求分析）；无分配单元仍 0；上限 capacityLimit（2^20）不变；§1/§9.6/T28 同步；m2 v0.8.4 引用同步；无格式变更）；v0.18.5：`HandleTable.initialCapacity` 开放——窗口初始容量为宿主可配置（默认 1024；可在调用前调整、对之后开始的调用生效；无分配单元仍 0）；`capacityLimit` 语义不变；§1（ctx 表 + 句柄窗口语义）/§8.1/§8.2（桥义务：hwBase/hwCap 写入明文化）/§9.6/§12 同步；m2 v0.8.5 措辞同步）；v0.18.6：§8.6 逃逸禁令设计理由成文——四条硬约束（窗口生命周期 §8.1 / 桥封闭性 §8.2.1 / 单元存活耦合 §8.7 / 确定性与重放 I8）+ 配套与术语注（与 §8.1「逃逸（D 路径）」同名反义）；§8.5 交叉引用同步；纯增注、无行为变更）；v0.18.7：§8.6 补后档指针两处（逃逸禁令行 + 设计理由「配套」句 → `jit-bytecode-m2.md` §13 第 8 项：逃逸闭包回桥草案——仅跨桥返回方向、存容器维持禁止）；纯增注、无行为变更）；v0.18.8：§8.5「M2 边界」修订（闭包逃逸仅"跨桥返回"方向自 M2 开放）+ §8.6 两处指针改指 m2 §14——逃逸闭包回桥（返回嵌套闭包）转为 **M2 交付**（同批：m2 v0.8.8 §14 增篇）；纯表述与指针、无 M1 行为变更）；v0.18.9：§8.8 增「异种引号内容规则」——与定界引号不同种的引号（含任意连续串）为有效内容、不参与定界配对（`'"aa"'` 的 `"`、`"'aa'"` 的 `'`；单行与多行均适用；同种引号规则不变；原始串不受影响）；T42 补项；语义明确化、无格式变更）；v0.18.10：§9.6 条 6 补 `initialCapacity` 选值依据（调用级不预分配、仅是扩容触发点；1024 覆盖常见单调用峰值量级；与 2^20 相差 1024 倍；运行期可调）；纯依据注记、无行为变更）；v0.18.11：`initialCapacity` 默认值 1024 → **128**（2^7）——依据修订：常见单调用分配为个位到十位数、128 留 4–10 倍余量并覆盖小循环（≤128 次迭代）；§1/§8.1/§9.6/§12 同步；m2 v0.8.9 同步；无格式变更）；v0.18.12：§9.6 明确**扩容倍率 = 倍增（×2）**（以 `capacityLimit` 封顶；单调用扩容事件 ≤ log2 上取整——默认 128 → 2^20 为 ≤ 13 次；松弛有界 `hwCap ≤ 2 × hwTop`；表物理容量宿主自管）；语义明确化、无格式变更）；v0.18.13：JIT 指令集支持表述修订——「JIT 仅 Linux x86_64 / aarch64」统一改为「**JIT 仅 Linux；指令集支持范围跟随仓颉 SDK for Linux**（当前 x86_64 / aarch64；SDK 扩大支持范围时本实现**随之扩大**）」——覆盖 §0 平台范围/冻结决策 ②/执行模型、§8 引擎选择（管线注释 + 段落）、§9 附则 10、§12 标题 + §12.1、§13.1 注 + §13 原则 4 + §4 原则表；当前支持集与行为不变）；v0.18.14：**OPCODE_TABLE 全量显式化**——0x00–0xFF 共 256 项不留空洞（98 个未分配槽补 `OP_RSVD`/CAT_RSVD；0xC0–FF 为 M2 规划预留区、归 RSVD）；顺带修正 0xBE `OP_MAP_ITER_STEP` len 1→2（`u8 mode`，违反校验 2 的笔误）；§10.1 RSVD/FORBID 归类、§10.3 导语与校验 1 措辞同步；行为不变（未分配槽发射仍 `ERR_NOT_IMPL`））；v0.18.15：**String 双向混合加法**——`s + x` / `x + s`（x = 任一可文本化类型，TO_STR 标签集 t∈0–8）经 `TO_STR` + `STR_CAT` 降低为 String 连接（复用既有指令；无新 opcode/helper、无 .fbc 格式变更、无新错误码）；Closure/容器/Unit 等非标签类型 → 编译错误（与插值同界）；§11.9 量纲约定 + 新冻结条、§5 A4/B7、§9 附则 13、§11.8、T11 同步）；v0.18.16：**DateTime TO_STR 改为本地时区呈现**——按宿主系统当前时区折算（偏移含夏令时；零偏移输出 `Z`、否则 `±HH:MM`；极限值 ISO 扩展年份）；DateTime 值/`DT_FIELD`/errCode 11 域恒 UTC 不变；「全表唯一环境相关格式项」定性；§11.9（DateTime 行 + 本地化注 + 块标题）、§11.4（「时间值仅 UTC」条）、§11.1 P3、§6 准入准则 ① 例外、§11.8 例外、T11 固定 TZ 同步）；v0.18.17：**Duration TO_STR 对齐仓颉**——`std.core.Duration.toString()` 语义逐字节一致（`[-]` + d/h/m/s/ms/us/ns 非零分量、零分量省略、全零 `0s`、负值 `-` 前缀；例 `1h2m3s4ms5us6ns`）；取代旧 `PT{h}H{m}M{s}.{nnnnnnnnn}S` 形态；§11.9 TO_STR 行、T11 同步）；v0.18.18：**Regex 字面量 flags 顺序无关**——`i/m/u` 任意排列、重复幂等（加载期归一为位域 bit0/1/2；顺序与重复不进入任何可观察语义：去重键/TO_STR 输出/匹配行为）；非法字符仍加载期 14；§3.3（字面值清单行 + 正则字面量段）、§11.5 kind 10、§11.9 TO_STR Regex 行（改「输出规范序」措辞）、T20 同步）
> 适用范围：M1 —— 纯计算 + 白名单值分配与容器自建/变更（§9.15；空容器构造 v0.18）+ 类型化局部变量（§11.7）+ first-class 闭包与自引用（§8.5–8.6）+ 正则字面量与操作符（§3.3/§11.9）+ 多重赋值（§5）+ 预定义函数（§8.4）+ 字符串重复与日期差（§11.9，v0.15）、不使用宏、无 JIT 级 try-catch（字节码无 handler 表、机器码不抛不展开；异常仅存在于宿主边界：helper 内转码 §6、桥的转换 §8）
> 平台范围：**字节码跨平台**（Windows / Linux / HarmonyOS / macOS）；**JIT 仅 Linux**——指令集支持范围**跟随仓颉 SDK for Linux**（当前 SDK 仅 x86_64 与 aarch64，故当前后端为这两种；SDK 扩大指令集支持范围时，本实现**随之扩大**）
> **冻结决策**：① 32 位宿主不支持（§9 附则 9） ② JIT 仅 Linux、指令集跟随仓颉 SDK for Linux（当前 x86_64 / aarch64），字节码不得含"仅 JIT 可实现"指令（§9 附则 10） ③ 编译粒度为整单元（§9 附则 11） ④ 宿主为仓颉运行时，句柄槽取 ID 形态（§9 附则 14）
> 目录：§0 总览 · §1 ctx · §2 错误码 · §3 帧布局 · §4 入口 ABI · §5 ISA · §6 helper · §7 伪指令 · §8 桥入口 · §9 附则 · §10 opcode 常量表 · §11 跨平台字节码 · §12 JIT 后端（Linux；当前 x86_64 / AArch64） · §13 平台矩阵与差分测试

---

## §0 总览与不变式

**执行模型**：栈式虚拟机字节码是**跨平台唯一产物**，由解释器在所有平台执行；在 Linux 上另有 JIT 后端把它展开为机器码（**指令集支持范围跟随仓颉 SDK for Linux**——当前 x86_64 与 aarch64；SDK 扩大时随之扩大）。机器码**本身不分配**、**不抛异常**、**不做栈展开**，且**永不落盘、永不跨机共享**。

**值分配（I8）与容器变更（v0.5）**：白名单**分配型** helper 可在宿主侧分配**值**（String/Decimal/DateTime/Duration/Range 的运算与转换结果、插值串、**闭包对象**（H54，fnId + 捕获快照，§8.6）、**新建空容器**（H70/H71，v0.18——可变，其变更仍经变更型 helper））；白名单**变更型** helper（H43–H48）是**唯一许可的容器副作用**——修改已存在的 List/Map（含自建容器），仅作用于非常量槽，且语义确定（§9.15）。机器码与解释器核心本身仍不分配、不直接变更。deopt 重放会重新分配**等值**对象——值不可变 ⇒ 可观察语义不变；**含变更型调用的函数禁止 deopt 重放**（§9.15②：H43–H48/预定义 helper/CALL_CLOSURE，汇编期保证重放不可达）。

**错误通道 vs 异常**：字节码与机器码**没有 try-catch**——错误经 ctx 错误槽单向传递（I3/I4：写槽 → CHECK_ERR → BAIL），由桥（宿主代码）在边界转换为仓颉异常抛给调用方（§8）。文档中出现的 try-catch 全部位于宿主侧：helper 内部的异常转码（§6/§9.5）与桥的 errCode→异常转换，均由宿主编译器处理，与字节码/JIT 无关。

**错误即终止（fail-fast，冻结）**：任何错误码写入 ctx 错误槽的瞬间，本次调用的语义即告结束——**自错误点起的剩余指令不再执行**、操作数栈不再消费、无任何字节码/JIT 层的恢复或继续机制；执行控制立即经 `CHECK_ERR → BAIL` 收敛到 epilogue（唯一返回路径，§4），由桥读槽分派（§8）。指令级失败由汇编器自动插入的 `CHECK_ERR` 保证短路（I3），helper 失败由其自动尾随的 `CHECK_ERR` 保证（§5），`CALL_FUNC` 链逐层短路返回（§4）。唯一"失败后继续执行"的形态是 DEOPT(-1) 重放——它不是错误（非异常，§12.6），且含变更型调用的函数重放不可达（§9.15②）。

**八条硬不变式**（违反即编译期报错或加载期拒绝）：

| # | 不变式 |
|---|---|
| I1 | 一切 cell 是 64 位；`Int64` 原值、`Float64` 位模式、句柄是整数 ID（0 = null） |
| I2 | 机器码永不解释句柄内容、永不解引用对象指针 |
| I3 | 每个可失败点后必跟 `CHECK_ERR`；由汇编器自动插入 |
| I4 | 错误只经 ctx 错误槽传递；helper 绝不抛异常（内部 try-catch 转码） |
| I5 | 调用失败时 `rax` 内容未被定义；桥必须读错误槽后再决定是否使用返回值 |
| I6 | 字节码与平台、端序、字长、编译器 ABI 无关；机器码只存在于内存，不作为分发物 |
| I7 | 解释器语义是规范，JIT 是等价加速器：同一字节码 + 同一输入，解释器与两个 JIT 后端的结果、错误码、site 必须**逐位一致** |
| I8 | 分配只经由白名单 helper 产出**不可变值**；机器码与解释器核心永不分配；重放重复分配不改变可观察语义 |

**由此得到的三个简化**：

1. 分配仅产**值**（不可变值 / v0.18 新建空容器）、变更仅经变更型 helper（非常量槽）⇒ 机器码永不持裸指针、无需写屏障。
2. 纯函数（不含变更型 helper）可**自由 deopt / 重放**：失败就退回解释器重跑（重复分配等值对象），语义安全；含变更型 helper 的函数按 §9.15② 禁用全部 deopt 源，重放不可达 ⇒ 变更不会被重复执行。
3. 无宏 ⇒ helper 分派在解释器实现中用条件分支/token 表手写即可，类型集封闭（List/Map/String/Decimal/DateTime/Duration/Range/Regex/Closure）。

---

## §1 ctx 布局（64 B，16 B 对齐，桥分配）

```
off  size 字段      含义
0    8    errCode   0=OK  -1=DEOPT  -2=INTERRUPT  >0=错误码
8    8    site      当前字节码偏移；未设置=-1
16   8    hwBase    句柄窗口起点（本次调用）
24   8    hwCap     窗口初始容量（默认 128；§9.6）
32   8    hwTop     窗口已用数（helper 写）
40   8    fnId      函数 id（桥填，供错误上下文）
48   8    flags     bit0=strictFp  bit1=trace  bit2=hasLoop  ...
56   8    reserved  预留/对齐
```

**句柄槽（8 B，仅 helper 可解释）＝ ID 形态（冻结决策 ④，§9 附则 14）**：槽内为 `idx:u32 + tag:u16 + gen:u16`——`idx` 指向桥持有的**托管对象表**（Cangjie 托管容器，条目即 GC 强引用：对象存活与搬移由仓颉 GC 处理，机器码只见整数 ID、永不接触对象指针），`tag` 用 §6 类型 token 编码（fetch 类型校验依据），`gen` 为表项世代号：表项释放复用时 +1、逃逸期间保持不变（§8.1）——M1 常规路径（常量/参数/窗口）窗口只增不减，不依赖世代校验。`objref`（槽内存裸指针）形态**不采用**：仓颉 GC 为 region 式搬移收集（低占用 region 整体回收搬移），托管对象地址不稳定，裸指针槽在仓颉宿主上不可实现。

**句柄窗口语义**：`[hwBase, hwTop)` 本次调用可见。M1 中窗口**只增不减**；仅白名单**分配型 helper**（§6：H24–H29、H32–H41、H50–H51、H53–H54、H58–H61、H69、H70–H71）可登记新槽，且每次调用至多登记 1 个——其运算结果（不可变值 / 闭包句柄）。**变更型 helper（H43–H48）不登记新槽**——它们修改已存在的容器（非常量槽）。`hwTop == hwCap` 时宿主就地扩容句柄表（§9.6），不因容量失败；**有分配单元 `hwCap` 初值 = `HandleTable.initialCapacity`（默认 128，可在调用前调整）**；无分配单元 `hwCap=0`。

---

## §2 错误码表

**fail-fast 契约（冻结，§0）**：下表任何非零错误码（含 -1/-2 的对应场景）写入 ctx 错误槽的瞬间即**终止本次调用**——自错误点起剩余指令不执行，执行控制立即经 `CHECK_ERR → BAIL` 收敛到 epilogue 返回桥；字节码/JIT 层无恢复机制（try-catch 属宿主/M2）。

```
 0   OK
-1   DEOPT        非异常：类型不符/资源不足 → 桥退回解释器重跑（含变更型调用——§9.15②：H43–H48/预定义 helper/CALL_CLOSURE——的函数重放不可达；防御性出现 → 99）
-2   INTERRUPT    取消/超时 → 桥抛 InterruptedException

 1   ERR_DIV_ZERO
 2   ERR_MOD_ZERO
 3   ERR_OVERFLOW_I64        (含 INT_MIN/-1, INT_MIN 取负)
 4   ERR_IDX_OOB             (下标越界——GET_IDX/STR_AT/STR_SUB；STR_SUB 的 a/b 为码点索引)
 5   ERR_KEY_MISSING
 6   ERR_NULL_HANDLE         (对 null 句柄取用)
 7   ERR_BAD_CAST
 8   ERR_HANDLE_TYPE         (句柄类型不符：helper fetch 与 GUARD_TYPE 共用；7 仅用于 CAST 值转型)
 9   ERR_DEC_RANGE           (DEC_TO_I64 越界——Decimal 任意精度，算术本身无范围溢出)
10   ERR_DEC_DIV_ZERO        (Decimal ÷0，含 0÷0)
11   ERR_DT_RANGE            (DT±DUR 结果超出 DateTime 值域)
12   ERR_DUR_OVERFLOW        (Duration 算术溢出)
13   ERR_FP_INVALID          (NaN/Inf 转整型；F64→Decimal)
14   ERR_ARG_MISMATCH        (CALL_FUNC argc 不符；RANGE_NEW step=0；STR_REPLACE 空模式；正则字面量非法 pattern/flags（加载期）；STR_TO_REGEX 非法/空 pattern（运行期，v0.17）；桥入口断言)
15   ERR_STACK_GUARD         (DEOPT 后解释器余量亦不足、无法重跑时由桥写入)
16   ERR_HANDLE_WINDOW_FULL  (宿主句柄表全局上限——资源耗尽)
17   ERR_EXPLICIT            (源语言 throw；具体码放 site 附加表)
18   ERR_NOT_IMPL            (汇编器遇到未实现特性时主动 bail)
19   ERR_CALL_CONTRACT       (call 的调用契约错误：参数长度/元素类型/返回 T 不符；调用已卸载单元（§8.7）；桥层产生，site=-1，不经字节码执行)
20   ERR_READONLY            (对常量/冻结容器写入——变更型 helper 的目标槽属路径 A，§9.15①)
23   ERR_CONCURRENT_MOD      (for-in 遍历 Map 期间修改同一 map——转码自 std 的 ConcurrentModificationException，对齐仓颉；§11.9)
99   ERR_HELPER_PANIC        (helper 内未识别异常兜底；任何内部异常最终都以此码浮现)
```

**错误码 → 桥侧异常类型映射**（`code → Exception`，桥静态表，无宏）：

| 范围 | 抛出类型 |
|---|---|
| 1–20、23 | `JitException(code, site, fnId, msg)` |
| 99 | `JitException`，msg 前缀 `internal helper failure`，并附 `cause` 原始描述字符串 |
| 0 / -1 / -2 | 不抛：OK 走值路径，DEOPT 走解释器，INTERRUPT 抛 `InterruptedException` |

---

## §3 帧布局

### §3.1 机器帧（固定大小，编译期算出）

```
frameSize = 32 + 8*nLocals + 8*maxStack + 8   // 再向上取整到 16 的倍数

高地址
┌─────────────────────────────┐
│ 调用方帧                     │
├─────────────────────────────┤
│ return address              │  rbp+8
│ saved rbp                   │  rbp+0   ← rbp
│ saved r15（调用方值）        │  rbp-8   ctx 存于 r15 寄存器
│ hwBase 镜像 (i64)           │  rbp-16  调试/安全点用
│ reserved (i64)              │  rbp-24
├─────────────────────────────┤
│ locals[0]  = arg0           │  rbp-32
│ locals[1]  = arg1           │  rbp-40
│ ...                         │
│ locals[nLocals-1]           │  rbp-32-8*(nLocals-1)
├─────────────────────────────┤
│ operand stack 顶 (sp)        │  ← rsp；push 后 [rsp] 即栈顶
│ operand stack ...           │
│ operand stack 底            │  rbp-32-8*nLocals-8*maxStack
└─────────────────────────────┘
低地址
```

- **参数即局部变量**：`locals[0..nargs-1]`，由 prologue 从 `args` 数组拷入；`nargs` 在编译期已知并写入 `LOADL` 范围校验。
- **寄存器名说明**：本节用 x86_64 记法（`rbp`/`rsp`/`r15`）。AArch64 对应 `x29`/`sp`/`x19`，且返回地址在 `x30` 需由 prologue 保存——完整映射见 §12.2、§12.3。帧布局本身**两后端共享**（`frameSize` 统一按 16 字节对齐）。
- **操作数栈向下增长**：`PUSH` = `sub rsp,8; mov [rsp],v`；`POP` = `mov v,[rsp]; add rsp,8`。
- **r15 全程持 ctx**（callee-saved，跨 helper 调用不失效）。**禁止把 ctx 放 rdx/rcx**（caller-saved）。
- 帧内 `hwBase` 镜像仅用于安全点比对，非必需。
- **内存卫生填充（不可观察）**：prologue 将全部非参数局部槽写 0（确定性初始化，不依赖宿主内存残留）。**该零值不是默认值、不可观察**：局部变量实行**明确赋值**（§7 校验 10）——非参数局部在其被读取的所有可达路径上必须已被显式写入，读未赋值局部 = 编译期拒绝；因此填充值永不出现在可观察语义中（差分一致性的保险，而非语义）。
- **空安全（局部）**：句柄型局部（LocalType 4–9、12，参数槽另可 10–11）**恒为有效句柄（≠0），没有空值**；`PUSH_NULL` 不得作为句柄型局部的赋值源（§7 校验 10）。null 只存在于互操作边界（桥参数为 0 → helper 边界报 6）与栈上瞬态值，不进入局部变量。

### §3.2 cell 类型约定（栈/局部槽内都是 64 位）

| 逻辑类型 | 表示 | 说明 |
|---|---|---|
| `Int64` | 原值 | 补码整数 |
| `Float64` | IEEE754 位模式 | 浮点指令以 `movq` 读写，不经 FPU 转换栈 |
| `Bool` | 0/1 | |
| 引用类型（List/Map/String/Decimal/DateTime/Duration/Range/Regex/Closure） | 句柄 ID（正整数） | 0 = null；String/Decimal/DateTime/Duration/Range/Regex/Closure 为**不可变值**（分配型 helper 可产出；Regex 来自常量或 `STR_TO_REGEX` 构造（v0.17）；Closure 由 closure_new 产出，§8.6）；List/Map **可变**——来源 = 参数 / 常量 / 空字面值构造（v0.18）；读恒许可，写**仅经变更型 helper**（H43–H48）且目标不得为常量槽（路径 A → 20，§9.15①） |
| `Unit` | 0 | 无返回值占位 |

**局部变量的静态类型**：每个局部槽的类型由 §11.7 局部类型表声明（v0.4 起），可声明的类型集为 `Int64 / Float64 / Bool / Unit / String / Decimal / DateTime / Duration / Range / Regex / Closure / List / Map`（v0.6；Closure 自 v0.10；List/Map 自 v0.18）；cell 表示不变（64 位），类型表是规范性元数据（详见 §11.7）。局部变量**空安全且无默认值**：必须显式赋值后才能读取（§7 校验 10），句柄型局部恒非空——与仓颉"非 Option 类型无 null"的语义一致。

**std 类型映射（不自定义类型）**：句柄类型的承载实现全部映射到仓颉标准库——`List = std.collection.ArrayList`、`Map = std.collection.HashMap`、`String = std.core.String`、`Range = std.core.Range`、`Duration = std.core.Duration`、`DateTime = std.time.DateTime`、`Decimal = std.math.numeric.Decimal`、`Regex = std.regex.Regex`（v0.6）。全部构造/运算/比较/文本化直接调用对应 std API（helper 实现见 §6；Decimal 上下文约束见 §9.12；正则编译语义见 §3.3）。

### §3.3 常量表（拼装期构造，只读共享）

```
ConstTable
  [0..k-1]  句柄常量: (kind, 宿主对象)   ← PUSH_KH n 使用
  [k..]     元信息: 源位置、站点描述、函数名
```

字面量 `[1,2,3]` / `{k:v}` / `"abc"`（字符串三形态：单行 `'…'`/`"…"`、多行 `'''`/`"""`、原始 `#`×n 定界——§8.8，v0.14） / `Decimal(...)`（**无后缀小数字面值即 Decimal**，§11.9）/ 区间 `a..b` / `a..=b`（可带 `: step`，§11.9）/ **正则 `/pattern/flags`**（v0.6；flags ∈ `i m u` 任意组合且**顺序无关**（v0.18.18），见下）**（非空形态）全部在拼装期由宿主构造一次**，登记入常量表并由 ctx 外部持有强引用（唯一例外：空容器字面值 `[]`/`{}`——v0.18 起为运行时构造，见下）。语义：**字面值共享只读**——常量容器被变更型 helper 写入 → `ERR_READONLY(20)`（§9.15①，跨调用共享 ⇒ 写入会破坏可重复调用）；如需"每次求值可变副本"，由桥在调用前显式深拷贝（`CallContext.literalCopy`，M2）。**空容器字面值 = 构造（v0.18，冻结）**：`[]` / `{}` 每次求值调用 `MAKE_LIST`/`MAKE_MAP`（H70/H71，分配型）新建**可变**空容器——窗口分配（**非路径 A**）：可经变更型 helper 写入、可作参数/返回值流转；**不进常量表**；必须有上下文类型（局部声明注解 / 实参签名），无法推断 → 编译错误。非空字面值维持常量模型（共享只读、写 → 20）。**字面值声明的变量可返回（v0.18.1，冻结）**：任意 M1 字面值类型声明的变量（`let x = <字面值>`）均可作返回值交付宿主——标量/不可变值照常；**非空容器字面值（常量，路径 A）**亦可：经三态收尾 D 路径交付的即**共享常量对象本身（零拷贝）**（§8.1 规则 1 对本情形为 **no-op**），ID 跨调用稳定（规则 4；有效期 = 单元存活期——卸载后作废，§8.7）；宿主按**只读契约**使用（§8.3⑤——字节码侧写入仍 → 20；宿主侧直接改写属契约违反、自担）；需要"可变副本"时由宿主自行深拷贝，或改用空构造 + 填充模式（v0.18）。**闭包例外**：闭包值逃逸仍为编译错误（§8.6）——闭包字面值声明的变量不可返回。

**正则字面量（v0.6）**：形式 `/pattern/flags`——两个 `/` 之间为 pattern（UTF-8），结尾标志字符：`i` 忽略大小写、`m` 多行模式、`u` Unicode 模式，分别对应 `std.regex.RegexFlag` 的相应项（以 std 为准）。**flags 顺序无关（v0.18.18，冻结）**：三字符可任意排列、重复幂等——`/pat/im` ≡ `/pat/mi` ≡ `/pat/ii`；加载期归一为**位域**（bit0=i bit1=m bit2=u；§11.5 kind 10、§6 `ConstRegistry.addRegex`），顺序与重复**不进入任何可观察语义**（去重键、TO_STR 输出、匹配行为均以位域为准）；`i/m/u` 之外的字符仍属非法 flags（加载期 14）。示例：`/^[a-z]+$/im` 与 `/^[a-z]+$/mi` 等价。**一次性编译、跨调用复用**：加载器在装载 `.fbc` 时对每个 kind 10 常量构造一次 `Regex` 实例（ConstTable 持有，路径 A——跨调用同 ID，永不在执行期重编译）；同单元内**同 (pattern, flags) 去重为同一常量**（跨单元不共享，编译粒度决策 ③）；非法 pattern 或 flags 组合 → **加载期拒绝**（`JitException(14)`，site=-1），不进入执行期；**pattern 为空 → 加载期拒绝**（v0.11——非空 pattern 保证每次匹配至少 1 字节，替换扫描无零宽死循环，§11.9）。**Regex 可作参数与返回值（v0.17 开放）**：与其它句柄类型同路由——参数经 Marshal 表 `pin`（§8.1 路径 B）、返回经逃逸（路径 D）交由 `call<T>` 解包（§8.2）；LocalType 9 全位置合法、`retType=9` 合法（§11.7）。**字符串扩展构造（v0.17，`fountain::f_regex`）**：`regexStr.regex(): Regex`——运行期由字符串构造（恒无 flags；flags 需求用字面量形态）。降低：字符串句柄 + `STR_TO_REGEX`（0xBF，H69，分配型，§5/§6）。失败：**非法或空 pattern → 14**（空 pattern 与字面量同因——防零宽匹配死循环，§11.9）；结果为不可变新对象——每次求值新分配、**不去重**（去重是 kind 10 字面量常量的性质）；重放等值重建（I8）。

---

## §4 入口 ABI（桥 → 机器码）

```
rdi = ctx 指针（**桥分配、桥释放**——机器码仅调用期内经此指针**借用**：可按 ABI 约定读写指定字段，无分配/保存/释放权，§8.3 禁止保存复用。栈上或堆上均可，调用期间不得移动）
rsi = &args[0]（Int64 数组；nargs=0 时可为 null）
rdx = nargs（编译期已固定，运行时仅作断言）
ret: rax = cell（返回值或句柄）；errCode != 0 时 rax 未定义
```

**ctx 内存机制（"不得移动"的兑现）**：ctx 必须位于**非 GC 托管内存**——桥经 C 互操作 `malloc/free` 分配，或对宿主 `Array<UInt8>` 用 std.core `acquireArrayRawData`/`releaseArrayRawData` 配对钉住（钉住窗口内 GC 不搬移；未配对释放属运行时错误）。ctx 内只有整数标量（errCode/site/fnId/hwBase/hwTop/flags/nargs），无任何指针（决策 ④），GC 无需扫描。

**Prologue**（汇编器固定发射）：

```asm
    push  rbp
    mov   rbp, rsp
    mov   [rbp-8], r15               ; 保存调用方 r15（callee-saved）
    mov   r15, rdi                   ; ctx
    sub   rsp, frameSize
    mov   rax, [r15+16]
    mov   [rbp-16], rax              ; hwBase 镜像（x86 无 mem→mem，须经寄存器）
    mov   qword [r15+40], <fnId>     ; 错误归因（CALL_FUNC 链中最内层函数）
    ; nargs>0: for i in 0..nargs-1:  mov rax,[rsi+8i]; mov [rbp-32-8i],rax
    ; 编译期已知 nargs，直接按需发射，无循环
    ; 内存卫生填充：for i in nargs..nLocals-1:  mov qword [rbp-32-8i], 0
    ;   （不可观察：明确赋值分析保证先写后读，见 §7 校验 10 / §11.7）
.epilogue:
    mov   r15, [rbp-8]               ; 恢复调用方 r15
    mov   rsp, rbp
    pop   rbp
    ret
```

**Epilogue 是唯一返回路径**：所有 `RET/RET_VOID`、所有 `BAIL` 都以 `jmp .epilogue` 结束（`BAIL` 前置 `mov eax,0`）。

**桥的调用义务**：ctx 准备时写 `hwBase`（本次窗口起点 = 句柄表当次尾位）与 `hwCap`（有分配单元 = `HandleTable.initialCapacity`；无分配单元 = 0；§9.6）；入口前 `errCode=0; site=-1; hwTop=hwBase`；返回后**先读 errCode**，非 0 时不得使用 rax。

**内部调用 `CALL_FUNC`**：复用同一 ctx 与句柄窗口（不新开窗口），参数从操作数栈按顺序拷入新帧 locals，仍遵循本节帧约定，只是不经桥。汇编期校验 `fid` 存在且 `argc` 与被调函数一致（不符 → 编译错误 / 运行期 `ERR_ARG_MISMATCH`）。被调函数 prologue 把自己的 `fnId` 写入 ctx；**返回后调用方立即重写自身 `fnId`**（一条 mov），保证后续错误归因正确。**自递归**（源语言 `recursive(…)` 关键字，§8.0）就是 `fid = 自身 fnId` 的 CALL_FUNC——非尾位置递归深度受宿主线程栈限制；**尾位置自递归经 v0.17 自动尾递归优化**（帧复用回边，不增长栈，§8.0）。不插深度检查。

---

## §5 M1 ISA 指令表（opcode 编号）

编码：`[op:u8][operands...]`，小端；`rel` 为相对**下一条指令**的有符号 32 位偏移。栈作用列 `... a b → c` 表示先弹 b 再弹 a。

### 0x00–0x0F 控制 / 杂项

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 00 | `NOP` | — | 无操作 | — |
| 01 | `TRAP` | u8 | 调试陷阱 | — |
| 02 | `BREAKPOINT` | — | 保留，发布版空操作 | — |
| 03 | `SET_SITE` | i32 | 写 `ctx.site`；伪指令展开目标 | — |
| 04 | `CHECK_ERR` | rel32 | `errCode != 0` → 跳 bail | — |
| 05 | `BAIL` | i8 k | 写错误槽=k，`eax=0`，跳 epilogue | — |
| 06 | `CHECK_ERR_NC` | — | 仅断言（发布版空操作），调试期校验 | — |
| 07 | `STACK_GUARD` | u16 need | 剩余栈 < need → `BAIL -1`（DEOPT） | DEOPT |
| 08–0F | 保留 | | | |

### 0x10–0x1F 常量 / 栈

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 10 | `PUSH_I8` | i8 | `→ sext(v)` | — |
| 11 | `PUSH_I32` | i32 | `→ sext(v)` | — |
| 12 | `PUSH_I64` | i64 | `→ v` | — |
| 13 | `PUSH_F64` | i64(bits) | `→ v`（位模式原样） | — |
| 14 | `PUSH_BOOL` | u8 | `→ 0/1` | — |
| 15 | `PUSH_NULL` | — | `→ 0`（不得直存句柄型局部，§7 校验 10） | — |
| 16 | `PUSH_KH` | u16 idx | 压常量句柄 | — |
| 17 | `DUP` | — | `a → a a` | — |
| 18 | `DUP2` | — | `a b → a b a b` | — |
| 19 | `POP` | — | `a →` | — |
| 1A | `POP2` | — | `a b →` | — |
| 1B | `SWAP` | — | `a b → b a` | — |
| 1C | `PICK` | u8 n | `… v → … v v`（n=0 等价 DUP） | — |
| 1D–1F | 保留 | | | |

### 0x20–0x2F 局部变量

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 20 | `LOADL` | u16 i | `→ locals[i]` | 越界=编译错误 |
| 21 | `STOREL` | u16 i | `v → locals[i]=v` | 越界=编译错误 |
| 22 | `LOADL0` | — | `→ locals[0]`（压缩形式，可选） | — |
| 23 | `LOADL1` | — | `→ locals[1]` | — |
| 24 | `LOADL2` | — | `→ locals[2]` | — |
| 25 | `LOADL3` | — | `→ locals[3]` | — |
| 26 | `LOAD_CAP` | u16 idx | 闭包句柄（locals[0]）→ 捕获第 idx 个 cell（H56；仅闭包函数 prologue/体内使用，§8.6） | 6, 8 |
| 27–2F | 保留 | | | |

### 0x30–0x3F 整型算术（IADD–IMOD 检查溢出 / 除零；IADD_WRAP 显式无检查）

| Hex | 名称 | 语义（`a b → r`） | 失败码 |
|---|---|---|---|
| 30 | `IADD` | a+b | 3 |
| 31 | `ISUB` | a-b | 3 |
| 32 | `IMUL` | a*b | 3 |
| 33 | `IDIV` | a/b（向零截断） | 1, 3（INT_MIN/-1） |
| 34 | `IMOD` | a%b | 2, 3 |
| 35 | `INEG` | -a | 3 |
| 36 | `IABS` | \|a\| | 3 |
| 37 | `IMIN` | min(a,b) | — |
| 38 | `IMAX` | max(a,b) | — |
| 39 | `IADD_WRAP` | a+b 无检查（显式选择） | — |
| 3A | `ICLZ` | 前导零计数 | — |
| 3B | `IPOPCNT` | 位中 1 的个数 | — |
| 3C–3F | 保留 | | |

### 0x40–0x4F 浮点运算

| Hex | 名称 | 语义（`a b → r`） | 失败码 |
|---|---|---|---|
| 40 | `FADD` | a+b（IEEE） | — |
| 41 | `FSUB` | a-b | — |
| 42 | `FMUL` | a*b | — |
| 43 | `FDIV` | a/b，IEEE（得 ±Inf/NaN，**不报错**） | — |
| 44 | `FDIV_CHK` | a/b，÷0 报错（strictFp） | 1 |
| 45 | `FNEG` | -a | — |
| 46 | `FABS` | \|a\| | — |
| 47 | `FMIN` | min（任一操作数为 NaN → canonical NaN，§11.3） | — |
| 48 | `FMAX` | max（同上） | — |
| 49 | `FSQRT` | √a（负数 → NaN） | — |
| 4A | `FFLOOR` | 向下取整（保留 NaN/±Inf） | — |
| 4B | `FCEIL` | 向上取整 | — |
| 4C | `FTRUNC` | 向零取整 | — |
| 4D | `FROUND` | 四舍六入五成双 | — |
| 4E–4F | 保留 | | |

### 0x50–0x6F 比较 / 逻辑 / 位运算

| Hex | 名称 | 语义（`a b → r`） | 备注 |
|---|---|---|---|
| 50 | `CMP_I` | -1/0/1 | 整型三路比较 |
| 51 | `CMP_F` | -1/0/1 | **NaN → 结果未定义**，汇编器禁止对其发射 |
| 52 | `EQ_I` | 0/1 | |
| 53 | `NE_I` | 0/1 | |
| 54 | `LT_I` | 0/1 | |
| 55 | `LE_I` | 0/1 | |
| 56 | `GT_I` | 0/1 | |
| 57 | `GE_I` | 0/1 | |
| 58 | `EQ_F` | 0/1 | NaN 比较恒 false |
| 59 | `NE_F` | 0/1 | NaN ≠ 任意 → true |
| 5A | `LT_F` | 0/1 | |
| 5B | `LE_F` | 0/1 | |
| 5C | `GT_F` | 0/1 | |
| 5D | `GE_F` | 0/1 | |
| 5E | `NOT_B` | `a → !a` | |
| 5F | `AND_B` | a&&b（0/1） | 无短路；短路用跳转 |
| 60 | `OR_B` | a\|\|b | |
| 61 | `XOR_B` | a^b（bool） | |
| 62 | `BAND_I` | a&b | |
| 63 | `BOR_I` | a\|b | |
| 64 | `BXOR_I` | a^b | |
| 65 | `BNOT_I` | ~a | |
| 66 | `SHL_I` | a<<b（b 取低 6 位） | 与硬件一致 |
| 67 | `SHR_I` | a>>b 算术 | |
| 68 | `USHR_I` | a>>>b 逻辑 | |
| 69 | `EQ_H` | 句柄同一性（== null 亦用此） | 不解引用 |
| 6A | `NE_H` | 句柄不同一 | |
| 6B | `CMP_STR` | 字符串序（helper H09） | 6 |
| 6C | `CMP_DEC` | Decimal 序（helper H11） | 6, 8 |
| 6D | `CMP_DT` | DateTime 序（helper H13） | 6, 11 |
| 6E | `CMP_DUR` | Duration 序（helper H15） | 6, 12 |
| 6F | 保留 | | |

### 0x70–0x7F 控制流与调用

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 70 | `JMP` | rel32 | 无条件跳 | — |
| 71 | `JZ` | rel32 | `c==0` 跳（弹 c） | — |
| 72 | `JNZ` | rel32 | `c!=0` 跳 | — |
| 73 | 保留 | | | |
| 74 | `LOOP_BACK` | rel32 | 回边：`STACK_GUARD` + 安全点 → 跳 | DEOPT / -2 |
| 75 | `CALL_HELPER` | u16 hid, u8 argc | 调 helper，压结果；**汇编器自动尾随 CHECK_ERR**（hid：1–62、69 = 固定 helper §6；[0x0100,0xFFFF] = 单元私有预定义 helper §8.4，仅源入口产物） | helper 码 |
| 76 | `CALL_HELPER_NC` | u16 hid, u8 argc | 同上但不做错误检查（仅永不失败的纯函数允许） | — |
| 77 | `CALL_HELPER_V` | u16 hid, u8 argc | 返回 Unit，不压栈；**自动尾随 CHECK_ERR**（与 CALL_HELPER 同） | helper 码 |
| 78 | `CALL_FUNC` | u16 fid, u8 argc | 内部 JIT 函数调用（共窗口） | 传播 + 14 |
| 79 | `CALL_HOST` | u16 fid, u8 argc | 经薄 @C 包装调宿主回调（**M1 汇编期报 `ERR_NOT_IMPL`**，M2 启用；八项困难与三档演进路径见 §6 议题清单） | 传播 |
| 7A | `HW_OPEN` | u16 cap | 打开分配区块（M1 汇编期报 `ERR_NOT_IMPL`） | 16 |
| 7B | `HW_CLOSE` | — | 关闭区块 | — |
| 7C | `RET` | — | `t=[rsp]`；`rax=t`；跳 epilogue | — |
| 7D | `RET_VOID` | — | `rax=0`；跳 epilogue | — |
| 7E | `RET_NULL` | — | `rax=0`（引用返回位） | — |
| 7F | `CALL_CLOSURE` | u8 argc | 栈 [闭包句柄, a1…argc] → 间接调用闭包（§8.6；被调帧 locals[0]=句柄） | 传播 + 6, 8, 19 |

### 0x80–0x8F 类型 / 转换 / 显式错误

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 80 | `CAST` | u16 tok, u8 mode | 值/句柄转型；mode 0=报错 1=deopt | 7 / DEOPT |
| 81 | `TO_I64` | u8 mode | F64→I64（NaN/越界按 mode） | 13 / DEOPT |
| 82 | `TO_F64` | — | I64→F64（可能丢精度，不报错） | — |
| 83 | `IS_TYPE` | u16 tok | 句柄类型判定 `→ 0/1`（null→false） | — |
| 84 | `GUARD_TYPE` | u16 tok, u8 mode | 类型不符按 mode 处理 | 8 / DEOPT |
| 85 | `THROW` | u8 code | 写错误槽=17，site 附加表记源语言码 | — |
| 86 | `ASSERT` | u8 code | 弹 bool，false → BAIL(code) | code |
| 87 | `ABORT` | u8 code | 无条件 BAIL(code) | code |
| 88 | `GUARD_NNZ` | u8 mode | 栈顶句柄为 0 时按 mode 处理 | 6 / DEOPT |
| 89 | `TYPE_OF` | — | 句柄 → 类型 token（调试用） | 6 |
| 8A–8F | 保留 | | | |

### 0x90–0x9F 容器 / 值提取 / 数值转换（走 helper）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| 90 | `LEN` | — | 句柄 → 元素数（List/Map/String 通用） | 6, 8 |
| 91 | `GET_IDX` | — | `h i → 元素` | 4, 6 |
| 92 | `GET_KEY` | — | `h k → 值`（缺键报错） | 5, 6 |
| 93 | `GET_KEY_OR` | — | `h k d → 值`（缺键取 d） | 6 |
| 94 | `HAS_KEY` | — | `h k → 0/1` | 6 |
| 95 | `STR_AT` | — | `h i → Rune(Int64)` | 4, 6 |
| 96 | `DT_FIELD` | u8 f | `h → 字段值`（f 见 §6 H14） | 6, 11 |
| 97 | `DUR_TICKS` | — | `h → 纳秒 Int64` | 6, 12 |
| 98 | `DEC_IS_INT` | — | `h → 0/1` | 6, 8 |
| 99 | `HANDLE_TAG` | — | 调试：取 tag | 6 |
| 9A | `RANGE_NEW` | — | `start end step isClosed → h`（H41；isClosed 对应仓颉 `..` / `..=`；step=0 或 isClosed∉{0,1} → 14；空区间规则见 §11.9） | 14, 16 |
| 9B | `RANGE_CONTAINS` | — | `h v → 0/1`（H42；语义见 §11.9） | 6, 8 |
| 9C | `TO_DEC` | u8 src | src=0：Int64→Decimal（精确，scale 0，H28）；src=1：Float64→Decimal（最短往返，H29） | 13, 16 |
| 9D | `DEC_TO_I64` | u8 mode | mode=0：向零截断、越界 → 9（H30）；mode=1：越界 → DEOPT | 9 / DEOPT |
| 9E | `DEC_TO_F64` | — | IEEE 最近偶数，溢出 → ±Inf 不报错（H31） | 6, 8 |
| 9F | 保留 | | | |

### 0xA0–0xAF 分配/变更区（v0.5 起大部分启用；分配 = 登记新槽，变更 = 修改容器，§9.15）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| A0 | `MAKE_LIST` | — | `→ h` 新建空 List（H70，v0.18；分配型；对应源语言空字面值 `[]`，§3.3） | 16 |
| A1 | `LIST_APPEND` | — | `list cell → 0` 追加尾部（H43；ArrayList.add） | 6, 8, 20 |
| A2 | `MAKE_MAP` | — | `→ h` 新建空 Map（H71，v0.18；分配型；对应源语言空字面值 `{}`，§3.3） | 16 |
| A3 | `MAP_PUT` | — | `h k v → 0` 写键（H44；`map[k] = v` 语义） | 6, 8, 20 |
| A4 | `STR_CAT` | — | `h1 h2 → h` 字符串拼接（H32；插值串与混合 String 加法原语，不可变结果） | 6, 16 |
| A5 | `DEC_ADD` | — | `h1 h2 → h`（H24；decimal128 语义，§9.12/§11.9） | 9, 16 |
| A6 | `DEC_SUB` | — | `h1 h2 → h`（H25） | 9, 16 |
| A7 | `DEC_MUL` | — | `h1 h2 → h`（H26） | 9, 16 |
| A8 | `DEC_DIV` | — | `h1 h2 → h`（H27；÷0 → 10） | 9, 10, 16 |
| A9 | `DT_NEW` | — | 禁用（M2；M1 的 DateTime 来自常量/桥/DT±DUR） | — |
| AA | `DUR_NEW` | — | 禁用（M2） | — |
| AB | `LIST_INSERT` | — | `h i cell → 0` 定点插入（H45；add(T, at!)；i 越界 → 4） | 4, 6, 8, 20 |
| AC | `LIST_SET` | — | `h i cell → 0` 下标写（H46；`list[i] = v`；越界 → 4） | 4, 6, 8, 20 |
| AD | `LIST_REMOVE` | — | `h i → cell` 下标删除并返回被删元素（H47；remove(at!)；越界 → 4） | 4, 6, 8, 20 |
| AE | `MAP_REMOVE` | — | `h k → 0/1` 删键（H48；1=已删 0=本无此键，不报 5） | 6, 8, 20 |
| AF | `MAP_ITER_BEGIN` | — | `h → i64` 建立宿主侧 Map 迭代器并返回**游标**（H49，v0.16.1 重定义；**不登记窗口槽**——状态在宿主侧调用级迭代器表，随调用销毁；for-in 降级专用，§11.9） | 6, 8 |
| BE | `MAP_ITER_STEP` | u8 mode | `cur → cell` 迭代推进/取件/关闭（H62，v0.16.1 重定义；mode：**0=推进→0/1**、1=键、2=值、**3=close**（出口发射、幂等）；坏游标/未推进取件 → 99（防御）；**迭代中修改同一 map → 23**） | 23, 99 |

### 0xB0–0xBF 时间运算 / 文本化 / 字符串切片替换 / 正则 / 字符串建 Regex（v0.4–v0.17，走 helper）

| Hex | 名称 | 操作数 | 语义 | 失败码 |
|---|---|---|---|---|
| B0 | `DT_ADD` | — | `dt dur → dt`（H34） | 11, 16 |
| B1 | `DT_SUB` | — | `dt dur → dt`（H35） | 11, 16 |
| B2 | `DUR_ADD` | — | `d1 d2 → d`（H36） | 12, 16 |
| B3 | `DUR_SUB` | — | `d1 d2 → d`（H37） | 12, 16 |
| B4 | `DUR_MUL` | — | `d i64 → d`（H38；Int64×Duration 由前端换序） | 12, 16 |
| B5 | `DUR_DIV` | — | `d i64 → d`（H39；i64=0 → 1） | 1, 12, 16 |
| B6 | `DUR_NEG` | — | `d → d`（H40） | 12, 16 |
| B7 | `TO_STR` | u8 t | 值 → 字符串（H33；t=静态类型标签，格式冻结于 §11.9；插值/混合加法共用） | 6, 8, 16 |
| B8 | `STR_SUB` | — | `h a b → h` 子串（H50；**码点索引**半开区间 `[a, b)`，与 `STR_AT` 同一索引域（§11.4）；`a<0 / b>码点数 / a>b` → 4，`a==b` → 空串；源语言 `s[a..=b]` 由前端折算为半开形式） | 4, 6, 8, 16 |
| B9 | `STR_REPLACE` | — | `h old new → h` 全部子串替换（H51；old 为空串 → 14） | 6, 8, 14, 16 |
| BA | `REGEX_IS_MATCH` | — | `h_re h_s → 0/1`（H52；h_re 为任意 Regex 句柄——常量/局部/构造结果） | 6, 8 |
| BB | `REGEX_FIND` | — | `h_re h_s → h` 首个匹配子串（H53；返回整个匹配 group-0 的新 String，无匹配 → 0；捕获组提取属 M2） | 6, 8, 16 |
| BC | `STR_REPEAT` | — | `h i64 → h` 字符串重复（H60，v0.15；n ≤ 0 → 空串；`n × len_utf8` 溢出 → 3；见 §11.9） | 3, 6, 8, 16 |
| BD | `DT_DIFF` | — | `dt1 dt2 → h` 日期差 `dt1 − dt2 → Duration`（H61，v0.15；可为负；差分溢出 Duration 值域 → 12；见 §11.9） | 6, 8, 12, 16 |
| BF | `STR_TO_REGEX` | — | `h_s → h_re` 字符串构造 Regex（H69，v0.17；非法/空 pattern → 14；分配型；见 §3.3） | 6, 8, 14, 16 |

**0xC0–0xFF 预留 M2**，M1 发射即报错；预留给：`HW_OPEN` 区块内的批量分配、`CALL_HOST`。（非空/批量容器构造与时间构造属 M2 专项。）

### 前端控制流降低模式（if / while / for-in / break / continue）

M1 的控制原语（`JMP/JZ/JNZ/LOOP_BACK`）足以表达全部结构化控制流——`if`、`while` 在字节码层完全可表达。本节固化其规范降低模式，前端必须按此生成，以保证安全点与明确赋值分析（§7 校验 10）的兼容性：

**`if-else` 与 `if-else if-else`**：M1 支持这两种形式（无专用指令，经条件跳转降低）；**值用法靠栈顶留值汇合（语句用法经 `POP` 丢弃——形式判定见下）**。

`if-else`：

```
<cond 求值 → 0/1>
JZ   else                 ; 条件假 → 走 else
<then 分支>               ; 值用法：结果恰留 1 个 cell 在栈顶
JMP   end
else:
<else 分支>               ; 结果恰留 1 个 cell（值用法：类型与 then 逐位一致，前端保证）
end:                      ; 两分支栈深一致地汇合
```

`if-else if-else`：`else if` 就是 **else 分支内嵌套的 if**，逐级串联、每个分支各自 `JMP end` 汇合：

```
<c1>
JZ   elif1
<A 分支>
JMP  end
elif1:
<c2>
JZ   else2
<B 分支>
JMP  end
else2:
<C 分支>
end:
```

- **形式判定（冻结，v0.15.1；用户裁定）**：按**使用位置**判定——if 的值**被使用**（赋值/实参/运算数/尾返回等任何需要其值的上下文）→ **表达式形式**；值**被丢弃**（语句位置）→ **语句形式**。与分支形状无关；
- **语句形式**（无值）：各分支栈净深为 0——分支末值为表达式时经 `POP`（0x19）丢弃；**分支类型不受任何限制**（可互不相同、任意类型混用，值不参与任何类型约束）；**裸 `if`**（无 else-if/else 收尾）允许，等价于末尾为空分支；
- **表达式形式（值用法）**：**必须有最终 else**（仓颉语义：无 else 的 if 不产生值），且**每个分支**（then、每个 else-if、else）都恰留 1 个 cell、**类型逐位一致**（同一 LocalType；含容器的元素/键值类型等前端静态知识，§8.0 同口径）——**不做提升/统一**（如 I64/F64/DEC 混合即不一致）；不一致 → **编译错误**（前端保证，§7 校验 9 同口径）。**该约束仅随值用法生效——典型触发 = 用 if 表达式为变量赋值（`let x = if …` / `x = if …`）；语句用法不受此限制**；
- **明确赋值汇合规则**（§7 校验 10）：某局部必须在**全部分支**（then、每个 else-if、else）内都被赋值 → 出口视为已赋值；任一分支未赋值 → 出口未赋值，出口后读取 = 编译错误。

**`while (cond) { body }`**（条件在头部，每轮重算）：

```
header:
  <cond 求值 → 栈顶 0/1>
  JZ   end                 ; 假 → 退出循环
  <body>
  LOOP_BACK header         ; 回边 = STACK_GUARD + interrupt_poll(H22) + jmp header
end:
```

- **`for-in`**：经**隐藏计数局部**降低为上述 while 模式，不需要新指令、不需要迭代器协议。**源语言形式冻结为仓颉同形（v0.6）**：`for (i in iterable) { … }`——括号与花括号必带；`iterable ∈ {Range, List, Map, String}`（Map 的绑定形式为 `for ((k, v) in map)`——键值对双绑定，**无单变量形式**，迭代器仅服务于此）；可选 `where` 谓词（`for (i in iterable where cond)`）降低为循环体内首条"条件不满足 → 跳转至 continue 点"：
  - 区间：`for i in a..b(:s)` → 隐藏局部 `i` 初始化为 `a`（声明即首写，满足明确赋值），条件按 `s` 符号与 `b` 比较（`..=` 含端点，空区间规则见 §11.9），步进 `i = i + s`（`s<0` 用 `ISUB`）；空区间首轮条件即假，体不执行；
  - 容器：`for x in list` → `n = LEN(h)`（迭代开始快照长度）+ `j = 0; while j < n { x = GET_IDX(h, j); body; j = j + 1 }`；`for (k, v) in map`（**v0.16.1 惰性单遍迭代**）→ `cur = MAP_ITER_BEGIN(m)`（0xAF）→ 循环：`has = MAP_ITER_STEP(cur, 0)`（0xBE；0 → 跳出口）→ `k = MAP_ITER_STEP(cur, 1)`、`v = MAP_ITER_STEP(cur, 2)` → body → 回跳；**出口标签处发射一次 `MAP_ITER_STEP(cur, 3)`（close，幂等；覆盖条件出口与 break）**——**唯一一遍遍历（无快照、无预遍历）**；**不登记窗口槽**（迭代器状态在宿主侧调用级表，条目 ≤ 同时活跃迭代器数＝嵌套深度）；**迭代中修改同一 map → 23**（对齐 std `ConcurrentModificationException`）；
  - 隐藏计数局部计入 `nLocals` 与局部类型表（`Int64`），遵守明确赋值与空安全的全部规则。
- **`while (true)`**：可省略头部的 `JZ`，但**回边安全点必须保留**——`deadline` 到期经 `interrupt_poll` 置 -2，保证无限循环可中断（§12.6）。
- **`break` / `continue`**：无专用指令。`break` = `JMP end`；`continue` = `JMP` 至回边指令（`LOOP_BACK`）之前，保证每一轮回边都经过安全点。
- **多重赋值与变量交换（v0.6）**：`(a, b) = (b, a)` 是前端糖，语义冻结为**同时赋值**——全部 RHS 先求值、后统一写回（先读后写 ⇒ 交换天然正确，`a` 的写入不影响 `b` 的读取）。降低：为每个 RHS 结果引入**隐藏局部**（类型 = 各 RHS 静态类型，声明即首写，计入 `nLocals` 与局部类型表），再依序 `STOREL` 至 LHS。约束：LHS 只能是局部变量（M1 无属性赋值——`list[i] = v` 是指令不是赋值语句）；RHS 仅支持**一维元组字面量**（M1 函数单返回值，无元组类型，元组不可作为值传递）；LHS 槽可用 `_` 忽略——对应 RHS **仍求值**（副作用与错误不能省），结果经 `POP`（0x19）丢弃；RHS **从左到右求值**；含变更型调用的 RHS 照常受 §9.15 约束。明确赋值交互：LHS 全部视为出口已赋值（各 `STOREL` 均执行）；RHS 所读变量须此前已赋值（§7 校验 10 自然满足）。
- **`recursive(args)` 自递归（v0.7，§8.0）**：顶层 lambda 内 = `CALL_FUNC <entryFn>`（`fid` = 自身，目录必含）；实参表达式从左到右求值入栈，argc 与自身 `nargs` 一致由前端静态校验 + §7 校验 7 把关；**v0.17 自动尾递归优化**：**尾位置**的 `recursive(...)` 降为「实参逆序 `STOREL`（闭包槽基址 1）→ `LOOP_BACK <函数入口>`」帧复用回边（不重入帧、不增长栈；不发射 `RET`——该路径以回边终结）；非尾位置深度受宿主线程栈限制。**v0.9/v0.10**：`recursive` 绑定**最近一层词法闭包**（嵌套闭包内 = `LOADL 0` + `CALL_CLOSURE`，捕获快照经闭包对象携带；顶层 = `CALL_FUNC`，§8.5/§8.6）。**v0.12 值位**：`recursive` 可作右值——求值结果 = 当前层的**自引用闭包值**（LocalType 12，类型 = 当前层签名 `(T1..Tn) -> R`）：闭包层 = `LOADL 0`（零成本）；顶层 = `closure_new <adapterFn>`（0 捕获；adapterFn 为前端按需生成的隐藏适配器 FuncEntry，闭包帧格式，体 = 转发 `CALL_FUNC <entryFn>`，§8.0/§8.6）——经变量赋值与嵌套捕获，内层闭包可递归调用任意外层（§8.5）。
- **嵌套闭包与立即调用（v0.9，§8.5；v0.10 闭包值模型）**：闭包声明 → 独立 FuncEntry + `closure_new`（捕获快照打包）；`name(args)` / `{...}(args)` → `CALL_CLOSURE`（被调帧 locals[0]=句柄，捕获经 LOAD_CAP）；first-class 局部闭包值支持（§8.6），逃逸 → 编译错误。
- **正则操作符（v0.11，§11.9）**：`re ~ s` / `re !~ s` → `REGEX_IS_MATCH`（`!~` 加 `NOT_B` 取反）；`re/s/r/g` → `REGEX_REPLACE_ALL`；`re/s/r/n` → `REGEX_REPLACE_NTH`（示意中 `re` 为 Regex 表达式**占位符**——变量/字面量皆可；分隔符恒为单 `/`：无 flags 字面量代入后其闭合 `/` 与分隔 `/` 相邻呈 `//`，带 flags 字面量与变量均为单 `/`）；优先级高于加减、低于乘除，左结合；字面量后的紧贴 `/` 优先于注释识别。
- **短路 `&&` / `||`**：前端用 `JZ/JNZ` 短路链降低；`AND_B/OR_B`（0x5F/0x60）仅用于两侧均已求值的场景。

**明确赋值分析与回边（§7 校验 10 的循环规则）**：数据流按**不动点迭代**求解。M1 的循环（`while` 与经降低的 `for-in`）都**不保证至少执行一轮**，因此**仅**在循环体内 `STOREL` 的局部，在循环出口之后一律**不视为已赋值**——出口后读取 = 编译错误，前端必须在循环入口之前完成赋值：

```cangjie
var x: Int64            // 声明（无默认值，§11.7）
while (c) { x = f() }   // 仅循环内赋值
return x                // 编译错误：出口路径 x 未必已赋值
```

---

## §6 M1 @C helper 清单

**helper ABI**：`rdi=ctx`，`rsi=&args[0]`，`rdx=nargs`，`ret rax=cell`。args 从**操作数栈顶向下**排列（`args[0]` 是最深的那个）；nargs 由指令 `argc` 决定。**helper 内部必须把所有异常转成错误码，绝不抛出**。

**封闭白名单**：本表 + §5 指令面 = JIT 产物对仓颉类型的**全部**可见能力。机器码没有任何直接调用仓颉 API 的通道（只见 Int64 ID 与固定 ABI）；不存在"调用任意 ArrayList/HashMap/String/… API"的路径。新增 helper 的准入准则（必须**全部**满足）：① 确定性——同输入同输出，禁止 now/随机/读全局态（**唯一例外：`TO_STR` 的 DateTime 时区呈现**——读宿主系统时区，§11.9；语义显式定义、非未定义行为）；② 无副作用——除登记不可变值与**变更型 helper 的容器修改**（H43–H48，§9.15）外；③ 结果不可变；④ 异常面可枚举并映射到 §2 错误码；⑤ 三引擎逐位一致（I7；涉及格式时按 §11.9 冻结）。扩展能力 = 新增指令 + helper + verMinor 升版（§13.3）+ 差分测试；"调用任意仓颉函数"的通用出口是 M2 `CALL_HOST`（用户经 Compiler 注册的预定义函数走 user helper 通道，§8.4，准入责任由注册者自担）。

**M2 CALL_HOST 议题清单（v0.12.1 备案——不改变任何 M1 语义；M1 内 CALL_HOST 汇编期报 `ERR_NOT_IMPL`）**：以"运行期接收宿主仓颉闭包做实参"为标本，八项困难均**非理论障碍**、均有解法（括注），性质为工程代价与可证明正确性面的取舍：

1. **调用通道缺位**——机器码只见固定 helper ABI（`rdi=ctx, rsi=&args, rdx=n, ret rax=cell`），无法调用仓颉 ABI（含隐藏捕获环境参数）（解法：`CALL_HOST` 薄 @C 转发器 = helper ABI 反向版，0x79 已预留）；
2. **静态性丧失**——调用点目标运行期才知，§8.4 的"静态 hid 烘焙 + trampoline 编译期布局"不可复用（解法：运行期回调表——闭包 ID 入句柄表、条目持 `CFunc`，同步保护复用 §9.7）；
3. **签名运行期校验 + 禁高阶失效**——§8.6 的"签名是前端/桥静态知识"前提崩塌，宿主闭包返回值可为闭包形成高阶链（解法：Marshal 时对仓颉函数类型验签；一/二档**保留禁高阶**，排除高阶链）；
4. **输入等价性不可建立**——宿主闭包捕获状态跨调用可变，"同输入同输出"无法定义，差分测试与可重复调用（§8.3）失去黄金基准（解法：三引擎共用同一宿主闭包 ⇒ 行为天然一致，差分退化为"转发语义逐位一致"；含 CALL_HOST 的函数按 §9.15 既有模式保守按变更型处理）；
5. **异常语义错位**——用户闭包的业务异常是正常程序流，映射为 99（实现缺陷信号）不合理（解法：新错误码 `21 ERR_HOST_CALLBACK` + 复用 cause 通道；异常对象回译属第三档）；
6. **重入**——宿主闭包体内再调 JIT 产物（解法：ctx 每调用独立分配已是 §9.7 现状，重入 = 转发器内走正常 call 开新 ctx；需专项审计 fail-fast/三态收尾的嵌套组合语义）；
7. **GC 栈扫描边界放大**——回调链穿过 JIT 帧更深（解法：先例已存在——helper 内分配即触发 GC 穿过 JIT 帧；需验证并文档化保守扫描假设）；
8. **序列化封闭**——闭包不可序列化（§8.4），`.fbc` 分发世界无供给通道（解法：分发世界继续禁止，零成本）。

**三档演进路径**（每档独立交付、独立测试）：

- **第一档（最小可行）**：`CALL_HOST` 仅调**编译期注册**的回调——静态性保留，仅补运行期绑定；
- **第二档**：宿主闭包做实参——运行期回调表 + 运行期验签 + 错误码 21，禁高阶保留（**技术方案已立专项规格：`jit-bytecode-m2.md`**）；
- **第三档**：高阶（闭包返回闭包——指**回调链内**函数类型签名传递，与 §14「逃逸闭包回桥」（字节码闭包 → 宿主）为**独立两轴**）+ 异常对象回译——完整双向互操作。

判定：M1 的形态上限是 §8.4（编译期注册、运行期只传数据）；运行期闭包实参 = M2 CALL_HOST 的核心议题，按档渐进开放。

| hid | 名称 | 输入 | 输出 | 失败码 |
|---|---|---|---|---|
| H01 | `hl_len` | h | i64 | 6 |
| H02 | `hl_get` | h, i | cell | 4, 6 |
| H03 | `hm_len` | h | i64 | 6 |
| H04 | `hm_get` | h, kh | cell | 5, 6 |
| H05 | `hm_get_or` | h, kh, d | cell | 6 |
| H06 | `hm_has` | h, kh | 0/1 | 6 |
| H07 | `hs_len` | h | i64 | 6 |
| H08 | `hs_at` | h, i | Rune | 4, 6 |
| H09 | `hs_cmp` | h1, h2 | -1/0/1 | 6 |
| H10 | `h_ref_eq` | h1, h2 | 0/1 | — |
| H11 | `hd_cmp` | h1, h2 | -1/0/1 | 6, 8 |
| H12 | `hd_is_int` | h | 0/1 | 6, 8 |
| H13 | `ht_cmp` | h1, h2 | -1/0/1 | 6, 11 |
| H14 | `ht_field` | h, f | i64 | 6, 11 |
| H15 | `hdur_cmp` | h1, h2 | -1/0/1 | 6, 12 |
| H16 | `hdur_ticks` | h | i64 | 6, 12 |
| H17 | `h_is_type` | h, tok | 0/1 | —（null → false） |
| H18 | `h_tag_of` | h | tok | 6 |
| H19 | `h_guard` | h, tok | h | 6, 8 |
| H20 | `h_nonnull` | h | h | 6 |
| H21 | `err_raise` | code | 0 | —（写槽 + site 后返回） |
| H22 | `interrupt_poll` | — | 0 | -2 |
| H23 | `hw_check` | cap | 0 | 16 |
| H24 | `dec_add` | h, h | h | 9, 16 |
| H25 | `dec_sub` | h, h | h | 9, 16 |
| H26 | `dec_mul` | h, h | h | 9, 16 |
| H27 | `dec_div` | h, h | h | 9, 10, 16 |
| H28 | `dec_from_i64` | i64 | h | 16 |
| H29 | `dec_from_f64` | f64 | h | 13, 16 |
| H30 | `dec_to_i64` | h | i64 | 9 |
| H31 | `dec_to_f64` | h | f64 | — |
| H32 | `str_cat` | h, h | h | 6, 16 |
| H33 | `to_str` | v（带标签 t） | h | 6, 8, 16 |
| H34 | `dt_add` | h, h | h | 11, 16 |
| H35 | `dt_sub` | h, h | h | 11, 16 |
| H36 | `dur_add` | h, h | h | 12, 16 |
| H37 | `dur_sub` | h, h | h | 12, 16 |
| H38 | `dur_mul` | h, i64 | h | 12, 16 |
| H39 | `dur_div` | h, i64 | h | 1, 12, 16 |
| H40 | `dur_neg` | h | h | 12, 16 |
| H41 | `range_new` | i64, i64, i64, u8(0/1) | h | 14, 16 |
| H42 | `range_contains` | h, i64 | 0/1 | — |
| H43 | `list_add` | h, cell | 0 | 6, 8, 20 |
| H44 | `map_put` | h, cell, cell | 0 | 6, 8, 20 |
| H45 | `list_insert` | h, i64, cell | 0 | 4, 6, 8, 20 |
| H46 | `list_set` | h, i64, cell | 0 | 4, 6, 8, 20 |
| H47 | `list_remove` | h, i64 | cell | 4, 6, 8, 20 |
| H48 | `map_remove` | h, cell | 0/1 | 6, 8, 20 |
| H49 | `map_iter_begin`（v0.16.1 重定义） | h | i64 | 6, 8 |
| H50 | `str_sub` | h, i64, i64 | h | 4, 6, 8, 16 |
| H51 | `str_replace` | h, h, h | h | 6, 8, 14, 16 |
| H52 | `regex_is_match` | h, h | 0/1 | 6, 8 |
| H53 | `regex_find` | h, h | h | 6, 8, 16 |
| H54 | `closure_new` | i64(fnId), cell…捕获 | h | 14, 16 |
| H55 | `closure_fnid` | h | i64 | 6, 8 |
| H56 | `closure_cap` | h, i64 | cell | 6, 8 |
| H57 | `fn_table` | — | i64(基址) | — |
| H58 | `regex_replace_all` | h, h, h | h | 6, 8, 16 |
| H59 | `regex_replace_nth` | h, h, h, i64 | h | 6, 8, 14, 16 |
| H60 | `str_repeat`（v0.15） | h, i64 | h | 3, 6, 8, 16 |
| H61 | `dt_diff`（v0.15） | h, h | h | 6, 8, 12, 16 |
| H62 | `map_iter_step`（v0.16.1 重定义） | i64, mode | cell | 23, 99 |
| H69 | `str_to_regex`（v0.17；编号接 m2/m3 占用的 H63–H68 之后） | h | h | 6, 8, 14, 16 |
| H70 | `list_new`（v0.18） | — | h | 16 |
| H71 | `map_new`（v0.18） | — | h | 16 |

**分配型 helper（H24–H29、H32–H41、H50–H51、H53–H54、H58–H61、H69、H70–H71）**：每次调用在窗口登记**恰好 1 个新槽**（其结果：不可变值 / H54 的闭包对象——新对象，M1 内只读使用 / H70–H71 新建空容器——可经变更型 helper 修改），窗口满则宿主扩容（§9.6）；句柄表全局上限触顶 → 16。**H30/H31 返回原始值、H42/H48/H52 返回 0/1，均不登记新槽**；H01–H23 与**变更型 helper（H43–H48）**同样不登记。`to_str` 的标签 `t`：`0=I64 1=F64 2=Bool 3=String 4=Decimal 5=DateTime 6=Duration 7=Range 8=Regex`。

**变更型 helper（H43–H48，v0.5）**：修改**已存在**的 List/Map（目标槽经 fetch 取得，tag=1/2），是 M1 **唯一许可的容器副作用**。三条硬规则（§9.15）：① 目标槽属路径 A（常量）→ `ERR_READONLY(20)`；② 含其调用的函数**禁止 deopt 源**（汇编期校验，§7 校验 11）；③ 元素/键值 cell 按 §3.2 表示（Int64/Float64/Bool 原值，句柄型传 ID）。语义对应 std API（签名以 std 为准）：`ArrayList.add(element)` / `add(element, at!)` / `remove(at!)`（返回被删元素）/ 下标写（`operator [](index, value!)`）；`HashMap.add(key, value): Option<V>`（写键——std 无 `put` 方法；覆盖并返回旧值，键此前不存在 → None；M1 `map[k] = v` 忽略该返回值）/ `HashMap.remove(key): Option<V>`（删键——返回被删值，不存在 → None；H48 规范化为 1/0）。

`ht_field` 的 f：`1=year 2=month 3=day 4=hour 5=minute 6=second 7=nanosecond 8=dayOfWeek 9=epochSec 10=epochMilli`

**类型 token（u16，M1 封闭集；加载器遇未知值拒绝）**：`0 保留，1=List 2=Map 3=String 4=Decimal 5=DateTime 6=Duration 7=Range 8=Regex 9=Closure`。`IS_TYPE/GUARD_TYPE/CAST/H17–H19` 与句柄槽 `tag` 均使用该编码。

**fetch 类失败码约定**：凡经 `HandleTable.fetch` 的 helper，句柄为 null → 6、类型不符 → 8；上表失败码列略写了这类公共项（`ERR_BAD_CAST`(7) 仅由 `CAST` 指令产生）。

**std 类型实现（不自定义类型）**：全部句柄类型映射到标准库（§3.2 映射表），运算/构造/比较/文本化直接调用 std API，不自实现——H01–H08（List/Map/String 的 `LEN/GET_IDX/GET_KEY` 等）、H24–H27 与 H28–H31（`std.math.numeric.Decimal`，§9.12）、H32/H33（String 拼接与文本化）、H34–H40（`std.time.DateTime`/`std.core.Duration` 运算）、H41/H42（`std.core.Range`）、H43–H48（`std.collection` 容器变更）、H49/H62（v0.16.1：`HashMap.iterator()` 惰性游标封装——单遍无快照）、H50/H51（String 切片/替换）、H52/H53（`std.regex.Regex` 匹配/查找）、H58/H59（`std.regex` 全局/第 n 替换，§11.9）、H69（v0.17：`std.regex` 运行期构造——String 扩展，§3.3）、H70/H71（v0.18：`std.collection` 空容器构造——对应空字面值 `[]`/`{}`）、H60/H61（v0.15：String 重复 / DateTime − DateTime 差；详见 §11.9）。helper 捕获 std 异常并按 §2 转码（除 0 → 10/1、越界 → 4/9、其余未知 → 99）。语义确定性由 std 的跨平台一致实现保证（T1/T11）。

**单元私有预定义 helper（user helpers，v0.8，§8.4）**：Compiler 实例注册的宿主函数（`PredefinedFunction`），编译期名字解析后以 hid [0x0100,0xFFFF] 进入 CALL_HELPER 通道；trampoline ABI 与本表一致（§6 ABI），实参/返回值按注册签名 marshal（§8.4），异常转码按 §9.5；一律按变更型处理（§9.15），返回句柄型时同时为分配型（登记 1 槽）。封闭白名单的责任模型：固定 helper 由本规范背书；user helper 的准入责任由**注册者**自担（运行期安全由 §9.15 保守规则兜底，不依赖注册者自觉）。

**helper 实现模板（必须遵守）**：

```cangjie
@C
func hl_get(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    try {
        let h = args[0]; let i = args[1]
        let list = HandleTable.fetch<ArrayList<Int64>>(h)   // null/类型不符 → 抛
        if (i < 0 || i >= list.size) { ErrIdxOob.throw() }
        return list[i]
    } catch (e: Exception) {
        ctxWriteCode(ctx, codeOf(e))     // 映射到 §2 错误码；未知 → 99
        return 0
    }
}
```

**拼装期 API（非 JIT 调用路径）**：

| 名称 | 签名 | 用途 |
|---|---|---|
| `ConstRegistry.addList` | `(ArrayList<T>) -> hid` | 注册列表字面量常量 |
| `ConstRegistry.addMap` | `(HashMap<K,V>) -> hid` | 注册映射字面量常量 |
| `ConstRegistry.addStr` | `(String) -> hid` | 注册字符串常量 |
| `ConstRegistry.addValue` | `(Decimal/DateTime/Duration) -> hid` | 注册值常量 |
| `ConstRegistry.addRange` | `(start: Int64, end: Int64, step: Int64, isClosed: Bool) -> hid` | 注册区间常量（§11.5 kind 9；对应字面量 `s..e:step` / `s..=e:step`） |
| `ConstRegistry.addRegex` | `(pattern: String, flags: UInt8) -> hid` | 注册正则常量（§11.5 kind 10；flags bit0=i bit1=m bit2=u；对应字面量 `/pattern/flags`；同 (pattern, flags) 去重同 hid） |
| `ConstRegistry.freeze` | `() -> Unit` | 冻结常量表（之后只读） |

---

## §7 伪指令表（汇编器展开，不出现在最终码流）

| 伪指令 | 操作数 | 展开为 | 约束 |
|---|---|---|---|
| `SET_SITE` | i32 | `mov qword [r15+8], imm32` | 仅在可能失败指令前发射 |
| `CHECK_ERR` | — | `cmp qword [r15+0],0; jne <最近 bail>` | 由 `CALL_HELPER` 自动尾随 |
| `GUARD_HANDLE` | n | `call H20; CHECK_ERR` | 合成形式 |
| `LOOP_BACK` | rel | `STACK_GUARD` + `call H22` + `jmp` | 热循环回边 |
| `BAIL` | k | 独立基本块 `写槽; eax=0; jmp .epilogue` | 每函数至少一个 |
| `PUSH_KH_HINT` | idx | 仅编码期提示，无机器码 | 供调试器映射 |
| `CHECK_ERR_OFF` | — | 取消随后一条自动 CHECK_ERR | 仅 `CALL_HELPER_NC` 语义等价的场景 |
| `BAIL_SITE` | k, i32 | `SET_SITE i32` + `BAIL k` | 便于阅读的组合 |

**与 §5 真实 opcode 的关系**：`SET_SITE/CHECK_ERR/BAIL/LOOP_BACK` 在 `.fbc` 中是 §5 的真实 opcode（03/04/05/74，解释器同样执行它们）；本表的"展开"指机器码 lowering 阶段把这些 opcode 变为实际指令序列，其本身不占机器码字节。`GUARD_HANDLE/PUSH_KH_HINT/CHECK_ERR_OFF/BAIL_SITE` 则是汇编器源层语法糖，不进 `.fbc`。

**汇编期硬校验（报错即拒绝生成）**：

1. 每条 `CALL_HELPER` 后必存在可达 `CHECK_ERR`（除显式 `_NC`）。
2. `0xA9–AA` 与 `0xC0–0xFF` 出现即 `ERR_NOT_IMPL`（v0.5 起 A1/A3/AB–AF、v0.6 起 0xB8–BB、v0.15 起 0xBC–BD、v0.16.1 起 0xBE、v0.17 起 0xBF、v0.18 起 A0/A2 已启用）。
3. 每个 sink（`RET/RET_VOID/BAIL`）前 `rsp` 深度必须回到帧基线（栈平衡校验）。
4. `PUSH_KH idx` 的 idx 必须 < 常量表长度且已 `freeze`。
5. `LOADL/STOREL i`：`i < nLocals`。
6. 存在 `LOOP_BACK` 的函数必须在所有 `CALL_HELPER` 之后保留错误检查（不允许把检查优化掉跨越回边）。
7. `CALL_FUNC` 的 `fid` 必须存在于同一 `.fbc` 函数目录（§11.7）且 `argc` 与被调函数 `nargs` 一致（不符 → 编译错误 / 运行期 `ERR_ARG_MISMATCH`）；`closure_new` 的 fnId 立即数同规则校验（< 目录数，§8.6）。
8. M2 专属指令（`CALL_HOST`、`HW_OPEN`、`HW_CLOSE`）在 M1 一律 `ERR_NOT_IMPL`；`HW_CLOSE` 必须与已打开的 `HW_OPEN` 区块配对（配对校验 M2 启用）。
9. 每个函数必须携带局部类型表（§11.7）：长度恰为 `nLocals`、每槽类型值合法；`STOREL` 的栈顶类型与目标槽声明类型一致由**前端保证**（M1 无字节码校验器，不做栈类型跟踪）。
10. **明确赋值与空安全**：非参数局部在被读取的所有可达路径上必须已被 `STOREL` 显式写入（汇编期数据流分析，违规 = 编译错误）；`PUSH_NULL` 不得作为句柄型局部（LocalType 4–12）的赋值源直存。零值填充不可观察（§3.1）。
11. **变更型函数的 deopt 禁令（v0.5，§9.15②；v0.8 纳入预定义 helper；v0.10 纳入 CALL_CLOSURE）**：函数内出现任一变更型 helper 调用（H43–H48、预定义 helper/user helper（§8.4）或 `CALL_CLOSURE`（§8.6，被调闭包体静态不可知）；经 CALL_FUNC 传递亦然——整函数保守判定）时，`DEC_TO_I64` mode=1 与 `TO_I64` 的 deopt 模式**禁止发射**（前端必须改用报错模式，语义等价——deopt 收敛后同样以错误码落地）；违规 → `ERR_NOT_IMPL`。这保证变更不会被 deopt 重放重复执行。

---

## §8 桥入口与 JitFunction 成员（Cangjie）

### §8.0 被编译代码格式（源入口声明，v0.7，冻结）

`compile(source)` 的输入**必须且只能是一个仓颉 lambda 字面量**：

```cj
{ <arg_list> =>
    <body>   // 局部变量声明、if、while、for-in、各类型访问与运算等
}
```

- **`arg_list`（形参列表）**：严格按仓颉函数参数定义——`name: Type` 逗号分隔；**不支持具名参数与参数默认值**；可以为空（`{ => … }`）。`=>` **不可省略**。参数类型 ∈ §11.7 LocalType（0–11；**9=Regex 自 v0.17 可作参数/返回**，Marshal 表含 token 8（§8.2.1）；**12=Closure 仅限非入口函数**——源入口（顶层 lambda）参数不得为 Closure：Marshal 表无此行（§8.2.1），经 `call<T>` 恒不可供给，前端拒绝（v0.12.1 收紧；CALL_FUNC 链内传闭包不受影响，§8.6）），容器参数记 `List<元素类型>` / `Map<K, V>`（元素类型为前端/桥的静态知识，类型表只记大类）。这些形参就是字节码/JIT 产物接收的参数（`locals[0..nargs-1]`，§3.1）。
- **返回值 = 闭包体执行的最后一个表达式的值**（隐式返回，仓颉 lambda 语义），不限制返回类型（§11.7 类型集内即可；Unit 体最后为语句）。**任意字面值声明的变量均可返回（v0.18.1）**——含非空容器字面值常量（交付共享只读对象，§3.3）；闭包值除外（§8.6）。返回类型由前端对尾表达式做**静态推导**，写入 `FuncEntry.retType`（§11.7）——这就是 `JitFunction.call<T>` 识别结果具体类型的依据：`retUnboxer` 按 retType 解包（§8.2.2），`T` 与 retType 不符 → 19（§8.2 第 5 步）。实参按**顺序**转换成 arg_list 的参数类型（§8.2.1 Marshal 表）。
- **body 能力面**（全部为白名单内能力）：类型化局部变量声明（§11.7 类型集——v0.18 起含 List/Map 局部）、`if` / `while` / `for-in`（§5 规范降低）、`recursive` 自递归（见下）、**嵌套闭包定义与立即调用（§8.5，v0.9）**、全部 §5 指令面/§6 helper 可达操作（数值与 Decimal 算术、混合提升、字符串切片/替换/插值/重复（v0.15）、多行/原始字符串字面量（§8.8，v0.14）、正则匹配/操作符（§11.9，v0.11）与 `s.regex()` 字符串构造（§3.3，v0.17）、容器构造（空字面值 `[]`/`{}`，v0.18）与遍历/变更/返回（任意来源容器——参数/常量/构造；非空字面值常量可返回，v0.18.1）、区间、Duration/DateTime 运算（含日期差 `dt1 − dt2`，v0.15）等）。
- **body 禁用面**：宏（M1 总则）；try-catch（§0 错误通道）；**闭包逃逸**（闭包值不可跨桥/存容器——first-class 局部闭包值自 v0.10 支持，见 §8.6；词法绑定不可重赋值为异签名闭包）；具名/默认参数。
- **`recursive` 自递归调用（关键字）**：`recursive(<arg_list>)` 调用**当前最近一层词法闭包**自身（v0.9 细化：顶层 lambda 内 = 调用顶层；嵌套闭包内 = 调用该嵌套闭包，§8.5）——参数表须与所在闭包签名逐位一致（个数/类型，前端静态校验）。降低：**顶层 lambda 内** = `CALL_FUNC <entryFn>`；**嵌套闭包内** = `LOADL 0`（自身闭包句柄，§8.6 帧约定）+ `CALL_CLOSURE`（v0.10；argc 与签名一致由 §7 校验 7 把关）。**自动尾递归优化（v0.17，冻结；无需关键字）**：处于**尾位置**的 `recursive(...)` 自动降低为**帧复用回边**——实参求值入栈 → 按**逆序** `STOREL` 写入本次参数槽（顶层 `locals[0..n-1]`；闭包 `locals[1..n]`，不重写 `locals[0]` 自身句柄）→ `LOOP_BACK <函数入口>`：**不增长调用栈**、操作数栈回基线后回跳；`STACK_GUARD`/安全点照常（深尾递归可被 `-2` 取消）。**尾位置定义（冻结）**：函数体末表达式；`if`/`else` 各分支（当该 `if` 位于尾位置）；块的最后表达式（当该块位于尾位置）。非尾位置的 `recursive(...)` 维持普通调用（`CALL_FUNC`/`CALL_CLOSURE`），深度受宿主线程栈限制——**尾递归路径不再增长栈（不溢出）**，非尾路径与仓颉原生递归表现一致；M1 不插深度检查。实参求值顺序、静态 argc/签名校验与错误路径全部不变（求值失败即 fail-fast 退出，不回跳）；含变更型调用的尾递归函数照常受 §9.15 全部规则约束（尾优化与 deopt 禁令正交）。含变更型调用的递归函数同样受 §9.15 全部规则约束。**值位（v0.12）**：`recursive` 亦可作右值——求值结果 = 当前层的**自引用闭包值**（LocalType 12，类型 = 当前层签名）：闭包层 = `LOADL 0`；顶层 = `closure_new <adapterFn>`（0 捕获）。**adapterFn** 为前端按需生成的隐藏 FuncEntry（不计入源函数数；闭包帧格式：`locals[0]`=句柄、`locals[1..n]`=实参；体 = 依次推入 `locals[1..n]` + `CALL_FUNC <entryFn>` + 尾直返；适配器内 `recursive` 绑定适配器自身，前端不生成对它的使用）。约束：**顶层签名含 Closure 参数（LocalType 12）→ 值化编译错误**（规避禁高阶边界，改用命名变量模式）；值化每次求值 = 新分配（分配型，重放等值，§8.6）；调用经值化引用的 argc/类型不符 → 运行期 14（§2）。
- **单元形态**：源入口 = 单个 lambda ⇒ 前端为其与**每个嵌套闭包**各生成一个 FuncEntry（目录 ≥ 1 项，`entryFn` = 顶层 lambda；v0.9，§8.5）；**v0.12**：源码出现**顶层 `recursive` 值位**时另按需生成 1 个隐藏适配器 FuncEntry（见上文值位）——目录 = 顶层 + 嵌套闭包 + 适配器（按需）；多函数目录（含互递归）由**分发入口** `compile(unit)` 的 `.fbc` 提供的场景同样成立，`CALL_FUNC` 能力对两者一致可用。

示例：

```cj
// 阶乘：recursive 自递归；返回 Int64（尾表达式推导）
{ n: Int64 =>
    if (n <= 1) { 1 } else { n * recursive(n - 1) }
}

// 无参数；返回 String（最后表达式）
{ =>
    let s = "a" + "b"          // STR_CAT
    s + "${1 + 2}"             // 插值 → 返回 String
}

// 容器参数 + for-in + 容器变更；返回 Map（逃逸，retType=11）
{ list: List<Int64>, m: Map<String, Int64> =>
    for (x in list) { m["${x}"] = x }   // GET_IDX 遍历 + MAP_PUT（键经插值文本化）
    m
}

// v0.18：空字面值构造 + 局部持有 + 变更 + 返回（自建 Map；宿主无需传入）
{ list: List<Int64> =>
    let m: Map<String, Int64> = {}       // 每次求值 = 新建可变空 Map（MAKE_MAP/H71）
    for (x in list) { m["${x}"] = x }    // GET_IDX 遍历 + MAP_PUT
    m                                    // 逃逸返回（retType=11）
}
```



```cangjie
// ① 主入口：源码字符串 → 字节码 →（Linux 上）立即 JIT，一站式完成。
//    v0.8 起为主入口为 Compiler 实例方法（§8.4）：配置（CompileOptions）与预定义函数
//    注册表在构造/注册阶段绑定实例，compile(source) 使用实例上下文。
//    管线四步（并发安全，去重协议见 §12.6）：
//    1. 源码 → 字节码：源码必须是单个 lambda 字面量（§8.0），前端为其与每个嵌套闭包
//       各生成 FuncEntry（§8.5），并生成 .fbc 容器（含 FuncEntry.retType 签名），
//       完成加载校验（§11.6/§11.7）；
//       源码中对预定义函数的调用编译为单元私有 user helper 调用（§8.4）；
//       编译时自动导入：std.time（DateTime）、std.math.numeric（Decimal）、
//       std.collection（ArrayList/HashMap）、fountain::f_regex（String.regex() 扩展，v0.17）；std.core 按仓颉规则始终隐式可用；
//       编译粒度是整单元（§9 附则 11），CALL_FUNC 经 §11.7 目录自动互连（支持相互递归）；
//    2. 并发去重：以 (源码指纹) 为键查询进程级编译缓存——命中 Ready 复用同一
//       JitFunction；他人 Compiling 中则等待其完成（成功共享结果、失败共享异常），
//       确保【相同源码只编译一次】；Miss → CAS 占位后执行后续步骤；
//    3. 引擎选择：OS 为 Linux 且指令集在仓颉 SDK for Linux 支持范围内
//       （当前 = x86_64 / aarch64）→ 立即将字节码 JIT 为机器码；
//       否则编译到此结束（仅解释器，diagnostics 记录，§12.1）；
//    4. 返回入口函数对象（fnId == entryFn），单元内其余函数随之就绪。
//    失败在此刻抛出，不涉及运行期错误槽；失败结果同样入缓存（同键复用同一异常）。
public func compile(source: String): JitFunction      // Compiler 实例方法（§8.4）

// ①b 分发入口：直接装载 .fbc 产物（T1 黄金字节码场景）
//    管线同上（步骤 1 换为装载校验；去重键换为字节码指纹），共享同一管线与缓存。
//    注意：分发入口没有预定义函数注册表——.fbc 中出现 user helper hid → 加载期拒绝（§8.4）。
public func compile(unit: SourceUnit): JitFunction    // Compiler 实例方法（§8.4）

// ②③④ JitFunction 的三个执行成员（同一处声明；②③ 为 private，④ 是唯一对外执行成员）+ ⑤ 生命周期成员（v0.13）
extend JitFunction {

    // ② 桥内部执行入口：语义等价于直接解释执行
    //    errCode>0  → throw JitException
    //    errCode=-2 → throw InterruptedException
    //    errCode=-1 → 内部退回解释器重跑（对调用方透明，可能补抛解释器的异常）
    private func invoke(
        ctx: CallContext
    ): JitValue

    // ③ 桥内部不抛入口：热路径 / 批量调用
    //    任何失败（含 DEOPT 后解释器异常）都收敛为 Err(JitException)
    private func tryInvoke(
        ctx: CallContext
    ): Result<JitValue, JitException>

    // ④ 唯一对外执行成员：统一函数包装（机制与六步流程见 §8.2）
    public func call<T>(args: Array<Any>): T

    // ⑤ 生命周期成员（v0.13，非执行成员；状态机与资产清点见 §8.7）
    public func unload(timeout!: ?Duration = None): Bool
    public prop isUnloaded: Bool
}
```

**支撑类型**：

```cangjie
public class JitException <: Exception {
    public let code: Int64          // §2 错误码
    public let site: Int64          // 字节码偏移，-1 表示未知
    public let fnId: Int64
    public let sourcePos: ?SourcePos // 由 site 查表得到，可能为 None
    public let message: String       // 桥按 code + site 静态表组装
    public let cause: ?String        // code=99 时附 helper 原始描述
}

public struct CallContext {
    public var args: Array<Int64>        // 入参 cell
    public var literalCopy: Bool = false // M2：字面量深拷贝
    public var strictFp: Bool = false    // bit0 → ctx.flags
    public var deadline: ?DateTime       // 配合 interrupt_poll
}

public enum JitMode { Off | Auto | Force }

public class CompileOptions {
    public var jit: JitMode = JitMode.Auto
    public var cpuFeatures: UInt64 = 0        // M2：显式 ISA 开关
    public var diagnostics: DiagnosticsSink   // 降级/告警接收器（接口从略；§12.1/§13.2 T7 依赖其记录）
    public init(diagnostics: DiagnosticsSink) { self.diagnostics = diagnostics }
}

public struct SourceUnit {
    public let raw: Array<UInt8>     // 已加载 .fbc 的 code/const/site 三段
    public let entryFn: UInt32       // §11.6 容器头；函数目录见 §11.7
}                                 // 分发入口 compile(unit) 的输入（§8 ①b）

public enum JitValue {
    | Int(Int64) | Float(Float64) | Handle(Int64) | Unit  // Handle=句柄 ID（已按 §8.1 逃逸，经 HandleTable.get 取回对象）
}
```

**桥的三态收尾（private `invoke` 内部固定流程）**：

```
0. **入口断言**：`f` 未卸载（状态 Ready，§8.7）——否则抛 `JitException(19)`（site=-1），不进入后续步骤
1. ctx.errCode = 0; ctx.site = -1; ctx.hwTop = ctx.hwBase; ctx.fnId = f.id
2. rax = rawEntry(ctx, &args[0], nargs)
3. 按 ctx.errCode 分派（伪码）：
     0   → unbox(rax)                     // 正常；返回句柄先按 §8.1 逃逸（迁出窗口）
    -1   → interp.run(f, ctx)              // 解释器重跑，其抛出的异常原样上抛
    -2   → throw InterruptedException
    >0   → throw JitException(code, site, ...)
4. （tryInvoke）把第 3 步的所有 throw 收进 Result.Err
```

调用方感知示例：

```cangjie
try {
    let r = f.invoke(ctx)
} catch (e: JitException) {
    println("jit error code=${e.code} at site=${e.site}: ${e.message}")
}
```

**引擎选择（跨平台一致）**：`CompileOptions.jit` 取值 `Off / Auto / Force`。只有 **Linux、且指令集在仓颉 SDK for Linux 支持范围内**（当前 x86_64 / aarch64）才可能产生机器码；其他平台（Windows / macOS / HarmonyOS / 当前 SDK 未支持的 Linux 架构）一律**静默降级为解释器**，并在 `CompileOptions.diagnostics` 记一条说明——**绝不因此报错，也绝不改变语义**（见 §12.1、§13）。三个入口的签名与语义在任何平台完全相同。

### §8.1 句柄生命周期与桥 Marshal（v0.4）

对象实例 ↔ 句柄 ID 的转换是**桥独占职责**，机器码与解释器核心只处理整数 ID（I2/I8）。句柄进入字节码世界的三条路径与一个逃逸出口：

| 路径 | 时机 | 登记动作 | 强引用根 |
|---|---|---|---|
| A 常量 | 加载 `.fbc` 时 | 加载器实例化 const 段（kind 3–10）登记 ConstTable（§3.3） | ConstTable（freeze 只读） |
| B 参数 | 执行前 | 桥 `pin` 宿主对象，ID 写入 `ctx.args[i]`（§8） | 宿主调用方 |
| C 窗口分配 | 执行期 | 分配型 helper（§6：H24–H29、H32–H41、H50–H51、H53–H54、H58–H61、H69、H70–H71）追加槽并推进 `hwTop`（§9.6） | 窗口 `[hwBase, hwTop)` |
| D 逃逸 | unbox 时 | 桥把返回的句柄槽迁出窗口、提升为持久根 | HandleTable 逃逸区/宿主 |

**Marshal API 签名草案**（与 §6 `HandleTable.fetch` 同族，示意；**纯 Cangjie 自实现**——句柄表即桥持有的托管容器：`pin` = 存入并返回下标、`get` = 按下标取出，仓颉 GC 天然把容器内的引用当根集合。仓颉不提供、本方案也**不需要**"对象→裸指针"API，此即冻结决策 ④ 的动因）：

```cangjie
public class HandleTable {
    // 路径 B：对象 → ID。同表内同对象复用同 ID；tag 按 §6 类型 token 写入
    public static func pin<T>(obj: T): Int64
    // 路径 D 的读回（宿主侧，返回 Option；与 §6 helper 边界的抛错式 fetch 相区分）
    public static func get<T>(id: Int64): ?T
    // 逃逸句柄显式释放（不调用则随逃逸区生命周期结束）
    public static func release(id: Int64): Unit
    // 窗口初始容量（可配置；默认 128 = 2^7，§9.6）。有分配单元调用入口以本值写 ctx.hwCap；
    // 可在调用前调整，对之后开始的调用生效（进行中调用不追溯）
    public static var initialCapacity: Int64 = 128
    // 全局槽上限（可配置；默认 2^20 = 1048576，§9.6）。运行中调大即时生效；
    // 调小不追溯已占用槽。触顶 → 16（路径 B/C/D 与逃逸区共用）
    public static var capacityLimit: Int64 = 1048576
}
```

**逃逸规则（三态收尾第 3 步的强制部分）**：

1. 函数签名返回引用类型时，桥在 `unbox` 前把返回句柄对应槽**迁出窗口**：强引用登记入逃逸区，表项保留、ID 不变；随后窗口重置 `hwTop=hwBase` 不影响该槽（§9.6）。**返回句柄属路径 A（常量）时本步骤为 no-op**：对象已在持久区（处置矩阵 A 行），ID 不变且跨调用稳定（规则 4；有效期 = 单元存活期，§8.7）。
2. 逃逸句柄存活至 `release(id)` 或宿主侧逃逸区销毁；期间表项**不得重用**（`gen` 不变，保证宿主持有的 ID 稳定有效）。
3. 逃逸区受句柄表同一全局上限约束（§9.6，默认 2^20 槽），超限 → `ERR_HANDLE_WINDOW_FULL(16)`。
4. **跨调用 ID 稳定性（冻结语义）**：同一次调用内 ID 稳定（`EQ_H` 可靠）；**跨调用仅常量句柄（路径 A）保证同 ID**——路径 C/D 的结果因重放或重复分配**不保证同 ID**（值不可变 ⇒ 等值）。宿主不得缓存/比较跨调用句柄 ID，应以值比较（`get` 后比较或字节码内比较）为准。常量同 ID 保证的作用域 = **单元存活期**：单元卸载后旧常量 ID 一律作废，宿主不得跨卸载缓存/使用任何 ID（§8.7）。
5. Marshal 与逃逸操作由宿主侧同步保护（§9.7）；对机器码与解释器核心完全不可见。
6. **逃逸回收的自动化边界（冻结，v0.4.2）**：① `call<T>` 路径**自动回收**——解包（`get`）完成时宿主已持有对象引用，且按规则 4 宿主不得跨调用缓存句柄 ID，故桥随即释放本次调用的**窗口分配**逃逸槽（`hwBase ≤ id < hwTop`，`gen` +1 允许复用）；路径 A/B 的 ID 不在回收之列（不在窗口区间，且分配型 helper 产的都是新对象，不会与常量/参数 ID 撞号）。② `invoke` 路径（`JitValue.Handle`，桥内部）**只能显式 `release`**：宿主持有的是 ID 本身，桥无法感知其使用何时结束——ID 是可复制的普通整数值（无引用计数回调）、GC 不通知桥、依赖 GC finalizer 则时机不确定（`JitValue` 为值类型）。③ 错误 16 时**不做**批量自动清理：16 由历史逃逸累积造成，自动清理会把宿主仍在使用的 ID 作废（违反规则 2），把资源错误变成静默数据错配；正确处置是宿主先 `release` 再重试。

**保活矩阵**：

| 句柄来源 | 强引用根 | 存活期 | 失效方式 |
|---|---|---|---|
| A 常量（kind 3–10 实例化） | ConstTable | 整个单元生命周期 | 单元卸载（§8.7，v0.13 起为真实能力；卸载后旧 ID 作废） |
| B 参数（`pin`） | 宿主调用方 | `pin` 至调用结束 | 宿主释放对象 |
| C 窗口分配（helper 结果） | `[hwBase, hwTop)` | 单次调用 | 返回/重放前重置 `hwTop` |
| D 逃逸（返回值） | 逃逸区/宿主 | `unbox` → `release`；`call<T>` 至解包完成（自动回收，§8.1 规则 6） | `invoke`：显式 `release` 或逃逸区销毁；`call<T>`：桥自动回收 |

> **单元卸载（v0.13，§8.7）**：提供 `JitFunction.unload`——整体回收单元全部资产（ConstTable + A 常量槽 + code buffer + fnTable + 适配器注册表条目 + 编译缓存条目），状态机 `Ready → Unloading → Unloaded` 保证与活跃调用/并发编译的安全交互。常量同 ID 契约随卸载终止（§8.1 规则 4）；跨卸载缓存 ID 属禁止事项（§8.3）。

### §8.2 统一函数包装：`JitFunction.call<T>`（v0.4）

**定位**：编译器内部的函数包装机制——把字节码与 JIT 产物统一封装为普通仓颉函数；`call` 是 `JitFunction` **唯一对外暴露**的执行成员（`invoke/tryInvoke` 已声明为 private，仅供桥内部与 `call` 使用，三个成员的签名同处 §8）。所有句柄转换（§8.1 `pin`/逃逸）与类型转换（`Any` ↔ cell ↔ 仓颉值）均在编译器与 `call` 内部完成，对宿主代码完全透明；底层是机器码还是解释器不可感知（I7）。

**编译器生成的适配器（核心机制）**：`compile()` 按整单元签名信息为每个函数生成两个内部转换器，并在 `call<T>` 被**单态化**时按 `(签名, T)` 组合生成、缓存最终适配器——T 在编译期实例化点已知，因此解包末端的 downcast 是编译期生成的强类型代码，**不依赖运行期反射**：

```
argMarshalers : Array<(Any) -> Int64>   // 第 i 个 Any 元素 → 第 i 个 cell（含 §8.1 pin）
retUnboxer    : (Int64) -> Any          // 返回 cell → 具体仓颉值（句柄型先走 §8.1 路径 D 逃逸）
```

**`call` 固定六步**：

1. `args.size != nargs` → `JitException(19)`。
2. 逐参 Marshal（§8.2.1 表）；任一元素类型不符 → 19。
3. 组装 `CallContext`，进入三态收尾（§8）执行——**执行期异常原样转换抛出**（§8.2.3），不吞不改。
4. `retUnboxer` 解包返回 cell（句柄型先逃逸）。
5. T 与签名返回类型一致性：同一编译单元内在调用点**静态校验**（编译期报错）；跨模块/动态绑定场景由适配器注册表**运行期校验** → 不符 → 19。签名返回类型来源：源入口 = lambda 尾表达式静态推导写入 `FuncEntry.retType`（§8.0/§11.7）；分发入口同理读自 `.fbc`。
6. 返回 `T`。

- **CallContext 派生字段**：`call` 使用默认 `CallContext`（`strictFp=false`、`deadline=None`、`literalCopy=false`）；需要自定义时改用 `invoke/tryInvoke`。
- **适配器注册表**（第 5 步）：以 `(单元指纹, fnId, T 的编译期类型标识)` 为键，单态化时写入；动态绑定查无此键 → `JitException(19)`。
- **资源清理机制（try/finally）**：自第 2 步 Marshal 起，本次调用的全部句柄登记（B pin、C 窗口、D 逃逸）都在 `try` 保护内；`finally` 释放**本次调用登记的非常量槽**——成功与失败（含执行期异常）路径一致，这是 §8.3 ③"失败无残留"与 §8.1 规则 6① 的实现机制。**A 常量槽不在任何调用清理路径中被释放**——其唯一释放点是单元卸载（§8.7）；§8.1 规则 4 的常量同 ID 保证（单元存活期内）依赖它。
- **ctx 非托管内存的配对释放（finally 义务）**：ctx 是本方案**唯一的 GC 管辖外内存**（§4）——其 malloc/free 或 `acquireArrayRawData`/`releaseArrayRawData` 配对释放同样在 `finally` 内完成（宿主对象表、ConstTable、逃逸区均为托管容器，GC 兜底；唯 ctx 需显式配对）。桥不得在任何路径（含抛异常路径）遗漏配对，否则即真实内存泄漏——T27 覆盖。

**§8.2.1 参数 Marshal 表（`Any` → cell）**：

| 签名参数类型 | 接受的 `Any` 实际类型 | 转换 | 失败 |
|---|---|---|---|
| `Int64` | `Int64` | 原值 | 19 |
| `Float64` | `Float64` | IEEE 位模式 | 19 |
| `Bool` | `Bool` | 0/1 | 19 |
| `String/Decimal/DateTime/Duration/Range/Regex/List/Map` | 对应引用类型 | `HandleTable.pin`（§8.1 路径 B） | 19 |

- **不做数值宽化与混合提升**（§11.9 提升规则是前端编译期职责，`call` 不重做）；不接受 `Option`/null（句柄传 null → M1 不支持）。
- `pin` 失败抛 `JitException`：句柄表全局上限 → 16；不接受的对象类型（无类型 token，如宿主自定义类）→ 19。

**§8.2.2 返回解包表（cell → `T`）**：

| 签名返回类型 | 解包 | `T` 校验 |
|---|---|---|
| `Int64` / `Float64` / `Bool` / `Unit` | 原值 / 位模式 / 0↔false / 忽略 | `T` == 该类型 |
| `String/Decimal/DateTime/Duration/Range/Regex/List/Map` | 逃逸（§8.1 路径 D）→ `get` → 对象引用 | `T` == 该类型 |

- 执行期已失败（`errCode > 0`）→ 不解包，直接按三态收尾抛出（rax 未定义，I5）。
- 返回引用类型经逃逸 + `get` 交付后，本次调用的窗口分配逃逸槽由桥**自动回收**（§8.1 规则 6）——`call<T>` 不产生跨调用句柄泄漏；`release` 仅桥内部 `invoke` 路径需要。

**§8.2.3 异常转换清单（`call` 捕获一切执行异常）**：

| 来源 | 转换结果 |
|---|---|
| 三态收尾 `errCode` 1–20 / 99 | `JitException`（§2 映射，原码原 site；19 为桥层契约错误不经此路） |
| `errCode` = -2 | `InterruptedException` |
| `errCode` = -1 | 内部解释器重放，宿主不可见 |
| Marshal / T 校验失败 | `JitException(19)`（`site=-1`，`sourcePos=None`） |
| helper 内部异常 | 已在 helper 边界转码（§6/§9.5），最终以 1–20/99 浮现 |

- `call` **绝不让非 `JitException`/非 `InterruptedException` 的底层异常逃逸**——桥内兜底转换为 99（§9.5），这是"捕获编译产物执行过程中的所有异常"的规范定义。
- **宿主处置约定**：1–20 按域错误处理（19 = 桥层契约错误；17 = 源语言 throw，回译为源语言异常语义；4/5 等可按业务取默认值；20 = 源程序试图写常量容器，属前端缺陷或需改用可变副本）；**99 = 实现缺陷信号，必须上报**（`cause` 即原始异常描述），不得按可恢复错误吞掉；-2 按取消处理。反模式：`catch (e: Exception)` 泛兜并忽略——宿主侧的泛兜只会销毁桥已完成分类的信息（§9.5 在 helper 内的同类兜底是义务，因为那是"翻译"层；宿主是"消费"层）。
- 19 不属于字节码执行错误码（不经错误槽），由 T15 覆盖；T6 仍只覆盖执行期错误码。

### §8.3 调用契约与线程模型（v0.4）

**前提**：编译产物——无论 `.fbc` 字节码还是 JIT 机器码——必须支持**可重复、并发安全的多次调用**：同一 `JitFunction` 可被任意线程、任意次数调用；同输入下结果、错误码、site 逐位一致（I7），且实现不得引入任何"跨调用可见"的可变态。字节码与 JIT 两引擎在本契约下无差别。

**① 调用契约与线程模型**

- 宿主唯一对外路径是 `call<T>`（§8.2）；一次调用 = 一个独立事务：Marshal（§8.2.1）→ 执行（三态收尾 §8）→ Unbox/逃逸（§8.2.2）→ 复位。
- **每线程独立栈帧**：ctx（64 B）与机器帧随**调用栈**分配（§1/§3.1），操作数栈与全部局部槽都在帧内。两个线程调用同一函数 → 两份完全独立的帧与 ctx，物理上位于各自线程栈，不存在共享寻址。
- 桥的调用义务（§4）：入口前复位 `errCode=0; site=-1; hwTop=hwBase; fnId`；返回后先读 errCode、非 0 不得使用 rax（I5）。

**② 并发安全依赖的机制**

| 机制 | 层面 | 出处 |
|---|---|---|
| 编译产物只读 | 字节码常量/目录/类型表加载后只读；机器码页 W^X 后只读执行 | §11.7、§12.5 |
| 线程私有帧/ctx | 栈上分配，随调用销毁 | §3.1、§9.7 |
| 常量表 freeze | 只读共享的前提 | §3.3、§9.7 |
| 句柄表/逃逸区同步 | 槽追加与逃逸登记由宿主侧锁保护 | §8.1、§9.7 |
| 适配器注册表同步 | 编译期注册 / 卸载期移除由宿主侧锁保护（键 `(单元指纹, fnId, T)`） | §8.2、§8.7 |
| 编译去重与状态机 | 单元级"只编译一次"、函数级 JIT 编译状态机 | §12.6 |
| 安全点（非抢占） | 仅 LOOP_BACK 回边 interrupt_poll；无异步抢占 → 无信号安全负担 | §12.6 |
| GC 协作 | 机器码不持裸指针；线程的窗口槽 = 该线程的 GC 根集合 | I2/I8、§9.6 |

**③ 重复调用的状态隔离与复位**

- 复位点唯一：每次调用入口由桥复位（三态收尾第 1 步）。除此之外**没有任何跨调用残留通道**：
  - 帧内状态（操作数栈、局部槽、hwBase 镜像）随帧分配、随帧销毁；
  - 局部槽卫生填充不可观察（§3.1）——第二次调用不可能读到第一次的值；
  - 窗口槽调用后回收（未逃逸），逃逸槽归逃逸区接管（§8.1）；
  - 静态数据（常量/目录/机器码）执行期只读，零变异。
- DEOPT 重放是**同一调用内部**的实现细节（重放重新分配等值对象，I8），对外仍等价一次调用。
- 失败调用同样无残留：错误只经 ctx 传递、随帧销毁；重试即全新调用。

**④ 局部变量的作用域与生命周期边界**

- 作用域：函数体内（CALL_FUNC 被调函数拥有自己的帧与局部，互不共享，§4）；
- 生命周期：**一次调用**——帧存活期即局部生命周期，返回即销毁；
- **不得跨线程共享**：局部槽在线程栈上，M1 不提供任何将其暴露给其他线程的机制（无静态/全局局部、无闭包逃逸与按引用捕获——词法嵌套闭包按值快照捕获，§8.5；`ctx` 指针不得被保存复用——它随调用栈销毁）；
- 跨调用持久状态在 M1 中**不存在**：唯一持久物是只读常量与逃逸句柄（均由宿主管理，§8.1）；需要跨调用状态时由宿主持有并经参数显式传入。

**⑤ 跨线程数据传递**

正确方式：

| 传递物 | 为什么安全 |
|---|---|
| 值型 cell（Int64/Float64/Bool） | 按值拷贝，无共享 |
| 不可变值对象（String/Decimal/DateTime/Duration/Range/Regex）经参数/逃逸返回 | **不可变 ⇒ 多线程同时读无竞态**（§3.2） |
| `JitFunction` 本身 | 编译产物不可变，任意线程并发调用（§12.6） |
| 只读常量（含常量 List/Map） | 按**只读契约**使用 |

禁止事项：

| 禁止 | 原因 |
|---|---|
| `List/Map` 实例跨线程共享并写入 | 容器可变且无同步（M1 的只读指令面不等于宿主对象不可变）；宿主修改常量容器同样违反只读契约 |
| 保存/复用 `ctx` 指针、帧地址、局部槽地址 | 随调用栈销毁，复用即悬挂 |
| 缓存非逃逸/非常量句柄 ID 跨调用使用 | §8.1 规则 4（重放/重分配不保证同 ID） |
| helper 读写跨调用可见的可变态 | 破坏"可重复调用结果一致"（纯度约束：helper 除分配不可变值、窗口登记与**变更型 helper 的容器修改**（H43–H48，§9.15）外不得有副作用） |
| 修改机器码页 / 字节码常量 | 违反 W^X 与只读契约 |
| 跨卸载缓存/使用句柄 ID（含常量 ID） | 卸载后旧 ID 作废（§8.7/§8.1 规则 4）；表项复用 + 同 tag 重分配无法静态区分，违反即未定义 |

**取消及时性边界（v0.12.1 审计补充）**：`-2` 仅在 `LOOP_BACK` 回边安全点产生（§5/§12.6）——**helper 执行期间不可中断**：正则匹配（含潜在灾难性回溯）、大串切片/替换、`user helper` 宿主代码等长操作会推迟取消的感知，延迟上界 = 该 helper 剩余执行时长。M1 不在 helper 内设安全点（M2 议题）；调用方对取消延迟的预期以此边界为准。

---

### §8.4 编译器门面与预定义函数（v0.8，冻结）

**Compiler 类（需求 1：实例化 + 配置）**：编译器封装为实例——一个实例 = 一个编译上下文（配置 + 预定义函数注册表 + 编译缓存视图）。§8 的过程式 `compile(source)` 自 v0.8 起并入实例方法（配置于构造时绑定）。

```cangjie
public class Compiler {
    // 需求 1：构造配置——jit 引擎选择、诊断接收器（CompileOptions.diagnostics）、
    // 实例名、预定义函数注册上限
    public init(name!: String = "compiler", opts!: CompileOptions,
                maxPredefined!: Int64 = 256)

    // 需求 2：预定义函数注册。重名 → SourceCompileException(kind=DuplicateRegistration)（禁止覆盖）；
    // 注册/注销只影响之后的 compile(source)，已编译产物不受影响（快照语义）。
    public func registerFunction(fn: PredefinedFunction): Unit
    public func unregisterFunction(name: String): Unit   // 未注册 → CompileException
    public func hasFunction(name: String): Bool
    public func registeredNames(): Array<String>

    // 需求 3：源入口编译（§8.0 格式）。body 内对预定义函数的调用经名字解析编译为
    // user helper 调用（见下）；未注册/未定义标识符 → SourceCompileException（需求 4）。
    public func compile(source: String): JitFunction

    // 分发入口（T1）：装载 .fbc。无预定义函数注册表上下文——
    // .fbc 中出现 user helper hid（[0x0100,0xFFFF]）→ 加载期拒绝（JitException(18) 语义）。
    public func compile(unit: SourceUnit): JitFunction
}

/// 预定义函数：签名（按 §11.7 LocalType 编码：0–8 与 10–11；9=Regex、12=Closure 非法——闭包值不跨桥/不进宿主闭包，§8.6）+ 实现。
/// impl 接收**已解包的仓颉值**（句柄型经 HandleTable.get 取回对象引用；值型原值），
/// 返回值须与 retType 匹配（实现侧应提供 LocalType 常量，§11.7）。
public class PredefinedFunction {
    public let name: String                        // 源码中的调用名（仓颉标识符）
    public let paramTypes: Array<UInt16>           // LocalType 编码序列
    public let retType: UInt16
    public let impl: (Array<Any>) -> Any
    public init(name!: String, paramTypes!: Array<UInt16>, retType!: UInt16,
                impl!: (Array<Any>) -> Any)
}

/// 编译期诊断异常（不占用 §2 运行期错误码——compile 失败"不涉及运行期错误槽"，§8）
public class SourceCompileException <: Exception {
    public let kind: String      // UnregisteredFunction | UndefinedIdentifier |
                                 // BadParameterList | MissingArrow | DuplicateRegistration | ...
    public let position: Int64   // 源码字节位置
    public let hint: String      // 修复提示（含已注册函数清单）
}
```

**预定义函数 = 单元私有 user helper（CALL_HELPER 通道）**。选择 CALL_HELPER 而非提前启用 CALL_HOST（M2），理由：① 调用点编译期**静态解析**（注册表在编译期固定）→ 静态 hid + 自动 `CHECK_ERR`；② 复用 helper 全套机制（trampoline ABI、错误转码、窗口登记）；③ CALL_HOST 的运行期动态回调语义留给 M2。

- **hid 编码（冻结）**：固定 helper H01–H62、H69 ↔ hid 1–62、69（v0.15：+H60/H61；v0.16：+H62；v0.16.1：H49/H62 重定义为迭代器——`map_iter_begin`/`map_iter_step`；v0.17：+H69 `str_to_regex`）；**63–68、70–255 保留**（63–68 为 M2/M3 草案规划占用）；**user helpers ↔ hid [0x0100, 0xFFFF]**（slot = hid − 0x0100，上限 65280，受 `maxPredefined` 收紧）。hid 0 非法。
- **编译期名字解析（需求 4）**：body 中 `name(` 调用点按顺序解析——`recursive` → 自递归（§8.0）；命中注册表 → user helper（实参表达式**从左到右**求值，逐参按签名静态校验）；未命中 → `SourceCompileException(kind=UnregisteredFunction)`，消息含**名字、字节位置、已注册清单与修复提示**。非调用的未定义标识符 → 同类异常（kind=UndefinedIdentifier）。**编译期错误不占用 §2 运行期错误码**。
- **运行路径（需求 3）**：`CALL_HELPER userHid` 与固定 helper 完全同构——`call trampoline` + 自动 `CHECK_ERR`；trampoline 按 (单元, slot) 查注册表快照 → **按签名 marshal**（实参 cell → 仓颉值：句柄型经 `HandleTable.get` 取回对象引用，值型直取）→ `impl(values)` → 返回值按 retType 校验 → 值 → cell（**返回句柄型 = 分配型语义：结果登记 1 槽**，逃逸/自动回收照 §8.1）。
- **异常转码（§9.5 user 版）**：impl 抛出的任何异常由 trampoline 兜底——已知语义（除零 → 1 等）→ 对应码；未知 → **99**（cause 附原始描述），绝不让宿主异常穿越机器码边界。**cause 通道为调用私有**：错误描述字符串由宿主侧按本次调用记录（随调用销毁，不跨调用/线程共享）——并发失败调用各自的 code/site/cause 互不串扰（§8.3）。
- **纯度与重放（保守冻结）**：预定义函数是**副作用黑盒**——一律按 §9.15 变更型处理：含其调用的函数 → `FuncEntry.flags.bit0` → deopt 源禁用 + 防御性 -1 → 99；返回句柄的 user helper 同时是分配型（登记窗口槽）。注册者应自行遵守准入准则（§6：确定性、副作用自担）——运行期安全性由上述保守规则保证，不依赖注册者自觉。
- **分发边界**：预定义函数是**编译器实例的宿主侧资产**，不写入 `.fbc`（闭包不可序列化）；其产物仅在本实例存活期内可执行；分发入口装载含 user hid 的 `.fbc` → 加载期拒绝。跨进程共享预定义函数属 M2（CALL_HOST + 序列化注册协议）。
- **并发**：注册表由宿主侧锁保护（§9.7）；register/unregister 只影响之后的 compile——已编译产物持有注册表**快照**（slot → 函数引用），不受后续变更影响。**impl 可能被多线程并发调用**——实现须可重入、无共享可变态（纯度约束，§8.3 禁止表）；违反的后果由注册者自担（§6 准入准则：副作用自担）。

使用示例（§8.0 lambda 源；需求 2/3/4 全路径）：

```cangjie
let c = Compiler(name: "demo", opts: opts, maxPredefined: 64)
// 需求 2：注册
c.registerFunction(PredefinedFunction(name: "double",
    paramTypes: [LocalType.I64], retType: LocalType.I64,
    impl: { args => (args[0] as Int64).getOrThrow() * 2 }))
// 需求 3：被编译代码调用（参数传递 + 返回值处理）
let f = c.compile("{ x: Int64 => double(x) + x }")
let r = f.call<Int64>([21])            // double(21) + 21 = 63
// 需求 4：未注册函数 → 清晰的编译期错误
let g = c.compile("{ x: Int64 => unknown(x) }")
// → SourceCompileException(kind=UnregisteredFunction, position=…,
//    hint="位置 …：调用了未注册的预定义函数 \"unknown\"。已注册：[double]。…")
```

---

### §8.5 嵌套闭包、立即调用与注释（v0.9，冻结）

**形式**：lambda body 内可定义嵌套闭包（与 §8.0 同一 lambda 语法），并支持声明处立即调用与源码注释：

```cj
{ n: Int64 =>
    let a = 10
    let add = { y: Int64 => a + n + y }      // 嵌套闭包：按值捕获 a、n
    add(5)                                    // 闭包调用 → 15 + n
}

{ x: Int64 =>
    let c = {=> x * 2}()                      // 声明处立即调用（IIFE）→ c = 2x
    c
}

{ n: Int64 =>
    let fact = { k: Int64 => if (k <= 1) { 1 } else { k * recursive(k - 1) } }
    fact(n)                                   // recursive = fact 自身
}
```

**闭包值模型（核心决策；v0.9 的"词法绑定（编译期绑定、非运行时值）"自 v0.10 起被本模型统一取代，捕获快照语义不变）**：闭包表达式求值产生**运行时闭包值**（句柄，token 9 / LocalType 12，详见 §8.6）——

- 闭包声明（作为表达式）→ 前端生成一个**独立 FuncEntry**（§11.7 目录多函数化；`entryFn` 仍为顶层 lambda），并发射 `closure_new`（H54，分配型）：**求值 = 创建不可变闭包对象**（fnId + 捕获快照），结果为句柄；
- 闭包变量的调用 `add(5)` → `CALL_CLOSURE`（0x7F，§8.6）：栈 = [闭包句柄, 实参…]；被调帧 `locals[0]` = 闭包句柄，捕获经 `LOAD_CAP`（0x26）按需读取；
- 闭包变量可赋值给同签名变量、向下传给 CALL_FUNC 被调函数、被嵌套闭包按值捕获（句柄快照）、在 CALL_FUNC 链内返回（retType=12）；**不可逃逸**（跨桥/存容器——§8.6 边界与设计理由；「链内返回」不属逃逸）。

**捕获语义（冻结：按值快照）**：

- 嵌套闭包捕获其词法作用域内、**声明之前已赋值**的变量（声明点的捕获即读取，明确赋值 §7 校验 10 自然校验；声明后才首次赋值的变量被捕获 → 编译错误）；
- **捕获 = 创建时刻的值快照**：之后外部对 `var` 的重新赋值**不改变**闭包看到的值。这是与仓颉原生按引用捕获的**有意差异**——M1 局部槽是帧内 64 位值、无堆上环境（§8.3④），按引用需要 boxed upvalue 堆槽，属 M2；
- 捕获不延长变量生命周期（快照经 `closure_new` 打包进闭包对象，随闭包句柄存续于窗口，§8.6）；
- 内层闭包可捕获外层闭包的参数/局部，以及**外层的闭包变量**（闭包句柄按值快照捕获——内层调用它 = `CALL_CLOSURE`）；递归嵌套逐层可见；
- 遮蔽：嵌套闭包的参数/局部可遮蔽外层名（内层引用遮蔽名 = 内层变量；未遮蔽名 = 捕获）；同一作用域重复定义同名闭包变量 → 编译错误。

**`recursive`（对 §8.0 关键字的绑定细化）**：`recursive` 绑定**最近一层词法闭包**（含顶层 lambda）——嵌套闭包内即"调用该嵌套闭包自身"，实参 = 当前层的捕获快照 + recursive 实参。注意：内层闭包内裸 `recursive` 被内层绑定**遮蔽**，无法直达外层 lambda——需要调用外层时的两条路：① 词法闭包变量模式（外层 `let f = {...}` → 内层词法引用 `f`）；② **v0.12 值化捕获**：任意层 `let self = recursive` 把当前层自引用闭包值存入变量（§8.0 值位），嵌套闭包按值捕获后即可 `self()` 递归调用该外层——外层为闭包实例时其捕获快照随句柄携带，语义 = 完整重入该层；外层为顶层 lambda 时经隐藏适配器转发（§8.0）。裸 `recursive` 的绑定规则不变（仍遮蔽至最近层）。降低（v0.10）：闭包内 `recursive(args)` = `LOADL 0`（自身闭包句柄，闭包函数帧约定，§8.6）+ `CALL_CLOSURE`；**顶层 lambda 内**维持 `CALL_FUNC <entryFn>`（§8.0）。**v0.17 尾位置特例**：尾位置的 `recursive(args)` 自动降为帧复用回边（实参逆序 `STOREL` + `LOOP_BACK <入口>`，不重写 `locals[0]`、不发射上述调用；§8.0）。

**立即调用（IIFE）**：`{ params => body }(args)` 在声明处直接调用，表达式的值 = 闭包返回值（`let c = {=> a + b}()` 中 `c` 即 `a + b` 的值）；实参表达式从左到右求值；降低（v0.10）：声明发射 `closure_new`、调用发射 `CALL_CLOSURE`，不经过任何绑定名。

**注释（词法层）**：

- `//` 单行注释：至行尾；`/* ... */` 多行注释：**支持嵌套**（与仓颉一致）——扫描维护嵌套深度，`/*` 使深度 +1、`*/` 使深度 −1，深度归零时注释结束（`/* /* */` 仍是注释内部）；源码结束仍深度 > 0 → 编译错误（kind=UnterminatedComment）；
- 注释可出现在源码任意 token 之间（含 arg_list 与 lambda 头内）；注释内容不参与词法（其中的 `{` `}` `//` `/*` 引号均无语义）；
- **词法预处理顺序（冻结）**：① 字符串字面量保护（**全部三形态（§8.8，v0.14）**：单行 `'…'`/`"…"`、多行 `'''`/`"""`、原始 `#`×n 定界——其完整跨度内的 `//`、`/*`、`{`、`}`、引号、`>|` 不参与配对与注释识别）→ ② 注释剥离 → ③ 解析。即：字符串字面量内部不识别注释，注释内部不识别字符串；
- 注释不影响字节码偏移与 site（字节码无注释；site → 源位置映射照常，T24 断言"注释不改变错误报告位置语义"仅指剥离后解析）。

**与既有机制的交互**：

- **多函数目录**（§11.7）：目录 = 顶层 lambda + 每个嵌套闭包各一个 FuncEntry；嵌套闭包之间的调用与互递归经 `CALL_CLOSURE`（同单元 .fbc 的静态多函数场景为 `CALL_FUNC`）支持，不依赖编译顺序（§9 附则 11）；
- **明确赋值**（§7 校验 10）：闭包声明点的捕获 = 外层函数的读取（外层数据流分析）；闭包体内的局部在**闭包函数内独立分析**（含其自身的回边不动点）；
- **变更型/重放**（§9.15）：嵌套闭包是独立 FuncEntry——其体内的变更型调用标记**自身** `flags.bit0`；外层经 `CALL_CLOSURE`（或分发 .fbc 的 `CALL_FUNC`）调用嵌套闭包 → 既有"经 CALL_FUNC 传递亦然"（§7 校验 11）的整函数保守判定覆盖外层；
- **I7/I8**：嵌套闭包是纯静态结构（无新运行时实体），三引擎逐位一致与重放规则照常。

**M2 边界（v0.18.8 修订）**：仍不做——按引用捕获（boxed upvalue）、闭包签名内嵌套闭包类型（非高阶）、运行期动态闭包组合；**闭包逃逸自 M2 仅开放"跨桥返回"方向**（原地提升方案见 `jit-bytecode-m2.md` §14）——**"存容器"与"跨桥实参"方向仍不做**。first-class 的局部形态（变量持有、调用、向下传参、链内返回）自 v0.10 支持（§8.6）。

---

### §8.6 first-class 闭包值（v0.10，冻结）

**类型**：闭包类型 = `(T1, …, Tn) -> R`（T/R ∈ §11.7 类型集；**禁高阶**——T/R 不得为闭包类型）。运行时表示：**宿主侧不可变闭包对象** `{fnId, captured: Array<Int64>}`，经句柄表持有（**类型 token 9 = Closure**；LocalType 12 = Closure，句柄型）。两个闭包类型兼容 = 签名逐位一致（参数个数/类型/返回类型）；类型表只记大类（12），**签名是前端/桥的静态知识**（同 List/Map 元素类型模式）。

**求值流程（闭包表达式 `{ params => body }` 作为表达式）**：前端为该 lambda 生成独立 FuncEntry（§8.5），随后发射 `closure_new(fnId, cap0…capk)`（H54，分配型）——捕获 = 体内引用的外层变量**当前值快照**（按声明序、从左到右求值）。结果 = 闭包句柄（tag=9，登记 1 窗口槽）。fnId 由前端烘焙，汇编期校验 `fid < 目录数`（§7 校验 7 扩展）。I8/重放：重放重建**等值**闭包对象（fnId 与捕获逐位相同）——闭包对象不可变 ⇒ 语义不变。

**变量绑定与赋值机制**：`let fn = {…}` / `var fn = {…}` / `fn = {…}`——`fn` 为 LocalType 12 局部槽，持闭包句柄；`let` 一次性绑定，`var` 可重赋（新闭包对象；旧对象随窗口语义回收）。赋值/传参/返回的类型兼容 = **签名一致**（不一致 → 编译错误）。

**调用时的执行逻辑**：`fn(a1…an)` → 新 opcode **`CALL_CLOSURE`（0x7F，u8 argc）**：操作数栈 = [闭包句柄, a1…an]。执行：取闭包对象 → fnId + 捕获 → 创建被调帧（`locals[0]` = 闭包句柄、`locals[1..argc]` = 实参；**捕获经 `LOAD_CAP idx`（0x26，lowering = `call H56 closure_cap`）由闭包函数序言按需加载进捕获槽**）→ 执行闭包体 → 返回 cell。两引擎实现：

- 解释器：直接读闭包对象（解释器是宿主代码，允许持引用）→ 按目录分派 fnId；
- JIT：`call H55 closure_fnid`（句柄 → fnId）→ `call H57 fn_table`（**单元函数机器入口表基址**，非 GC 内存）→ **间接调用** `call [fnTable + fnId*8]`（fnTable[fnId] = 各 FuncEntry 机器入口；入口 `endbr64` 使 IBT 安全，§12.3）。fnId 由前端烘焙并双重校验（汇编期 §7 校验 7 + closure_new），越界属实现缺陷。

**运行时存储与访问方式**：闭包对象存活于句柄表/窗口（分配型语义）；捕获快照是**调用方栈上值的拷贝**，不延长任何变量生命周期（§8.3④ 不变）；`EQ_H` 比较句柄 ID（同调用内稳定；跨调用不保证同 ID，§8.1 规则 4）。

**类型与作用域问题（冻结）**：

- 赋值/传参/返回的兼容 = 签名一致；调用实参个数/类型按静态签名编译期校验 + 运行期防御（19）；
- **生命周期/逃逸边界**：闭包值**不可逃逸出创建它的最外层调用**——不可作 `call<T>` 实参/返回（跨桥；Marshal 表不含 Closure，retType=12 的函数经 call<T> → 19）、**不可存入容器**（窗口重置 → 宿主容器悬空 ID；**M2 增量**：仅"跨桥返回"方向开放——方案见 `jit-bytecode-m2.md` §14；存容器与跨桥实参方向维持禁止）；**可以**：向下传给 CALL_FUNC 被调函数（参数槽 LocalType 12，调用期间窗口存活）、被嵌套闭包按值捕获（同调用内句柄快照）、在 CALL_FUNC 链内返回（retType=12，窗口存活）；
- 递归：闭包体内 `recursive` = 自身句柄（`locals[0]`）→ `CALL_CLOSURE`（§8.5；**尾位置**自 v0.17 自动改走帧复用回边，§8.0）；**v0.12 值位**：`recursive` 作右值 = `LOADL 0`（闭包层）/ `closure_new <adapterFn>`（顶层；隐藏适配器为闭包帧格式 FuncEntry，体 = 转发 `CALL_FUNC <entryFn>`，§8.0）——自引用闭包值可赋值、被嵌套按值捕获、按本节全部规则传递（不可逃逸出最外层调用/不可存容器/不跨桥）；被捕获后调用 = 完整重入该外层实例；
- **禁高阶**：闭包签名的 T/R 不得为闭包类型（编译错误）。

**逃逸禁令的设计理由（v0.18.6 成文）**：禁令不是实现取舍，而是四条既有硬约束的直接推论——

1. **窗口生命周期**：闭包值是路径 C（窗口分配）的宿主对象，句柄槽随三态收尾的重置（`hwTop=hwBase`）失效于调用结束；跨调用 ID 稳定只保证常量（§8.1 规则 4）。存入宿主容器 = 存一个调用结束后必然悬空的 ID——桥对容器写入无感知（ID 是可复制的普通整数值、无引用计数回调，§8.1 规则 6②），既无法感知也无法回收。
2. **桥的封闭性（编码层不存在）**：参数 Marshal 表（§8.2.1）与解包表不含 Closure 行——跨桥位置在「对象↔ID」编码层没有表示；源语言侧的「编译错误」只是这条封闭性的投射，绕过者由 `retType=12` 经 `call<T>` → 19 兜底（桥层契约错误）。
3. **单元存活耦合**：闭包对象含 `fnId`（指向本单元 FuncEntry / 函数入口表）；宿主长期持有 ⇒ 隐含「本单元不可卸载」——与 §8.7 卸载直接释放全部资产的模型冲突（卸载后旧 ID 一律作废）。
4. **确定性与重放**：deopt 重放重建**等值**闭包（新 ID，I8；对象不可变 ⇒ 语义不变）——逃逸会把「ID 跨调用不保证同 ID」暴露为可观察差异；封死在最外层调用内，重置与重放均无损、该差异完全不可观察。

配套与术语：逃逸所需的整套能力（堆上环境 / 按引用捕获 boxed upvalue）——**"跨桥返回"方向自 M2 开放**（方案见 `jit-bytecode-m2.md` §14）；**按引用捕获（boxed upvalue）仍属 §8.5「M2 边界」**——M1 first-class 只开放**局部形态**（变量持有、调用、向下传参、链内返回；窗口在调用期间存活，四者自然成立）。本节「逃逸」= 闭包值活过创建它的最外层调用；与 §8.1 的「逃逸（D 路径）」（返回值句柄正常迁出窗口的机制）**同名反义**——闭包值恰恰被排除在 D 路径之外。

**对现有语义的影响**：

- §8.5 词法绑定模型被本节**统一取代**（闭包变量即运行时值；捕获快照、遮蔽、recursive 绑定、IIFE 规则全部保留，仅降低方式更新）；
- §9.15：**含 `CALL_CLOSURE` 的函数 → `flags.bit0`**（实际调用的闭包体静态不可知，黑盒）→ deopt 源禁令；`closure_new` 是分配型，不触发禁令；
- §8.2：闭包值不跨桥——Marshal/解包表不含 Closure；
- §6 白名单：+H54/H55/H56/H57、token 9=Closure；准入准则照旧（H54 分配型）。

### §8.7 单元卸载（v0.13）

**定位**：卸载已编译单元（源入口 `compile(source)` 或分发入口 `compile(unit)` 的产物），回收其全部资产。无新 opcode、无 `.fbc` 格式变更、不改变任何字节码语义（差分测试体系不变，§13.3）。

**API**：

```cangjie
public class JitFunction {
    // 既有唯一对外执行成员 call<T>（§8.2）与 private invoke/tryInvoke 不变
    // v0.13：卸载
    public func unload(timeout!: ?Duration = None): Bool
    // true = 已卸载（含对已卸载单元的幂等重复调用）；false = 超时（单元恢复 Ready，可重试）
    public prop isUnloaded: Bool
}
```

**单元状态机**（独立于函数级 JIT 状态机与进程级编译缓存状态机，三层并存，§12.6）：

```
Ready ──unload() CAS──▶ Unloading ──activeCalls == 0──▶ Unloaded（终态，不可逆）
  ▲                        │ timeout 到期
  └────────────────────────┘（恢复 Ready，卸载未发生，可重试）
```

- **Ready**：可正常调用。
- **Unloading**：拒绝新调用（入口断言 → 19，§8.2 三态收尾第 0 步）；**正在执行中的调用不受任何影响**——不注入 -2、不抢占、正常完成并返回正确结果（卸载不改变执行中调用的可观察语义）。`activeCalls` 为原子计数：桥 `invoke` 入口 +1、`finally` −1（与资源清理同一 finally，§8.2）。
- **Unloaded**：资产已释放；再调用 → `JitException(19)`（site=-1）；重复 `unload` → true（幂等）。

**资产清点**（Unloading 排空后按序释放）：

| 资产 | 归属 | 处置 |
|---|---|---|
| code buffer + fnTable（仅 JIT 形态） | 非 GC 内存 | **最后释放**（活跃调用可能仍在执行机器码）；malloc/free 配对，T27 计数断言扩展 |
| ConstTable + A 常量槽 | 托管 + 句柄表 | ConstTable 释放 → 常量对象由 GC 回收；A 槽 `gen` +1、标记可复用 |
| 函数目录/字节码/局部类型表 | 托管 | 随 `JitFunction` 内部一并释放 |
| 适配器注册表条目 | 进程级 | 按单元指纹维度移除（键 `(单元指纹, fnId, T)`，§8.2） |
| 编译缓存条目 | 进程级 | 按指纹移除——同源码再次 `compile` 重新执行完整管线，产出**新** `JitFunction` |

**并发语义**：

- **unload vs 调用**：CAS 先行拒绝新调用，再排空活跃调用（`timeout = None` 无限等待；供给 timeout 则超时恢复 Ready）；
- **unload vs compile（同指纹 Compiling 中）**：阻塞等待其完成——成功 → 继续卸载流程；失败 → 缓存条目移除，`unload` 返回 true（与既有"Compiling 阻塞等待"语义一致，§12.6）；
- **unload vs compile（同指纹，Unloading 期间到达）**：**阻塞等待卸载完成**（缓存条目移除）→ 按 **Miss** 重新执行完整管线，产出**新** `JitFunction`——绝不返回正在卸载的旧句柄（其调用只会 19）；与"卸载完成后 re-compile"的序贯语义一致（T29），并发与序贯等价；
- **unload vs unload**：CAS 幂等，后者直接返回 true；
- **解释器形态**（Engine.Interp）：同样适用——无 code buffer/fnTable 资产，其余语义相同。

**失效与契约修订**：

- `JitFunction` 失效：Unloaded 后任何调用 → `JitException(19)`（§2）；
- **常量同 ID 契约终止**（§8.1 规则 4）：常量 ID 的跨调用同 ID 保证作用域 = **单元存活期**；卸载后旧常量 ID 一律作废。A 槽 `gen`+1 + tag 校验提供尽力拦截（同 tag 重分配不可静态区分——跨卸载缓存/使用 ID 属禁止事项，§8.3）。实际暴露面小：常量 ID 主要在字节码内流转，`call<T>` 参数走 Marshal `pin`（§8.2.1）；
- 逃逸槽（路径 D）独立于单元（per-call 逃逸区），不受卸载影响。

**测试**：T29（§13.2）。

### §8.8 字符串字面量形态（v0.14）

**来源与原则**：单行/多行/原始三形态的基础规则**与仓颉字符串字面量对齐**（`'…'` 为字符串而非字符——与仓颉一致；§8.5 词法保护按其处理）；**`>|` 每行锚定为本规格扩展**（仓颉无）。**全部处理在编译期完成**——各形态产物均为 `String` 常量（kind 3，UTF-8 字节），**无 `.fbc` 格式变更**。

**三形态（冻结）**：

| 形态 | 定界 | 转义 | 插值 | 跨行 |
|---|---|---|---|---|
| 单行（既有，顺带成文） | `'…'` 或 `"…"` | ✓ | ✓ | ✗ |
| 多行 | `'''…'''` 或 `"""…"""` | ✓ | ✓ | ✓ |
| 原始 | `#`×n + `'`/`"` … 相同引号 + 相同数量 `#`（n ≥ 1） | ✗（verbatim） | ✗（`${` 为字面文本） | ✓ |

**异种引号内容规则（v0.18.9，明确；单行与多行串均适用）**：与定界引号**不同种**的引号字符——包括其任意连续串——在串内一律为**有效内容**，**无需转义、不参与定界配对**：`'"aa"'` 中的 `"`（整个 `"aa"` 段）是字符串的有效内容（串值 = `"aa"`）；`"'aa'"` 中的 `'`（整个 `'aa'` 段）是字符串的有效内容（串值 = `'aa'`）。**多行同理**：`'''…'''` 内的 `"`/`""` 等为内容；`"""…"""` 内的 `'`/`''`/`'''` 等为内容（异种三连不终止）。**同种引号规则不变**（对照）：单行串内同种引号按既有转义规则（`\'`/`\"`）；多行串内同种引号至**首个非转义三连**为止（`'`/`''` 为内容、`'''` 终止；`"""` 同理）。原始串为 verbatim 语义（异种引号本即内容），不受本规则影响。

**多行规则（仓颉对齐 + 钉死项）**：

- 内容从开头三引号**换行后**的第一行开始——`"""` / `'''` 同行（其前）出现非空白内容 → 编译错误（kind=`MultilineHeadContent`）；
- 至**第一个非转义的三引号**为止（`\"""` 不终止；跨行允许）；内容可含除单独 `\` 外的任意字符（单独 `\` → 编译错误，同仓颉）；转义规则继承单行串语义（以仓颉为准）；
- 闭合引号前的换行与缩进**属于内容**（逐字节保留——与仓颉一致）；
- 源码结束未闭合 → 编译错误（kind=`UnterminatedMultilineString`）。

**原始串规则（仓颉一致）**：

- `#`×n（n ≥ 1）+ 一个引号（`'` 或 `"`）开头，至**相同引号 + 相同数量 `#`** 为止；内容 verbatim（转义不解码：`\n` 就是 `\` 与 `n` 两个字符）；
- 可跨行（换行与缩进逐字节保留）；EOF 前未匹配 → 编译错误（kind=`UnterminatedRawString`）；
- 只有"**相同数量 `#` + 相同引号**"才终止——内容中含更少 `#` 的引号序列不终止（与仓颉一致）。

**`>|` 每行锚定（本规格扩展，冻结）**：

- **适用范围**：仅多行形态（`'''`/`"""`）；单行与原始串不适用（原始串中 `>|` 是普通字面文本）。
- **进入判定**：串体内**任一行**存在**有效标记**（该行**首个非空白字符**起构成为 `>|`，即 `>|` 之前仅缩进空白）→ 整个串进入**锚定模式**；否则普通模式（**非空白符之后的 `>|` 不触发**）。
- **锚定模式规则（逐行）**：**有效标记** = 行内**首个非空白位置**的 `>|`（其前仅可有缩进空白）——**含有效标记的行**：标记连同其前缩进被消耗，`>|` 之后的**全部字符** = 该行内容（含行内后续出现的任何 `>|`——它们全是字面文本）；**`>|` 之前含任何非空白字符（无论何字符——含 `>`、`|` 等）→ 不是标记**（该 `>|` 是字面内容，整行按无标记行处理）；**无有效标记的行（无论空白与否）：整行字符全部原样保留**（不截取、不归一）；行内容以 `\n` 连接。
- **非标记情形（显式示例，冻结，v0.14.4）**：`>>|`（`>|` 前为 `>`）、`a>|b`（前为 `a`）、`|>|`（前为 `|`）——其中的 `>|` 一律是**字面内容**（不消耗、不截断、不触发锚定模式），整行原样保留；全文仅含此类行时按普通模式处理。
- **标记符号不进入内容（冻结，v0.14.2/v0.14.3）**：**有效标记**（首个非空白位置的 `>|`）是**纯定位语法**——连同前导缩进在切分时被消耗，**本身不属于字符串内容**，产物中不出现该标记；标记**之后**出现的 `>|` 是字面文本、照常进入内容。单独一行 `>|`（可含前导空白）→ 该行内容 = **空串**。
- **首现语义**：`>|>|abc` → 内容 `>|abc`；`>|    >|` → 内容 `    >|`（仅首个非空白位置的 `>|` 是标记；其后全部字符——含 `>|`——均为字面内容）。
- **处理顺序（冻结，歧义消除）**：① 定界扫描取原始串体 → ② **换行规范化** → ③ 锚定判定与逐行截取（在原始文本上进行）→ ④ 转义解码 → ⑤ 插值切分（若适用）。**被消耗的标记与前导缩进不参与任何后续步骤**；锚定截取在转义/插值之前——标记之后的字符正常参与转义与插值。
- **词法消歧（钉死）**：字符串起始处的三个连续引号（`'''` / `"""`）一律按多行定界识别（最长匹配）——空单行串后紧邻引号串的写法需改用另一引号或插入分隔。

**换行规范化（钉死，跨平台编译一致）**：所有形态中源码的换行序列在词法阶段统一为 `\n`（CRLF、CR 均 → `\n`）——同一源码在任何平台编译出的常量字节一致（P3 精神）。

**插值适用边界（对齐仓颉）**：单行与多行适用（前端糖不变，§9 附则 13）；**原始串不适用**（`${` 为字面文本）。

**错误 kind（前端编译错误，不占 §2 运行期错误码）**：`MultilineHeadContent` / `UnterminatedMultilineString` / `UnterminatedRawString`。

**测试**：T42（§13.2）。

---

## §9 附则（实现者必读）

1. **NaN 语义**：`CMP_F` 遇 NaN 结果未定义，汇编器**禁止**对可能含 NaN 的值发射 `CMP_F`，只能走 `EQ_F/NE_F/LT_F/...` 系（IEEE 无序 → false，`NE_F` → true）。
2. **移位**：`SHL_I/SHR_I/USHR_I` 的 b 参数取低 6 位（与 x86 `shl/sar/shr` 一致）；`b<0` 不报错，按位截断。若源语言语义不同，由前端插入 `ASSERT`。
3. **溢出检查成本**：`IADD/ISUB/IMUL` 用 `jo <bail_overflow>`，一个可预测分支；`IDIV` 需前置 `test` 与 `INT_MIN/-1` 判定（约 4 条指令）。
4. **site 精度**：只在**可能失败**的指令前写 site；纯算术指令不写（保持热路径 3–4 条指令）。错误报告中 site 精度为"最近一个可能失败点"。
5. **helper 写码规则**：多层嵌套 helper 时，内层已写码则外层**只在自身捕获到新异常时覆盖**；`catch` 顺序必须是 `catch (e: Exception)` 兜底，末尾必须能吞掉一切并写 99。
6. **窗口容量（可扩容）**：`hwCap` 为窗口初始容量（**有分配单元 = `HandleTable.initialCapacity`（默认 128 = 2^7，§8.1；可在调用前调整——调用入口由桥捕获，对之后开始的调用生效）**；无分配单元 = 0；超出由扩容兜底）。**扩容倍率（v0.18.12）**：触发时 `hwCap ← hwCap × 2`（**倍增**，以 `capacityLimit` 封顶）——单调用扩容事件 ≤ log2(capacityLimit / initialCapacity) 向上取整（默认 128 → 2^20：≤ 13 次）；几何增长的追加均摊 O(1)、空间松弛有界（`hwCap ≤ 2 × hwTop`）；承载表物理容量由宿主实现自管（语义以 `hwCap` 为准）。**两个宿主参数（`initialCapacity` / `capacityLimit`）均可在调用前调整**。**`initialCapacity` 选值依据（v0.18.11 修订）**：调用级**不预分配**（`hwBase/hwTop` 仅为记账区间，无额度预留）——本值的作用是**扩容触发点**、只影响扩容粒度：调小 → 触发更频繁（每次触发含宿主侧同步/就地扩容开销）；调大 → 无正确性危害（仅触发更晚）。**默认 128（2^7）**：常见单调用分配为**个位到十位数**（§6 每次至多登记 1 槽），128 留 4–10 倍余量并覆盖小循环（≤128 次迭代的循环分配不触发扩容）；比 1024 更贴近真实峰值（对可能的"预分配式"实现亦零浪费）；循环分配终将越过任何有限初值，由扩容兜底——扩容路径的深度测试可在测试/宿主侧**显式调小**复现（本值可调，§8.1）；与全局上限 2^20 相差 8192 倍；宿主可按实测负载在调用前调参。**新槽一律追加到句柄表表尾**（`hwBase/hwTop` 仅为本次调用的记账区间，用于 GC 根集合与重放清理）；句柄表全局上限触顶（默认 2^20 槽，可配置）→ `ERR_HANDLE_WINDOW_FULL(16)`。deopt 重放前桥重置 `hwTop=hwBase`，窗口内未逃逸的槽由宿主 GC 回收；**逃逸槽（§8.1）占用的表项不参与任何后续分配重用**。正常返回的句柄在窗口重置**前**按 §8.1 逃逸规则迁移。

> **16 的边界（推论）**：窗口在单次调用内**只增不减**（无栈映射 ⇒ 中途无法对已死槽做 liveness 回收，I8 的代价），故单次调用的分配总次数受全局上限约束——循环内海量分配触及上限时，16 在**执行中途**发生，调用结束后的清理（无论 try/finally）无法预防。因此 16 是**峰值容量错误**，不是泄漏：跨调用残留已被 §8.1 规则 6 与 call 的 try/finally 清零。容量预算恒等式：**上限 ≥ 常量基线 + 并发度 × 单调用活跃峰值**，缓解手段仅三个：
>
> 1. **调大全局上限**：`HandleTable.capacityLimit`（§8.1，默认 2^20 槽）——运行中调大**即时生效**；调小不追溯已占用槽；
> 2. **拆分超大调用**：把单次分配千万级的函数拆为多次调用，压低"单调用活跃峰值"；
> 3. **限制并发度**：宿主以信号量等手段控制同时执行的调用数，使 `并发度 × 单调用峰值` 不突破预算。
7. **并发**：ctx 随调用栈分配，各调用的句柄窗口 `[hwBase, hwTop)` 互不重叠，句柄表的槽追加由宿主侧同步保护，故 `JitFunction` 可在多线程并发调用（前提：常量表 `freeze` 后不可变）。完整调用契约与线程模型见 §8.3。
8. **不变量回归**：每个 M1 失败点（除零 / 越界 / 缺键 / 类型不符 / helper panic）都必须有对应测试用例，断言 `JitException.code` 与 `site` 两字段正确。
9. **32 位宿主不支持（冻结决策）**：`cell` 恒 64 位、`ctx` 恒 64 字节是整套设计的硬前提，因此 M1 **不为任何 32 位宿主（Windows x86 / Linux i686 / armv7 / …）提供支持路径**——不构建 32 位产物、不做指针压缩、不做 32 位兼容层、不引入"宽 cell"分支。表现为**构建期/装载期失败**而非运行期降级：桥不产出 32 位库；宿主若手工加载，装载向导必须以明确错误拒绝，不得尝试解释执行。
10. **JIT 仅 Linux（冻结决策）**：机器码只在 **Linux** 上产生、且**指令集支持范围跟随仓颉 SDK for Linux**（当前 x86_64 / aarch64；SDK 扩大指令集支持范围时，本实现**随之扩大**——按既有范围变更流程执行〔§13 原则 4 + §13.2 重跑〕，属预期演进、不改变语义）；其余平台即使 `jit = Force` 也**静默降级为解释器**（只记 `diagnostics`，不报错、不改语义、不改返回类型）。由此推出硬约束：**字节码中不得出现任何"仅 JIT 可实现"的指令**（`.fbc` 的 `flags.bit1` 恒 0）。当某项优化只有 JIT 做得到时，唯一允许的表现是"解释器跑得慢一些"，绝不允许表现为"该函数只有 JIT 能跑"或"非 Linux 上语义不同"。

11. **编译粒度为整单元（冻结决策）**：`compile()` 一次性处理 `SourceUnit` 内**全部函数**；不存在"单函数增量编译"。`CALL_FUNC` 只允许指向**同一 `.fbc` 单元内**的函数，目标经 §11.7 函数目录解析——相互递归因此天然支持，不依赖编译顺序。把粒度改为增量/跨单元编译属 M2 议题，且不得破坏本条与 §11.7 的一致性。
12. **Decimal = 仓颉标准库 `std.math.numeric.Decimal`（不自定义类型，冻结）**：任意精度有符号十进制数，默认精度 0（无限精度）；**可能产生无限小数的运算（除法等）默认采用 std 的 IEEE 754-2019 decimal128 舍入（HalfEven）**。M1 固定使用 std 默认上下文，不自定义精度/舍入（不使用 `divWithPrecision` 等自定义精度 API）——确定性由 std 的实现保证。构造（含 `parse`）、四则、比较语义全部以 std 为准；÷0（含 0÷0）→ 10；`DEC_TO_I64` 经 `OverflowStrategy` 转换，越界 → 9；比较恒精确（`CMP_DEC` 不变）。
13. **插值串是前端糖（冻结）**：`"a${x}b"` → 各片段 `TO_STR`（静态类型标签）+ `STR_CAT` 左结合链；片段类型不在 §6 标签集 → 编译错误。分配型指令在 deopt 重放时会**重新分配等值对象**（I8），允许；T10 覆盖。**适用形态（v0.14，对齐仓颉）**：单行与多行（非原始）字符串；**原始串中 `${` 为字面文本**；`>|` 标记与前导缩进同样不参与插值（§8.8）。**v0.18.15**：混合 String 加法（`s + x` / `x + s`，§11.9）与插值共用同一 `TO_STR` 机制与同一类型边界（可文本化类型 = §6 标签集；非标签类型 → 编译错误）。
14. **宿主为仓颉运行时，句柄槽取 ID 形态（冻结决策 ④）**：句柄槽实现为 `idx:u32 + tag:u16 + gen:u16`（§1）——对象表由桥以 Cangjie 托管容器持有（条目为 GC 强引用，对象存活与搬移由仓颉 GC 处理），机器码永不接触裸指针。依据：仓颉 GC 为 region 式搬移收集，对象地址不稳定，`objref`（裸指针槽）不可实现。`gen` 语义按 §8.1（逃逸期间表项不得重用、世代保持；复用时递增），M1 常规路径（窗口只增不减）不依赖世代校验。变更宿主或句柄槽形态属范围变更。
15. **变更型 helper 与重放安全（冻结，v0.5；v0.8 纳入预定义 helper；v0.10 纳入 CALL_CLOSURE）**：H43–H48（List add/insert/set/remove、Map 写键/删键）、**预定义 helper（user helper，§8.4——宿主闭包，副作用黑盒）**及 **`CALL_CLOSURE` 闭包调用（§8.6——被调闭包体静态不可知，黑盒）**保守按变更型处理，是 M1 **唯一许可的容器副作用**来源，三条硬规则：① **常量禁写**——目标容器槽属路径 A（常量，跨调用共享）→ `ERR_READONLY(20)`；写入会造成跨调用可见的状态残留，破坏可重复调用；② **deopt 禁令**——含变更型 helper 的函数**禁止全部 deopt 源**（汇编期校验，§7 校验 11）：deopt 重放会重复执行变更（add 两遍、remove 两遍），因此此类函数必须保证重放不可达；前端改用报错模式语义等价；③ **防御兜底**——`FuncEntry.flags.bit0`（§11.7）标记"含变更型调用"，运行期若桥仍收到该类函数的 `errCode=-1`，**不重放**、按 99 上报（实现缺陷）。I7 不受影响：三引擎共用同一 helper 代码，对同一输入的变更序列逐位一致；可重复调用性以"输入对象状态相同"为前提（变更后即不同输入）。

> 变更上述冻结决策（例如新增 macOS JIT、支持 32 位宿主、或改为增量编译）属于**范围变更**：需同步更新受影响章节（§8 / §11 / §12 / §13.1）并重跑 §13.2 全量测试，且不得违反 I6 / I7。

---

## §10 附录：opcode 常量表

### §10.1 命名与编码约定

- 常量名规则：`OP_<助记符>`（大写下划线），例如 `OP_PUSH_I8`、`OP_CALL_HELPER`。
- 指令编码：`[op:u8][operands…]` 小端；`rel` 为相对**下一条指令**的有符号 32 位偏移。
- 保留区（RSVD：表中未分配槽 + 0xC0–FF——后者为 M2 规划预留区〔HW_OPEN 区块内批量分配、CALL_HOST〕，见 §5）在 M1 中发射即 `ERR_NOT_IMPL`；禁用区（FORBID：0xA9–AA——时间**构造**，M2 启用）同样发射即报错。v0.5 起 A1/A3/AB–AF（容器变更/快照）、v0.6 起 0xB8–BB（字符串切片替换/正则）、v0.15 起 0xBC–BD（字符串重复/日期差）、v0.16.1 起 0xBE（Map 迭代步进）、v0.17 起 0xBF（字符串建 Regex）、v0.18 起 A0/A2（空容器构造）已启用，归入 BOX。
- 实现侧应构建 `OPCODE_TABLE: Array<OpInfo>` 并以 opcode 为下标索引，供反汇编、汇编期校验、调试器共用。

### §10.2 操作数编码种类（OperandFormat）

| 记法 | 长度 | 含义 |
|---|---|---|
| `-` | 0 | 无操作数 |
| `u8` / `i8` | 1 | 无符号 / 有符号 8 位 |
| `u16` | 2 | 无符号 16 位（局部索引、常量索引、helper id、类型 token） |
| `i32` | 4 | 有符号 32 位（site 值、立即数） |
| `rel32` | 4 | 相对偏移（跳转目标） |
| `i64` | 8 | 64 位立即数（整数值或 Float64 位模式） |
| `u16 u8` | 3 | 双操作数（如 helper id + argc） |

### §10.3 opcode 常量表（Cangjie 骨架，可直接作为实现起点）

**全量 256 项显式列出**（`table[i].code == i`）；未分配槽统一 `OP_RSVD`（CAT_RSVD）——M1 发射即 `ERR_NOT_IMPL`。

```cangjie
// 类别
public const CAT_MISC:   UInt8 = 0   // 控制/杂项
public const CAT_CONST:  UInt8 = 1   // 常量/栈
public const CAT_LOCAL:  UInt8 = 2   // 局部变量
public const CAT_I64:    UInt8 = 3   // 整型算术
public const CAT_F64:    UInt8 = 4   // 浮点算术
public const CAT_CMP:    UInt8 = 5   // 比较/逻辑/位
public const CAT_CTRL:   UInt8 = 6   // 控制流
public const CAT_CALL:   UInt8 = 7   // 调用
public const CAT_TYPE:   UInt8 = 8   // 类型/转换/错误
public const CAT_BOX:    UInt8 = 9   // 容器/值运算/转换（helper 路由，含分配型）
public const CAT_FORBID: UInt8 = 10  // 禁用（容器/时间构造，M2 启用）
public const CAT_RSVD:   UInt8 = 11  // 保留

public struct OpInfo {
    public let code: UInt8
    public let name: String
    public let fmt: String        // 操作数编码，见 §10.2
    public let len: Int64         // 指令总长（1 + 操作数字节）；M1 全部指令定长
    public let cat: UInt8
    public const init(code: UInt8, name: String, fmt: String, len: Int64, cat: UInt8) { ... }
}

public let OPCODE_TABLE: Array<OpInfo> = [
  // ---- 0x00–0x0F 控制/杂项 ----
  OpInfo(0x00, "OP_NOP",          "-",   1, CAT_MISC),
  OpInfo(0x01, "OP_TRAP",         "u8",  2, CAT_MISC),
  OpInfo(0x02, "OP_BREAKPOINT",   "-",   1, CAT_MISC),
  OpInfo(0x03, "OP_SET_SITE",     "i32", 5, CAT_MISC),
  OpInfo(0x04, "OP_CHECK_ERR",    "rel32", 5, CAT_MISC),
  OpInfo(0x05, "OP_BAIL",         "i8",  2, CAT_MISC),
  OpInfo(0x06, "OP_CHECK_ERR_NC", "-",   1, CAT_MISC),
  OpInfo(0x07, "OP_STACK_GUARD",  "u16", 3, CAT_MISC),
  // ---- 0x08–0x0F 未分配（RSVD）----
  OpInfo(0x08, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x09, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x0A, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x0B, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x0C, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x0D, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x0E, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x0F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0x10–0x1F 常量/栈 ----
  OpInfo(0x10, "OP_PUSH_I8",  "i8",  2, CAT_CONST),
  OpInfo(0x11, "OP_PUSH_I32", "i32", 5, CAT_CONST),
  OpInfo(0x12, "OP_PUSH_I64", "i64", 9, CAT_CONST),
  OpInfo(0x13, "OP_PUSH_F64", "i64", 9, CAT_CONST),
  OpInfo(0x14, "OP_PUSH_BOOL","u8",  2, CAT_CONST),
  OpInfo(0x15, "OP_PUSH_NULL","-",   1, CAT_CONST),
  OpInfo(0x16, "OP_PUSH_KH",  "u16", 3, CAT_CONST),
  OpInfo(0x17, "OP_DUP",      "-",   1, CAT_CONST),
  OpInfo(0x18, "OP_DUP2",     "-",   1, CAT_CONST),
  OpInfo(0x19, "OP_POP",      "-",   1, CAT_CONST),
  OpInfo(0x1A, "OP_POP2",     "-",   1, CAT_CONST),
  OpInfo(0x1B, "OP_SWAP",     "-",   1, CAT_CONST),
  OpInfo(0x1C, "OP_PICK",     "u8",  2, CAT_CONST),
  // ---- 0x1D–0x1F 未分配（RSVD）----
  OpInfo(0x1D, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x1E, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x1F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0x20–0x2F 局部变量 ----
  OpInfo(0x20, "OP_LOADL",  "u16", 3, CAT_LOCAL),
  OpInfo(0x21, "OP_STOREL", "u16", 3, CAT_LOCAL),
  OpInfo(0x22, "OP_LOADL0", "-",   1, CAT_LOCAL),
  OpInfo(0x23, "OP_LOADL1", "-",   1, CAT_LOCAL),
  OpInfo(0x24, "OP_LOADL2", "-",   1, CAT_LOCAL),
  OpInfo(0x25, "OP_LOADL3", "-",   1, CAT_LOCAL),
  OpInfo(0x26, "OP_LOAD_CAP", "u16", 3, CAT_LOCAL),
  // ---- 0x27–0x2F 未分配（RSVD）----
  OpInfo(0x27, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x28, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x29, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x2A, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x2B, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x2C, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x2D, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x2E, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x2F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0x30–0x3F 整型算术 ----
  OpInfo(0x30, "OP_IADD",      "-", 1, CAT_I64),
  OpInfo(0x31, "OP_ISUB",      "-", 1, CAT_I64),
  OpInfo(0x32, "OP_IMUL",      "-", 1, CAT_I64),
  OpInfo(0x33, "OP_IDIV",      "-", 1, CAT_I64),
  OpInfo(0x34, "OP_IMOD",      "-", 1, CAT_I64),
  OpInfo(0x35, "OP_INEG",      "-", 1, CAT_I64),
  OpInfo(0x36, "OP_IABS",      "-", 1, CAT_I64),
  OpInfo(0x37, "OP_IMIN",      "-", 1, CAT_I64),
  OpInfo(0x38, "OP_IMAX",      "-", 1, CAT_I64),
  OpInfo(0x39, "OP_IADD_WRAP", "-", 1, CAT_I64),
  OpInfo(0x3A, "OP_ICLZ",      "-", 1, CAT_I64),
  OpInfo(0x3B, "OP_IPOPCNT",   "-", 1, CAT_I64),
  // ---- 0x3C–0x3F 未分配（RSVD）----
  OpInfo(0x3C, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x3D, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x3E, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x3F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0x40–0x4F 浮点运算 ----
  OpInfo(0x40, "OP_FADD",     "-", 1, CAT_F64),
  OpInfo(0x41, "OP_FSUB",     "-", 1, CAT_F64),
  OpInfo(0x42, "OP_FMUL",     "-", 1, CAT_F64),
  OpInfo(0x43, "OP_FDIV",     "-", 1, CAT_F64),
  OpInfo(0x44, "OP_FDIV_CHK", "-", 1, CAT_F64),
  OpInfo(0x45, "OP_FNEG",     "-", 1, CAT_F64),
  OpInfo(0x46, "OP_FABS",     "-", 1, CAT_F64),
  OpInfo(0x47, "OP_FMIN",     "-", 1, CAT_F64),
  OpInfo(0x48, "OP_FMAX",     "-", 1, CAT_F64),
  OpInfo(0x49, "OP_FSQRT",    "-", 1, CAT_F64),
  OpInfo(0x4A, "OP_FFLOOR",   "-", 1, CAT_F64),
  OpInfo(0x4B, "OP_FCEIL",    "-", 1, CAT_F64),
  OpInfo(0x4C, "OP_FTRUNC",   "-", 1, CAT_F64),
  OpInfo(0x4D, "OP_FROUND",   "-", 1, CAT_F64),
  // ---- 0x4E–0x4F 未分配（RSVD）----
  OpInfo(0x4E, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x4F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0x50–0x6F 比较/逻辑/位 ----
  OpInfo(0x50, "OP_CMP_I",  "-", 1, CAT_CMP),
  OpInfo(0x51, "OP_CMP_F",  "-", 1, CAT_CMP),
  OpInfo(0x52, "OP_EQ_I",   "-", 1, CAT_CMP),
  OpInfo(0x53, "OP_NE_I",   "-", 1, CAT_CMP),
  OpInfo(0x54, "OP_LT_I",   "-", 1, CAT_CMP),
  OpInfo(0x55, "OP_LE_I",   "-", 1, CAT_CMP),
  OpInfo(0x56, "OP_GT_I",   "-", 1, CAT_CMP),
  OpInfo(0x57, "OP_GE_I",   "-", 1, CAT_CMP),
  OpInfo(0x58, "OP_EQ_F",   "-", 1, CAT_CMP),
  OpInfo(0x59, "OP_NE_F",   "-", 1, CAT_CMP),
  OpInfo(0x5A, "OP_LT_F",   "-", 1, CAT_CMP),
  OpInfo(0x5B, "OP_LE_F",   "-", 1, CAT_CMP),
  OpInfo(0x5C, "OP_GT_F",   "-", 1, CAT_CMP),
  OpInfo(0x5D, "OP_GE_F",   "-", 1, CAT_CMP),
  OpInfo(0x5E, "OP_NOT_B",  "-", 1, CAT_CMP),
  OpInfo(0x5F, "OP_AND_B",  "-", 1, CAT_CMP),
  OpInfo(0x60, "OP_OR_B",   "-", 1, CAT_CMP),
  OpInfo(0x61, "OP_XOR_B",  "-", 1, CAT_CMP),
  OpInfo(0x62, "OP_BAND_I", "-", 1, CAT_CMP),
  OpInfo(0x63, "OP_BOR_I",  "-", 1, CAT_CMP),
  OpInfo(0x64, "OP_BXOR_I", "-", 1, CAT_CMP),
  OpInfo(0x65, "OP_BNOT_I", "-", 1, CAT_CMP),
  OpInfo(0x66, "OP_SHL_I",  "-", 1, CAT_CMP),
  OpInfo(0x67, "OP_SHR_I",  "-", 1, CAT_CMP),
  OpInfo(0x68, "OP_USHR_I", "-", 1, CAT_CMP),
  OpInfo(0x69, "OP_EQ_H",   "-", 1, CAT_CMP),
  OpInfo(0x6A, "OP_NE_H",   "-", 1, CAT_CMP),
  OpInfo(0x6B, "OP_CMP_STR", "-", 1, CAT_CMP),
  OpInfo(0x6C, "OP_CMP_DEC", "-", 1, CAT_CMP),
  OpInfo(0x6D, "OP_CMP_DT",  "-", 1, CAT_CMP),
  OpInfo(0x6E, "OP_CMP_DUR", "-", 1, CAT_CMP),
  // 0x6F 未分配（RSVD）
  OpInfo(0x6F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0x70–0x7F 控制流与调用 ----
  OpInfo(0x70, "OP_JMP",           "rel32", 5,    CAT_CTRL),
  OpInfo(0x71, "OP_JZ",            "rel32", 5,    CAT_CTRL),
  OpInfo(0x72, "OP_JNZ",           "rel32", 5,    CAT_CTRL),
  // 0x73 未分配（RSVD）
  OpInfo(0x73, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x74, "OP_LOOP_BACK",     "rel32", 5,    CAT_CTRL),
  OpInfo(0x75, "OP_CALL_HELPER",   "u16 u8", 4,   CAT_CALL),
  OpInfo(0x76, "OP_CALL_HELPER_NC","u16 u8", 4,   CAT_CALL),
  OpInfo(0x77, "OP_CALL_HELPER_V", "u16 u8", 4,   CAT_CALL),
  OpInfo(0x78, "OP_CALL_FUNC",     "u16 u8", 4,   CAT_CALL),
  OpInfo(0x79, "OP_CALL_HOST",     "u16 u8", 4,   CAT_CALL),
  OpInfo(0x7A, "OP_HW_OPEN",       "u16", 3,      CAT_CALL),
  OpInfo(0x7B, "OP_HW_CLOSE",      "-", 1,        CAT_CALL),
  OpInfo(0x7C, "OP_RET",           "-", 1,        CAT_CALL),
  OpInfo(0x7D, "OP_RET_VOID",      "-", 1,        CAT_CALL),
  OpInfo(0x7E, "OP_RET_NULL",      "-", 1,        CAT_CALL),
  OpInfo(0x7F, "OP_CALL_CLOSURE",  "u8", 2,       CAT_CALL),
  // ---- 0x80–0x8F 类型/转换/错误 ----
  OpInfo(0x80, "OP_CAST",       "u16 u8", 4, CAT_TYPE),
  OpInfo(0x81, "OP_TO_I64",     "u8", 2,     CAT_TYPE),
  OpInfo(0x82, "OP_TO_F64",     "-", 1,      CAT_TYPE),
  OpInfo(0x83, "OP_IS_TYPE",    "u16", 3,    CAT_TYPE),
  OpInfo(0x84, "OP_GUARD_TYPE", "u16 u8", 4, CAT_TYPE),
  OpInfo(0x85, "OP_THROW",      "u8", 2,     CAT_TYPE),
  OpInfo(0x86, "OP_ASSERT",     "u8", 2,     CAT_TYPE),
  OpInfo(0x87, "OP_ABORT",      "u8", 2,     CAT_TYPE),
  OpInfo(0x88, "OP_GUARD_NNZ",  "u8", 2,     CAT_TYPE),
  OpInfo(0x89, "OP_TYPE_OF",    "-", 1,      CAT_TYPE),
  // ---- 0x8A–0x8F 未分配（RSVD）----
  OpInfo(0x8A, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x8B, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x8C, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x8D, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x8E, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0x8F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0x90–0x9F 容器/值提取/数值转换 ----
  OpInfo(0x90, "OP_LEN",         "-", 1,    CAT_BOX),
  OpInfo(0x91, "OP_GET_IDX",     "-", 1,    CAT_BOX),
  OpInfo(0x92, "OP_GET_KEY",     "-", 1,    CAT_BOX),
  OpInfo(0x93, "OP_GET_KEY_OR",  "-", 1,    CAT_BOX),
  OpInfo(0x94, "OP_HAS_KEY",     "-", 1,    CAT_BOX),
  OpInfo(0x95, "OP_STR_AT",      "-", 1,    CAT_BOX),
  OpInfo(0x96, "OP_DT_FIELD",    "u8", 2,   CAT_BOX),
  OpInfo(0x97, "OP_DUR_TICKS",   "-", 1,    CAT_BOX),
  OpInfo(0x98, "OP_DEC_IS_INT",  "-", 1,    CAT_BOX),
  OpInfo(0x99, "OP_HANDLE_TAG",  "-", 1,    CAT_BOX),
  OpInfo(0x9A, "OP_RANGE_NEW",   "-", 1,    CAT_BOX),
  OpInfo(0x9B, "OP_RANGE_CONTAINS","-", 1,  CAT_BOX),
  OpInfo(0x9C, "OP_TO_DEC",      "u8", 2,   CAT_BOX),
  OpInfo(0x9D, "OP_DEC_TO_I64",  "u8", 2,   CAT_BOX),
  OpInfo(0x9E, "OP_DEC_TO_F64",  "-", 1,    CAT_BOX),
  // ---- 0x9F 未分配（RSVD）----
  OpInfo(0x9F, "OP_RSVD", "-", 1, CAT_RSVD),
  // ---- 0xA0–0xAF 分配/变更区（A9/AA 禁用；A0–A3、AB–AF 自 v0.5/v0.18 起启用）----
  OpInfo(0xA0, "OP_MAKE_LIST",   "-", 1, CAT_BOX),
  OpInfo(0xA1, "OP_LIST_APPEND", "-", 1, CAT_BOX),
  OpInfo(0xA2, "OP_MAKE_MAP",    "-", 1, CAT_BOX),
  OpInfo(0xA3, "OP_MAP_PUT",     "-", 1, CAT_BOX),
  OpInfo(0xA4, "OP_STR_CAT",     "-", 1, CAT_BOX),
  OpInfo(0xA5, "OP_DEC_ADD",     "-", 1, CAT_BOX),
  OpInfo(0xA6, "OP_DEC_SUB",     "-", 1, CAT_BOX),
  OpInfo(0xA7, "OP_DEC_MUL",     "-", 1, CAT_BOX),
  OpInfo(0xA8, "OP_DEC_DIV",     "-", 1, CAT_BOX),
  OpInfo(0xA9, "OP_DT_NEW",      "-", 1, CAT_FORBID),
  OpInfo(0xAA, "OP_DUR_NEW",     "-", 1, CAT_FORBID),
  OpInfo(0xAB, "OP_LIST_INSERT", "-", 1, CAT_BOX),
  OpInfo(0xAC, "OP_LIST_SET",    "-", 1, CAT_BOX),
  OpInfo(0xAD, "OP_LIST_REMOVE", "-", 1, CAT_BOX),
  OpInfo(0xAE, "OP_MAP_REMOVE",  "-", 1, CAT_BOX),
  OpInfo(0xAF, "OP_MAP_ITER_BEGIN", "-", 1, CAT_BOX),
  // ---- 0xB0–0xB7 时间运算/文本化（v0.4）----
  OpInfo(0xB0, "OP_DT_ADD",      "-", 1, CAT_BOX),
  OpInfo(0xB1, "OP_DT_SUB",      "-", 1, CAT_BOX),
  OpInfo(0xB2, "OP_DUR_ADD",     "-", 1, CAT_BOX),
  OpInfo(0xB3, "OP_DUR_SUB",     "-", 1, CAT_BOX),
  OpInfo(0xB4, "OP_DUR_MUL",     "-", 1, CAT_BOX),
  OpInfo(0xB5, "OP_DUR_DIV",     "-", 1, CAT_BOX),
  OpInfo(0xB6, "OP_DUR_NEG",     "-", 1, CAT_BOX),
  OpInfo(0xB7, "OP_TO_STR",      "u8", 2, CAT_BOX),
  // ---- 0xB8–0xBB 字符串切片替换/正则（v0.6）----
  OpInfo(0xB8, "OP_STR_SUB",       "-", 1, CAT_BOX),
  OpInfo(0xB9, "OP_STR_REPLACE",   "-", 1, CAT_BOX),
  OpInfo(0xBA, "OP_REGEX_IS_MATCH","-", 1, CAT_BOX),
  OpInfo(0xBB, "OP_REGEX_FIND",    "-", 1, CAT_BOX),
  OpInfo(0xBC, "OP_STR_REPEAT",  "-", 1, CAT_BOX),
  OpInfo(0xBD, "OP_DT_DIFF",     "-", 1, CAT_BOX),
  OpInfo(0xBE, "OP_MAP_ITER_STEP",  "u8", 2, CAT_BOX),
  OpInfo(0xBF, "OP_STR_TO_REGEX", "-", 1, CAT_BOX),
  // ---- 0xC0–0xFF 保留（预留 M2：HW_OPEN 区块内批量分配、CALL_HOST；M1 发射即 ERR_NOT_IMPL，§5）----
  OpInfo(0xC0, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC1, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC2, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC3, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC4, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC5, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC6, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC7, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC8, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xC9, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xCA, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xCB, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xCC, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xCD, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xCE, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xCF, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD0, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD1, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD2, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD3, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD4, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD5, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD6, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD7, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD8, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xD9, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xDA, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xDB, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xDC, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xDD, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xDE, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xDF, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE0, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE1, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE2, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE3, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE4, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE5, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE6, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE7, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE8, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xE9, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xEA, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xEB, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xEC, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xED, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xEE, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xEF, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF0, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF1, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF2, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF3, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF4, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF5, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF6, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF7, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF8, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xF9, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xFA, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xFB, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xFC, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xFD, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xFE, "OP_RSVD", "-", 1, CAT_RSVD),
  OpInfo(0xFF, "OP_RSVD", "-", 1, CAT_RSVD),
]
```

**表构建时的一致性校验（建议放在 `OpcodeTable.build()` 的调试断言里）**：

1. 数组长度 == 256，且 `table[i].code == i`（0x00–0xFF **全量显式列出**；未分配槽统一为 `OP_RSVD`（CAT_RSVD））。
2. `len != 0` 时，`len == 1 + Σ operandSize(fmt)`。
3. `CAT_FORBID` 与 `CAT_RSVD` 类别的项，以及 M2 专属的 `OP_CALL_HOST/OP_HW_OPEN/OP_HW_CLOSE`，汇编器 `emit` 一律拒绝并报 `ERR_NOT_IMPL`。
4. `CAT_CALL` 中 `OP_CALL_HELPER` 之后必须能查到 `OP_CHECK_ERR`（见 §7 校验 1）。

---

## §11 跨平台字节码规格（Windows / Linux / HarmonyOS / macOS）

字节码是**唯一分发产物**：一份 `.fbc` 在四个平台上必须以相同结果、相同错误码运行。JIT 只是 Linux 上的加速器，因此**任何平台差异都不允许进入字节码层**。

### §11.1 三条移植性原则

| # | 原则 |
|---|---|
| P1 | 字节码是规范（normative），解释器与 JIT 都必须符合它；机器码不是分发物 |
| P2 | 字节码内不含任何宿主信息：无指针、无路径、无 OS 调用号、无寄存器/ABI、无宿主类型宽度 |
| P3 | 结果逐位可复现：整数（checked）、浮点（NaN 规范化）、文本（UTF-8 码点序）、Decimal（精确十进制）、时间（**值**仅 UTC；DateTime **文本化**按宿主系统时区，§11.9——同环境逐位一致、跨环境可不同） |

### §11.2 编码与端序

- 字节码是**字节串，固定小端（LE）**：多字节操作数按 LE 写出/读出，**必须显式解码**；禁止 `memcpy`、指针强转、`memcpy` 式的结构体覆盖来解读字节码。这样同一份字节码在 BE 主机上也能被解释器正确执行（JIT 仅面向 LE 目标）。
- cell = 8 字节、8 字节对齐；`Float64` = IEEE754 binary64；`Int64` = 补码，溢出已检查，**不依赖机器 wrap 行为**。
- 指令自身无对齐要求，**全部指令定长**（v0.4 起无可变长指令）；解码逐字节读取。
- §10.3 的 `len` 是**平台无关**的字节长度，任何平台都算得相同。

### §11.3 浮点：NaN 规范化（跨平台一致的关键）

| 规则 | 内容 |
|---|---|
| 产生 | 一切产生 NaN 的运算（0/0、Inf-Inf、`FSQRT(负数)`、`FMIN/FMAX` 遇 NaN）一律产出 **canonical NaN = `0x7FF8_0000_0000_0000`** |
| 传播 | 输入 NaN 的 payload 不参与任何可观察语义；拼装期 `PUSH_F64` 常量必须已规范化（加载器校验，非 canonical → 拒绝） |
| 比较 | `EQ_F/NE_F/LT_F/LE_F/GT_F/GE_F` 严格按 IEEE 无序规则 → 与 payload 无关，可复现 |
| `CMP_F` | 遇 NaN 结果未定义，**汇编器禁止发射**（§9.1） |
| 超越函数 | `sin/cos/exp/log/pow` 等 **M1 不提供**；M2 若提供，必须软件实现或显式标记"平台相关"并在差分测试中豁免（不允许静默差异） |
| 有符号零 | `0.0` 与 `-0.0` 只影响 `FDIV` 结果符号，按 IEEE 保留，不做规范化 |

### §11.4 文本与时间

- 字符串 = **UTF-8（无 BOM）**；`hs_len` 返回 UTF-8 字节数；`STR_AT(i)` 的 `i` 按 **Unicode 码点**计数（越界 → `ERR_IDX_OOB`）。
- 非法 UTF-8 / 孤立代理项：拼装期拒绝；运行期不得产生。
- `CMP_STR` 只做**码点序比较**（等价于 UTF-8 字节序），不做 locale case-fold / 词典序 / 规范化，避免平台差异。
- 时间**值仅 UTC**：`DT_FIELD` 的 `hour/dayOfWeek/...` 一律按 UTC 计算；本地时区只在桥侧宿主 API 处理——**唯一呈现路径 = `TO_STR` 的 DateTime 本地化**（v0.18.16，§11.9）；字节码层不可见、不可读时区。
- Decimal = 仓颉标准库 `std.math.numeric.Decimal`（任意精度，不自定义类型）；序列化表示固定为 `(sign: u8, scale: Int32, coefficient: 十进制数字串)`（§11.5 kind 6，加载时经 std 无限精度构造）；比较为**精确十进制比较**（std 比较），不得经过浮点中间值；文本化 = `std.math.numeric.Decimal.toString()`（§11.9），跨平台一致性由 T11 保证。

### §11.5 常量表序列化（与句柄解耦）

```
ConstTable { version: u16, count: u32, entries: [Entry] }
Entry = (kind: u8, payload)
  kind 1 = Int64         payload: i64
  kind 2 = Float64       payload: 8B（必须为 canonical 位模式，加载器校验）
  kind 3 = String        payload: u32 字节长 + UTF-8 字节
  kind 4 = List          payload: u32 元素数 + u32[常量表索引]
  kind 5 = Map           payload: u32 键值对数 + u32[键索引, 值索引]
  kind 6 = Decimal       payload: u8 sign + i32 scale + u32 长度 + 系数字节串（ASCII '0'–'9'，与 §11.4 表示一致）
  kind 7 = DateTime      payload: i64 = epochNanos（UTC）
  kind 8 = Duration      payload: i64 = nanos
  kind 9 = Range         payload: i64 start + i64 end + i64 step + u8 isClosed（1=左闭右闭 `..=`）
  kind 10 = Regex        payload: u8 flags(bit0=i bit1=m bit2=u——字面量 flags 顺序无关、重复幂等的归一形，§3.3) + u16 长度 + pattern UTF-8 字节串
```

- 序列化中**只有值，没有句柄 ID**：句柄 ID 是**加载时分配**的运行时索引，跨进程/跨平台都不稳定，禁止写入字节码。
- 常量表必须是 **DAG**（允许共享子结构，禁止环）；加载器做环检测。
- 每份 `.fbc` 附 `constFingerprint: u64`（FNV-1a）与 `crc32`，仅用于缓存键与诊断，**不参与语义**。

### §11.6 容器头 `.fbc`

```
off  size 字段        说明
0    4    magic       "FBC1"
4    2    verMajor    1
6    2    verMinor    11（递增原因＝新增 opcode / 新增 helper / 类型表格式变更 / CALL_HELPER hid 值域扩展；历史：v0.4=1、v0.5=2、v0.6=3、v0.7=4、v0.8=5、v0.10=6、v0.11=7、v0.15=8、v0.16=9、v0.17=10、v0.18=11；加载器接受 ≤ 自身版本的 verMinor）
8    4    flags       bit0=UTF-8 语义(恒 1)  bit1=需要 JIT(必须为 0)  bit2=使用值运算/分配/变更类指令（helper 路由：A0–A8 / 0x9A–0x9E / 0xAB–AF / 0xB0–0xBF 时置 1）
12   4    hdrSize     恒 32（v1；为向后兼容预留）
16   4    codeLen
20   4    constLen
24   4    siteLen     站点表（偏移 → 源位置）长度
28   4    entryFn     入口函数 id
32   4    crc32       code + const + site
36   ...  code / const / site 三段依次存放
```

- `flags.bit1`（需要 JIT）**必须恒为 0**（冻结决策，§9 附则 10）：字节码不得要求 JIT 存在。某优化只有 JIT 能做时，唯一允许的表现是"解释器跑得慢"。`flags.bit2`（值运算/分配/变更类指令）自 v0.4 启用（v0.5 纳入 A1/A3/AB–AF；v0.6 纳入 0xB8–BB）：置 1 时加载器按需预扩句柄表；置 0 的单元出现此类指令 → 加载期拒绝（与汇编器校验双保险）。
- 未知 `flags` 位或更高 `verMajor` → 加载期拒绝（桥抛 `JitException(code=18, ERR_NOT_IMPL 语义)`）。
- 站点表（site table）是**平台无关的偏移到源位置映射**，三引擎的错误报告都从这里取源位置。

### §11.7 代码段与函数目录（`CALL_FUNC` 依赖）

code 段头部是**函数目录**，其后是各函数体依次紧排：

```
FuncDir   { count: u32, funcs: [FuncEntry] }
FuncEntry = { fnId: u32, codeOff: u32, codeLen: u32, localTypesOff: u32,
              nargs: u16, nLocals: u16, maxStack: u16, retType: u16, flags: u16 }   // 恒 26 B
```

- `codeOff/codeLen/localTypesOff` 相对 code 段起点；`frameSize` 由 §3.1 公式在加载期算出（平台无关）。
- `flags.bit0` = 函数含变更型 helper、预定义 helper（user helper，§8.4）或 CALL_CLOSURE（§8.6）调用（v0.5，汇编器设置；v0.8/v0.10 扩展）：桥的防御性 DEOPT 检查依据（§9.15③）。
- `retType`（v0.7）：返回类型，LocalType 编码，合法值 0–12（**9=Regex 自 v0.17 合法**——可经 `call<T>` 双向，§3.3；12=闭包仅限 CALL_FUNC 链内返回，不可经 call<T> 逃逸，§8.6）。源入口 = lambda 尾表达式静态推导（§8.0）；分发入口场景 `call<T>` 的 `T` 校验依据（§8.2 第 5 步）。加载器校验其合法性。

**局部类型表（v0.4 起，每个函数一份，`localTypesOff` 指向，共 `nLocals` 字节）**：

```
LocalType (u8，每槽 1 字节):
  0=Int64   1=Float64  2=Bool     3=Unit
  4=String  5=Decimal  6=DateTime 7=Duration 8=Range
  9=Regex（v0.17 起可作参数/返回，§3.3）
  10=List  11=Map（v0.7 参数槽；**v0.18 起全槽位合法**（可声明为局部）；元素类型为前端/桥的静态知识，类型表不编码泛型实参）
  12=Closure（v0.10，§8.6；闭包句柄，签名是前端/桥的静态知识）
  13–255 保留（加载器拒绝）
```

- 值型（0–3）槽存原始 cell；句柄型（4–12；10=List、11=Map 自 v0.18 全槽位）槽存句柄 ID（0=null），且与 §6 类型 token 一一对应：String↔3、Decimal↔4、DateTime↔5、Duration↔6、Range↔7、Regex↔8、Closure↔9、List↔1、Map↔2（供 `IS_TYPE/GUARD_TYPE/H19` 使用）。
- 类型表覆盖**全部 nLocals 槽**，含参数槽 `locals[0..nargs-1]`（其类型应与函数签名一致——前端责任）。
- **明确赋值与空安全（v0.4 修订）**：局部**没有默认值**——非参数局部必须先 `STOREL` 后读取（汇编期数据流校验，§7 校验 10；读未赋值 = 编译错误）；**没有空值**——句柄型局部（4–9、12，参数槽 10–11）恒为有效句柄（≠0），`PUSH_NULL` 不得直存（§3.1 空安全）。参数槽 `locals[0..nargs-1]` 由调用方赋值，天然满足；参数句柄为 0（桥边界互操作值）时在 helper 边界报 6。内存卫生填充（§3.1）不可观察。
- **规范地位**：M1 中类型表是规范性元数据——加载器校验其结构（`localTypesOff` 落在 code 段内、恰 `nLocals` 字节、类型值合法、纳入 `crc32`）；**运行期不做栈类型跟踪**（无字节码校验器，M2 议题）。句柄型局部装入错误类型的句柄时，在 helper fetch 边界暴露为 6/8（§6 fetch 约定）。
- **可声明的局部类型集**：`Int64 / Float64 / Bool / Unit / String / Decimal / DateTime / Duration / Range / Regex / Closure / List / Map`（v0.6；Closure 自 v0.10；**List/Map 自 v0.18**——原「仅参数槽」限制解除：容器可声明为局部，元素类型为前端静态知识，同参数槽）。
- `CALL_FUNC fid` 经目录解析目标（支持相互递归，不依赖编译顺序）；`fid` 不存在或 `argc != nargs` → 编译错误 / 运行期 `ERR_ARG_MISMATCH`。
- 编译粒度是**整单元**（§9 附则 11）：单元内函数一次编译、目录与类型表整体生成；不存在单函数增量编译。
- 容器头 `entryFn` 必须命中目录中某个 `fnId`，否则加载期拒绝。
- 目录、局部类型表与函数体一并纳入 `crc32` 覆盖范围。

### §11.8 跨平台禁止清单

| 禁止 | 原因 |
|---|---|
| 字节码内出现主机地址 / 宿主句柄 / 文件路径 | 换平台即失效 |
| 依赖宿主 `Long`/`Double` 宽度（非 64 位） | cell 恒 64 位；**32 位宿主不支持**（冻结决策，§9 附则 9） |
| 依赖 wrap 溢出、移位越界、NaN payload、有符号零打印 | 已由 §11.2/§11.3/§11.9 固定或禁入 |
| `CALL_HOST`（M2）引用未在各平台注册的回调 | 各平台注册集不同 → 加载期校验为 `ERR_NOT_IMPL` |
| 机器码持久化 / 跨机共享 / 写入 `.fbc` | 后端与 ABI 相关 |
| 字节码中出现"仅 JIT 可实现"的指令 | 违反 I6 / P1；`flags.bit1` 恒 0（冻结决策，§9 附则 10） |
| 按平台分叉行为（错误码不同、某平台被拒） | 冻结决策：JIT 仅 Linux（指令集跟随仓颉 SDK for Linux、当前 x86_64 / aarch64），其余平台解释执行且**语义、可用性完全相同**（§9 附则 10） |
| TO_STR（**DateTime 的时区呈现除外**——语义 = 宿主系统时区，§11.9）/ 插值 / 混合 String 加法 / 数值转换依赖平台 locale 或宿主格式化库 | 违反 P3；除 DateTime 时区外，全部格式已由 §11.9 冻结，实现必须内嵌同一算法 |
| 分发装载含 user helper hid（[0x0100,0xFFFF]）的 `.fbc` | 预定义函数是编译器实例的宿主侧资产，不进 `.fbc`（§8.4）；加载期拒绝（JitException(18) 语义） |

### §11.9 数值互转与文本化格式（v0.4，全部冻结）

**互转矩阵**（"默认转换"由前端自动插入以下显式指令实现；字节码层无隐式行为，I6）：

| 转换 | 指令 | 规则 |
|---|---|---|
| I64→F64 | `TO_F64` | IEEE 最近偶数 |
| F64→I64 | `TO_I64` | mode 定报错/DEOPT；NaN/越界 → 13 |
| I64→DEC | `TO_DEC` src=0 | 精确，scale=0 |
| F64→DEC | `TO_DEC` src=1 | **最短往返**十进制表示（Ryu 算法族）；NaN/±Inf → 13 |
| DEC→I64 | `DEC_TO_I64` | 向零截断；越界 → 9 |
| DEC→F64 | `DEC_TO_F64` | IEEE 最近偶数；溢出 → ±Inf（不报错） |

> F64→DEC→F64 复合可能不还原原位型（最短往返 ≠ 精确二进制值）；这是冻结语义，不是缺陷。前端对 F64→DEC 的"默认转换"应谨慎（建议仅显式使用）。

**字面值类型规则（冻结）**：源码中的**小数字面值**——含小数点或指数的十进制字面值（如 `1.25`、`0.1`、`3e2`、`1e-3`）——**自动编译为 Decimal**：拼装期按字面文本精确构造（sign / scale / 系数直接来自字面值，§11.5 kind 6；`3e2` → scale=-3、`1e-3` → scale=3），**不经 Float64**，从根上避免二进制表示误差进入计算。**整数字面值**：Int64 范围内 → `Int64`；**超出 Int64 范围 → Decimal**（scale=0，精确构造，std `parse` 语义）——字面值不因溢出报错，类型自动升级；Decimal 为**任意精度**，不存在"过大整数"字面值（仅标度溢出经 std `OverflowException` → 拼装期编译错误）。`Float64` 值的来源仅限：显式标注的字面值（如 `1.5f64`，语法形式由前端定义）、`TO_F64` / `DEC_TO_F64` 转换、浮点运算结果、桥参数。由此，常见十进制算术（`1.5 * 2`、超大整数等）天然落在精确 Decimal 域（经 §11.9 提升规则），仅显式 Float64 值才进入二进制浮点域。

**混合类型四则与比较（提升规则，前端实现"默认"行为；字节码层仍只有显式指令，I6）**：

提升格（窄 → 宽）：`Int64 → Float64`（`TO_F64`）、`Int64 → Decimal`（`TO_DEC` src=0）、`Float64 → Decimal`（`TO_DEC` src=1，最短往返）。宽度序：**Decimal > Float64 > Int64**。

| 混合操作 | 前端降低为 | 结果/比较域 |
|---|---|---|
| `I64 op F64`（含反序） | 窄侧 `TO_F64` + F64 运算/比较 | F64 |
| `I64 op DEC`（含反序） | 窄侧 `TO_DEC`(src=0) + DEC 运算/比较 | DEC |
| `F64 op DEC`（含反序） | F64 侧 `TO_DEC`(src=1) + DEC 运算/比较 | DEC |

- `op` 覆盖 `+ − × ÷` 与全部比较（`EQ/NE/LT/LE/GT/GE`；DEC 域经 `CMP_DEC`）。
- 精度语义（冻结）：`I64→F64` 在 |v| ≥ 2^53 时按 IEEE 最近偶数舍入，比较结果由此唯一定义；`F64→DEC` 按最短往返（故 `0.1f64 == Decimal("0.1")` 为真）。除零沿用目标域规则（DEC → 10；F64 → ±Inf 不报错）。

**隐式与显式转换（冻结）**：

| 形式 | 方向 | 语义 |
|---|---|---|
| 隐式（提升） | **仅宽化**：I64→F64、I64→DEC、F64→DEC | 前端按上方提升规则自动插入，仅在混合运算/比较需要时 |
| 显式（源语言转换表达式，形式由前端定义，如 `x as Int64`） | **全部 6 个方向** | 编译为对应互转指令；**窄化方向（F64→I64、DEC→I64、DEC→F64）仅经显式形式可达** |

- 显式转换的失败语义由用户按指令形态选择：报错版（`TO_I64` mode=0 → 13；`DEC_TO_I64` mode=0 → 9）或 deopt 版（mode=1）；无失败方向（`TO_F64`、`DEC_TO_F64`）无此选择。
- **作用域限定**：显式机制仅覆盖数值三类型（Int64/Float64/Decimal）；Bool/Unit/Duration/DateTime/String/Range/Regex/Closure 的"禁止与任何类型互转"规则**同样适用于显式形式**——不存在、也不得添加其转换指令（转换面封闭）。

**量纲约定**：`(Duration, Duration)` 只定义 `DUR_ADD/DUR_SUB` 与 `CMP_DUR`；`×/÷` 只对 `(Duration, Int64)` 定义（`DUR_MUL/DUR_DIV`）。`(DateTime, Duration)` 只定义 `DT_ADD/DT_SUB`（负 Duration 即减）。**v0.15 扩展**：`(String, Int64)` 只定义 `×`（重复，`STR_REPEAT`）；`(DateTime, DateTime)` 只定义 `−`（差 → Duration，`DT_DIFF`——自 M2 提前纳入）。**v0.18.15 扩展**：`(String, T)` 与 `(T, String)`（T = 任一**可文本化类型**，即 TO_STR 标签集 t∈0–8）新增 `+`（非 String 侧经 `TO_STR` 转串后 `STR_CAT` 连接，见下条）；`− / ÷` 仍无定义（`(String, Int64)` 的 `×` 维持 v0.15）。

**重复、日期差与 n 的数值转换（v0.15 新增，冻结）**：

- **`s * n`（String 重复）**：结果 = `s` 重复 `n` 次的新 String。`n ≤ 0` → **空串**（不报错）；`n > 0`：结果字节数 = `n × len_utf8(s)` 以 Int64 计算——**乘法溢出 → 3**；宿主分配失败 → 99 兜底。反序 `n * s` 由**前端换序**（同 `DUR_MUL` 先例）。降低：`STR_REPEAT`（0xBC，H60，分配型）+ 自动 `CHECK_ERR`。
- **`dt1 − dt2`（日期差）**：结果 = `Duration`（**可为负**；两值相等 → 零 Duration）；差分超出 Duration 值域 → **12**。降低：`DT_DIFF`（0xBD，H61，分配型）。
- **n 位置的运行期数值转换（冻结）**：`s * n`、`d * n`、`d / n` 的 `n` 位置**接受 Int64/Float64/Decimal 任一数值类型**；**非 Int64 时前端自动插入运行期窄化转换**——F64 → `TO_I64`（mode=0：向零截断；NaN/越界 → 13）、DEC → `DEC_TO_I64`（mode=0：向零截断；越界 → 9）；字节码层仍只有显式指令（I6）。**该自动窄化仅限以上 n 位置**——一般表达式的窄化方向仍**仅经显式形式可达**（本节上文冻结表不变）；非数值类型出现在 n 位置 → 编译错误。

**String 双向混合加法（v0.18.15 新增，冻结）**：

- **规则**：`s + x` 与 `x + s`（`s` 为 String，`x` 为任一**可文本化类型**）定义为 String 连接——非 String 操作数先按下方 TO_STR 格式转串，再经 `STR_CAT` 连接；**结果恒为新 String**（不可变；两操作数均不被修改）。`x` 为 String 时退化为既有同型拼接（不插 `TO_STR`）。
- **可文本化类型 = TO_STR 标签集**（§6）：`Int64 / Float64 / Bool / String / Decimal / DateTime / Duration / Range / Regex`（t ∈ 0–8）；**Closure（§8.6 无文本形式）与 List / Map / Unit 等不在其内 → 编译错误**——与插值串片段同一类型边界（§9 附则 13）。
- **降低（前端糖；无新 opcode/helper、无格式变更）**：`s + x` → `[s, x, TO_STR(t_x), STR_CAT]`；`x + s` → `[x, TO_STR(t_x), s, STR_CAT]`。求值顺序保持源语言左→右；`x` 恰好求值一次（`TO_STR` 直接消费栈顶，无重复求值）。
- **分配与错误**：`TO_STR`（H33）与 `STR_CAT`（H32）均为分配型（各登记 1 槽、自动 `CHECK_ERR`）；错误面 = 两条指令既有集合（6/8/16），**无新错误码**；deopt 重放重建等值对象（I8，T10/T11 覆盖）。
- **与冻结转换面的关系**：本规则是**单向文本化（格式化输出）**，**不是类型转换**——"转换面封闭""显式机制仅数值三类型"（本节上文）与数值提升矩阵**均不变**；`− / × / ÷` 不因本规则扩展（String 的 `×` 仅维持 v0.15 的 `s * n` 重复）。

**TO_STR 格式（逐字节冻结；除 DateTime 本地化的时区项外跨环境一致；实现内嵌同一算法，禁止依赖平台 printf/locale）**：

| 值 | 格式 |
|---|---|
| Bool | `true` / `false` |
| Int64 | 十进制（负号 `-`） |
| Float64 | 最短往返表示；整数值附 `.0`（如 `1.0`）；`0.0`→`0.0`、`-0.0`→`-0.0`；`NaN` / `Infinity` / `-Infinity`；极大/极小按算法默认规则切科学计数 |
| Decimal | = `std.math.numeric.Decimal.toString()`：恒 plain 记法（无指数）、负数 `-` 开头（等价描述：`-` + 系数 + 按 scale 插小数点；scale 大于系数位数 → `0.0…` 前补零；负 scale → 整数尾补零） |
| DateTime | **本地时区呈现（v0.18.16）**：`YYYY-MM-DDTHH:MM:SS.nnnnnnnnn` + 偏移——偏移 ±00:00 输出 `Z`，否则 `±HH:MM`（如 `+08:00`）；按**宿主系统当前时区**折算（详见下注）；恒 9 位纳秒；值域（UTC）0001-01-01T00:00:00Z … 9999-12-31T23:59:59.999999999Z，即 errCode 11 的判定域 |
| Duration | = `std.core.Duration.toString()`（v0.18.17，对齐仓颉）：`[-]` + **非零分量串**——单位 `d/h/m/s/ms/us/ns` 自大到小、逐级整除分解；**零分量省略**（如 `1h2m3s4ms5us6ns`；`25h → 1d1h`）；**全零 → `0s`**；负值整体前置 `-`（取绝对值分解，如 `-1m30s`） |
| Range | `{start}..{end}` 或 `{start}..={end}`（按 isClosed）；`step ≠ 1` 时附加 ` : {step}`（空格风格与仓颉字面量一致） |
| Regex | `/` + pattern + `/` + flags（**输出按规范序 `i m u` 拼接**——规范化只作用于输出表示；源字面量 flags 顺序无关，§3.3；无标志时即 `/pattern/`） |
| String | 原样（插值语义，不加引号） |

Closure 无文本形式：`TO_STR` 标签 t=9 非法（前端对闭包 TO_STR → 编译错误，§8.6）。

**DateTime 本地化（v0.18.16，冻结）**：DateTime 值恒为 UTC 瞬时（`DT_FIELD`、比较、errCode 11 判定域均不变）；`TO_STR`（含插值、混合 `+`）**按宿主系统当前时区**折算为本地时间后输出——偏移 = 该时刻在该时区的**实际偏移**（含夏令时；取自宿主（仓颉标准库）本地时区设施，实现不得内嵌时区表副本）。**这是全表唯一的"环境相关"格式项**：同一值在不同系统时区可有不同文本；同机同时区逐位可复现；三引擎共用同一宿主时区（I7 不受影响），黄金测试须固定 TZ（T11）。折算越出四位年份的极限值（仅值域两端附近可发生）按 ISO 8601 扩展年份（前导 `+`）输出。

**区间语义（严格对齐仓颉 `Range<T>`，M1 仅 `Range<Int64>`）**：

- 字面量两形式（与仓颉一致）：`start..end : step`（左闭右开）、`start..=end : step`（左闭右闭）；省略 `: step` 时 step=1；**step ≠ 0**（=0 → 14；常量 step=0 由前端编译期拒绝）。
- 区间由四元组 `(start, end, step, isClosed)` 定义；**空区间合法**（不报错）：
  - `..`：`step>0 且 start ≥ end` → 空；`step<0 且 start ≤ end` → 空
  - `..=`：`step>0 且 start > end` → 空；`step<0 且 start < end` → 空
- step 可为负（`10..0 : -2` 遍历 10, 8, 6, 4, 2），方向由 step 符号决定。
- `RANGE_CONTAINS(h, v)`：按上述语义判定（`..=` 含 end；空区间恒 false）。
- 开端点区间（构造器 `hasStart/hasEnd=false` 形态）M1 不支持：字节码中的区间恒有双端点。
- `for-in` 循环经隐藏计数局部降低为 while 模式（§5 循环降低模式），支持 `Range` / `List` / `Map`（v0.5：Map 经 `MAP_KEYS`；**v0.16.1：`MAP_ITER_BEGIN`/`MAP_ITER_STEP` 惰性单遍迭代**）/ `String`（索引 + `STR_AT`）；切片 / 按区间索引 / 自定义迭代器协议属 M2。
- **迭代语义（v0.5 冻结，`for-in` 的规范降低；v0.16.1 更新 Map）**：① List——迭代开始快照长度 `n = LEN(h)`，逐索引 `GET_IDX`（迭代中越界 → 4）；② Map——**惰性单遍迭代（v0.16.1）**：`MAP_ITER_BEGIN` 建立宿主迭代器、逐轮 `MAP_ITER_STEP`（advance/key/value），出口 `close`——**无快照、无预遍历**（唯一一遍 = 循环本身）；**迭代期间修改同一 map → 错误码 23**（转码自 std `ConcurrentModificationException`——对齐仓颉；失败点 = 触发检测的 STEP 调用）；顺序 = std 迭代顺序；③ Range——整数循环，`i += step` 溢出 → 3；④ String——索引 + `STR_AT`。迭代中修改容器**语义明确**（List 为“长度快照 + 活值”；Map 为 fail-fast → **23**），**修改非同一容器的其它容器不受影响**；迭代器状态在宿主侧调用级表（随调用销毁；deopt 重放不携带旧游标）。变更型调用（`add` / `remove` / `[]=`——list 下标写与 map 写键）在循环体内许可（**Map 循环中修改自身 → 23**），同样受 §9.15 全部规则约束。源语言形式冻结为仓颉同形（§5）：`for (i in iterable) { … }`，Map 为 `for ((k, v) in map)`，可选 `where` 谓词。

**正则操作符（v0.11，冻结；v0.16.3 澄清 LHS 形态；v0.17 LHS 面扩展）**：LHS 恒为 Regex 类型（**任意 Regex 类型表达式**——字面量常量、Regex 局部变量或 `s.regex()` 构造结果，§3.3/§11.7）；RHS 为 String 类型表达式；类型不符 → 编译错误。

| 形式 | 语义 | 降低 |
|---|---|---|
| `re ~ s` | `s` 匹配 `re` → `true`（H52） | `REGEX_IS_MATCH` |
| `re !~ s` | `s` 不匹配 `re` → `true`（H52 + 取反） | `REGEX_IS_MATCH` + `NOT_B` |
| `re/s/r/g` | `s` 中**所有**匹配替换为 `r`（H58，分配型） | `REGEX_REPLACE_ALL` |
| `re/s/r`（省略 `g`） | 等价 `re/s/r/0`：仅替换第 0 个匹配（H59） | `REGEX_REPLACE_NTH` |
| `re/s/r/n` | 替换**第 n 个**匹配（n 为非负整数字面量，从 0 计；H59） | `REGEX_REPLACE_NTH` |

（表中 `re` 为 Regex 类型表达式**占位符**（变量或字面量），分隔 `/` 恒为单个——代入后按实际拼写：无 flags 字面量 = 其闭合 `/` 与分隔 `/` 相邻（`/\s//s/r/g`）；带 flags 字面量 = `/[a-z]/i/s/r/g`；变量 = `re/s/r/g`。详见下条「替换段词法」。）

- **优先级与结合性（冻结）**：正则操作符（`~`、`!~`、替换）构成独立层级——**高于加法级（`+ -`）、低于乘法级（`* / %`）**，**左结合**；`!~` 为单一词法 token（优先于一元 `!` 识别，避免 `!` + `~` 歧义）。
- **替换段词法（冻结；v0.16.3 澄清 `/` 个数，v0.16.4 示意记法修正）**：替换段由**单个 `/`** 开启（示意记法统一以单 `/` 书写：`re/s/r/g`——`re` 为 Regex 类型表达式**占位符**（变量/字面量皆可）；无 flags 字面量代入后其**闭合符**自然与**分隔符**相邻呈 `//`，并非分隔符翻倍），LHS 须为 Regex 类型表达式（正则字面量常量或 Regex 局部变量，§11.7；非 Regex 左操作数的 `/` 仍是除法——Regex 无除法运算，按类型无歧义）。开启符的书写形态随 LHS 而定：
  - **LHS = 正则字面量**：闭合定界符后**紧贴**（无空白）的 `/` 即开启符，该 `/` **优先于注释识别**。**无 flags 时**闭合符为 `/`、与开启符相邻，连写呈 `//`（两个 `/` 各司其职：前 = 闭合字面量，后 = 开启替换段——并非独立符号）：`/\s//s/r/g`、`/\s//s/r/1`；**带 flags 时**（`i m u`）字面量以 flags 收尾，只有单 `/` 开启符：`/[a-z]/i/s/r/g` ✓。
  - **LHS = Regex 变量/任意 Regex 表达式**：无闭合定界符，替换段直接以**单 `/`** 开启：`let re = /\s/` → `re/s/r/g`、`re/s/r/1` ✓；变量后 `//` **不**开启替换段（`//` 按注释识别——该写法不构成替换：语句实际在 LHS 处结束，其余部分为注释）。
  替换段依次为：目标串表达式、`/`、replacement 表达式、可选 `/` + 修饰符（`g` 或十进制整数 `n`）；修饰符段以 `-` 开头 → 词法错误。
- **replacement 语义**：**字面文本**替换（`$` 不展开——捕获组引用属 M2）；空 replacement = 删除匹配部分，合法。
- **边界（冻结）**：① pattern 为空 → 加载期拒绝（§3.3）——非空 pattern 保证每次匹配至少 1 字节，替换扫描天然推进、**无零宽匹配死循环**；② `n` 超出匹配次数或整体无匹配 → 替换返回**原串**（不报错），`~` 返回 false、`!~` 返回 true；③ `n = 0` 即第一个匹配；④ flags（`i m u`）对替换同样生效（同一 Regex 常量）；⑤ 句柄 null → 6（既有 fetch 语义）；⑥ 替换结果为新 String（分配型——I8/重放安全：重放重建等值串）。
- **类型**：`~` / `!~` 结果为 Bool；替换结果为 String。

---

## §12 JIT 后端规格（Linux · 指令集跟随仓颉 SDK for Linux；当前 x86_64 / AArch64）

### §12.1 适用范围与架构基线

**指令集支持范围跟随仓颉 SDK for Linux**——下表为**当前**状态（SDK 扩大指令集支持范围时，本实现随之新增后端，详见下条）：

| 平台 | 引擎 |
|---|---|
| Linux x86_64 | 解释器 + JIT（后端 **B1**；当前 SDK 支持） |
| Linux aarch64 | 解释器 + JIT（后端 **B2**；当前 SDK 支持） |
| Linux 其他架构（**当前 SDK 未支持**；如 riscv64 / loongarch64 / …） | 仅解释器 |
| Windows / macOS / HarmonyOS（任意架构） | 仅解释器（接口与语义完全一致；`jit = Force` 亦静默降级） |
| 任何 32 位宿主（Windows x86 / Linux i686 / armv7 / …） | **不支持**（**冻结决策**：cell 64 位、ctx 64 字节是硬前提；构建期/装载期明确拒绝，见 §9 附则 9） |

- 平台范围是**冻结决策**：JIT 后端只随 Linux 构建产出，**指令集支持范围跟随仓颉 SDK for Linux**（当前 x86_64 / aarch64；SDK 扩大支持范围时本实现**随之扩大**，按范围变更流程执行——§13 原则 4 + §13.2 重跑）；非 Linux 平台不编译机器码路径，也不得因缺少 JIT 而报错或降级语义（§9 附则 10）。
- 基线 ISA：x86_64 用 **SSE2**（x86-64 ABI 已保证存在）；aarch64 用 **NEON/ASIMD**（A64 基线）。JIT **不发射** AVX/AVX2/AVX512/SVE，不做运行时特性探测分支；需要时由 `CompileOptions.cpuFeatures` 显式开启（M2）。
- 引擎选择（三平台语义一致，只看能否拿到机器码）：

```cangjie
let engine = if (opts.jit == JitMode.Off) {
    Engine.Interp
} else {                                   // Auto / Force
    if (Platform.isLinux && (Platform.arch == X86_64 || Platform.arch == Aarch64)) {
        Engine.Jit        // Auto 另以字节码指纹为缓存键
    } else {
        diag("jit unavailable on ${Platform.os}/${Platform.arch}; fallback to interp")
        Engine.Interp
    }
}
```

### §12.2 后端抽象与 ABI 映射（两后端必须等价）

| 抽象名 | x86_64（SysV） | AArch64（AAPCS64） | 角色 |
|---|---|---|---|
| `CTX` | `r15` | `x19` | **callee-saved**，全程持 ctx；helper 调用不失效 |
| `FP` | `rbp` | `x29` | 帧基址 |
| `SP` | `rsp` | `sp` | 操作数栈 + 局部槽 |
| `RETV` | `rax` | `x0` | 返回值 cell |
| `TMP` | `r10`、`r11` | `x9`、`x10` | 立即数/中间结果（caller-saved，跨 helper 调用不可存活） |
| helper 入参 | `rdi=ctx, rsi=&args, rdx=n` | `x0=ctx, x1=&args, x2=n` | 见 §6 helper ABI 的**抽象签名**：`(ctx, &args, nargs)` |
| helper 返回 | `rax` | `x0` | cell |
| 返回地址 | 由 `call` 压栈 | `x30`(lr) | aarch64 必须由 prologue 保存 `x29/x30` |

- 两平台栈均要求 **16 字节对齐**，故 §3.1 的 `frameSize` 统一按 16 取整，两后端共用同一计算式。
- `CTX` 必须落在 callee-saved 寄存器：helper 调用会打烂 caller-saved（x86 的 `rdx/rcx`、aarch64 的 `x0–x17`；`x18` 为平台保留寄存器，同样不可依赖）。

### §12.3 入口 / 出口序列

```asm
; x86_64
    endbr64                     ; CET/IBT 若启用（未启用时为无害指令）
    push  rbp
    mov   rbp, rsp
    mov   [rbp-8], r15          ; 保存调用方 r15（callee-saved，与 §3.1/§4 一致）
    mov   r15, rdi              ; CTX
    sub   rsp, FRAME
    ...
    mov   r15, [rbp-8]          ; 恢复调用方 r15
    mov   rsp, rbp
    pop   rbp
    ret
```

```asm
; aarch64
    bti   c                     ; BTI 若启用（未启用时为无害指令）
    stp   x29, x30, [sp, #-16]!
    mov   x29, sp
    str   x19, [x29, #-8]       ; 保存调用方 x19（callee-saved，帧位形与 x86 相同）
    mov   x19, x0               ; CTX
    sub   sp, sp, #FRAME
    ...
    ldr   x19, [x29, #-8]       ; 恢复调用方 x19
    mov   sp, x29
    ldp   x29, x30, [sp], #16
    ret
```

- `endbr64` / `bti c` 策略为"**可用即发射**"：在未启用 CET/BTI 的内核上分别是 `NOP` 与无害指令，两后端代码路径统一。
- 入口第一参数位置不同（`rdi` vs `x0`），因此**桥必须为每个后端各生成一个 5 行的 thunk**，thunk 之后是同一份"把 args 拷进 locals"的序言模式（§4 prologue 的逐条展开）。
- 出口唯一（`.epilogue`）：`RET / RET_VOID / BAIL` 全部 `jmp .epilogue`，`BAIL` 前置 `eax/x0 = 0`（哑值）。

### §12.4 关键指令降低对照（语义必须逐位一致）

| 字节码 | x86_64 | AArch64 |
|---|---|---|
| `IADD`(checked) | `add rax,[rsp+8]; jo .bail3` | `adds x9,x9,x10; b.vs .bail3`（`adds` 置 V） |
| `ISUB`(checked) | `sub` + `jo` | `subs` + `b.vs` |
| `IMUL`(checked) | `imul`（置 OF）+ `jo` | `mul` **不置 V**：用 `smulh x11,x9,x10; cmp x11, x9, asr #63; b.ne .bail3` |
| `IDIV`(checked) | `test r10,r10; jz .bail1`；再判 `INT64_MIN / -1` → `.bail3`；然后 `cqo; idiv r10`（商 rax） | `cbz x10,.bail1`；`movz x11,#0x8000,lsl #48`(INT64_MIN)、`mov x12,#-1`（`movn`）比较后 `b.eq .bail3`；`sdiv x11,x9,x10` |
| `IMOD` | 除零判定与 IDIV 同；除数为 -1 → 直接得 0（硬件 `idiv` 对 `INT_MIN/-1` 会 `#DE`，而数学上余数恒 0，**不报溢出**）；否则 `cqo; idiv` 取 `rdx` | `sdiv` 不陷入，`msub` 天然正确（含 `INT_MIN/-1` → 0） |
| `PUSH_I8/PUSH_I32` | `movsx` 后压栈 | `sxtb` / `sxtw` 后压栈 |
| `PUSH_F64` | `movabs rax, imm64`（或从常量池 `movsd`） | `movz/movk` 四次拼装（或文字池 `ldr x9, =imm64`） |
| 浮点算术 | `movq xmm0, rax; addsd/subsd/mulsd/divsd` | `fmov d0, x9; fadd/fsub/fmul/fdiv` |
| `SHL_I/SHR_I/USHR_I` | `shl/sar/shr cl`（x86 自动掩码 63） | `lsl/asr/lsr x9, x9, x10`（aarch64 自动取低 6 位）——语义天然一致 |
| `CMP_I` | `cmp` + `setg/setl` 组合出 -1/0/1 | `cmp x9,x10; cset x11,lt; cset x12,gt; sub x11,x12` |
| `EQ_H` / `PUSH_NULL` | 整数 `cmp`（句柄即整数） | 同左 |
| `JZ/JNZ` | `test rax,rax; je/jne` | `cbz/cbnz x9, target` |
| `CALL_HELPER` | 参数经 `rsp` 布局后 `call` | 同样以 `sp` 布局、`bl` |
| `CHECK_ERR` | `cmp qword [r15+0],0; jne .bail` | `ldr x11,[x19]; cbnz x11, .bail` |

**分支可达范围差异（必须处理）**：

| 后端 | 条件分支范围 | 无条件分支范围 | 处理 |
|---|---|---|---|
| x86_64 | `jcc rel32` ≈ ±2 GB | `jmp rel32` ≈ ±2 GB | 通常无需 trampoline |
| aarch64 | `b.cond` ≈ **±1 MB** | `b` ≈ ±128 MB | 越界时插入跳板（trampoline）或跳板表 |

由于 aarch64 条件分支范围小，汇编器/后端需做**两遍布局**：先按短分支编码，越界则升级为"取反条件 + 无条件 `b`"跳板。此逻辑必须在两个后端共享的布局阶段实现，而非各自硬编码。

**分配/值运算/变更指令的 lowering**：`A1/A3–A8`、`0x9A–0x9E`、`0xB0–0xBE`、`0xAB–AF` 全部与 `CALL_HELPER` 同一模式——`call <helper>` + 自动 `CHECK_ERR`。其中分配型（A4–A8、0x9A、0x9C、0xB0–0xB7、0xAF、0xB8–B9、0xBB、0xBC–0xBE）在宿主 helper 内分配并登记窗口槽（结果 = 新句柄 ID）；0x9B/0x9D/0x9E/0xBA 与**变更型（A1/A3/0xAB–AE）**返回原始值、不登记。各类机器码均无新增模式，I8 自动满足；变更型的重放安全性由 §9.15② 的静态禁令保证。`hwCap` 初值取自宿主参数 `initialCapacity`（默认 128，§9.6），JIT 与解释器共用同一窗口机制。

**闭包值指令的 lowering（v0.10，§8.6）**：`closure_new`/`LOAD_CAP` 与 helper 调用同款（`call H54/H56` + 自动 `CHECK_ERR`）；`CALL_CLOSURE` = `call H55 closure_fnid`（句柄 → fnId）→ `call H57 fn_table`（单元函数机器入口表基址，非 GC 内存，桥在执行前填充）→ **间接调用** `call [fnTable + fnId*8]`——各 FuncEntry 机器入口带 `endbr64`，IBT 安全（§12.3）；fnId 由前端烘焙并经 §7 校验 7 + `closure_new` 双重校验。含 `CALL_CLOSURE` 的函数按 §7 校验 11 标记 `flags.bit0`（黑盒，deopt 禁令）。

### §12.5 代码内存、缓存与生命周期

- 内存：`mmap(PROT_READ|PROT_WRITE)` → 写入 → `mprotect(PROT_READ|PROT_EXEC)`，**W^X**，绝不使用 RWX。页大小取 `sysconf(_SC_PAGESIZE)`（4 KB / 16 KB / 64 KB 都必须正确）。
- aarch64：写入代码后必须清 I-cache（`__builtin___clear_cache` 或 `dc cvau / dsb ish / ic ivau / dsb ish / isb` 序列）；x86_64 由硬件保证一致性，但同一抽象接口调用。
- 不使用可执行栈；不修改既有代码页后重入（M1 不做跳转补丁，跳板只在编译期布局阶段解决）。
- 生命周期：`JitFunction` 释放时 `munmap`；编译缓存以 `(arch, cpuFeatures, bytecodeFingerprint)` 为键，**仅驻内存**，进程退出即丢弃。
- 失败处理：`mmap/mprotect` 失败 → `Engine.Interp` 降级（不是错误，不写错误槽）。

### §12.6 并发与去优化

- `JitFunction` 编译完成即**不可变**，可跨线程共享；编译自身用每函数一次的状态机（`NotCompiled → Compiling → Ready`，CAS 或自旋锁），重复请求等待或直接解释执行。
- **单元级"只编译一次"去重**：`compile` 以源码指纹（主入口）/字节码指纹（分发入口）为键查询进程级编译缓存（仅驻内存）：`Ready` → 复用同一 `JitFunction`；`Compiling` → 阻塞等待（成功共享结果、失败共享异常）；Miss → CAS 占位（`Idle → Compiling → Ready/Failed`）后执行管线（源码 → 字节码 → OS 检查 → JIT/解释器，§8）；条目可经单元卸载（§8.7）移除——同指纹再 compile 重新执行管线。与函数级 JIT 状态机（上条）两层并存，共同保证并发安全与**相同源码只编译一次**。
- DEOPT：`errCode = -1` → 桥回解释器重跑（§8 第 3 步）。因为机器码不分配（分配仅在宿主 helper 内，结果只是句柄 ID，I8），机器码**不需要栈映射（stack map）**，也就无需帧重建——这是最大的简化。重放会重新执行分配型 helper、产出等值的不可变新对象，语义不变（§9.13、T10）；**含变更型调用（变更型 helper/预定义 helper/`CALL_CLOSURE`）的函数不参与重放**——deopt 源已在汇编期禁用（§9.15②），防御性 -1 按 99 上报。
- 安全点：仅 `LOOP_BACK` 回边（`interrupt_poll`），保证超时可中断；不做异步抢占。

### §12.7 后端合规判据（可测定义）

对同一 `.fbc` 与同一输入，以下三者必须**逐位相等**（结果值 / NaN 位模式 / `errCode` / `site`）：

```
interp(args)  ==  jit_x86_64(args)  ==  jit_aarch64(args)
```

任何不一致一律视为 JIT 缺陷；唯一豁免是 §11.3 中显式标记为"平台相关"且默认不启用的特性（M1 无此类特性）。

---

## §13 平台矩阵与差分测试

### §13.1 能力矩阵

| 维度 | Windows x64 | Linux x86_64 | Linux aarch64 | Linux 其他 64 位 | macOS arm64 | HarmonyOS arm64 |
|---|---|---|---|---|---|---|
| 解释器 | 必须 | 必须 | 必须 | 必须 | 必须 | 必须 |
| JIT | — | B1 | B2 | — | — | — |
| 加载 `.fbc` | 是 | 是 | 是 | 是 | 是 | 是 |
| 常量表 | 同一份 | 同一份 | 同一份 | 同一份 | 同一份 | 同一份 |
| `jit = Off/Auto/Force` | 三值均为解释器 | Auto/Force 生效 | Auto/Force 生效 | 三值均为解释器 | 三值均为解释器 | 三值均为解释器 |
| 错误码 / site | 同一套 | 同一套 | 同一套 | 同一套 | 同一套 | 同一套 |

> **指令集支持范围跟随仓颉 SDK for Linux**（当前 x86_64 / aarch64）——SDK 扩大支持范围时本矩阵随之扩展（新增后端列）；非 Linux 平台恒为解释器（§9 附则 10、§12.1）。

### §13.2 测试项

| # | 测试项 | 判据 |
|---|---|---|
| T1 | **黄金字节码**：一份 `.fbc` 在所有平台加载执行 | 结果哈希与错误码完全一致 |
| T2 | **差分（核心）**：Linux 上 `interp` vs `jit_x86_64` vs `jit_aarch64` | 结果、`errCode`、`site` 三者全等 |
| T3 | **端序**：显式解码单测（构造非对齐/跨页边界的操作数） | 不依赖主机端序与对齐 |
| T4 | **页大小**：4 KB / 16 KB / 64 KB 页内核（或容器）各跑一遍 | 代码缓存分配、`munmap`、I-cache 清理正确（与 §12.5 一致） |
| T5 | **CET/BTI**：启用 IBT/BTI 的内核上运行 JIT | 入口 `endbr64` / `bti c` 正确，无控制保护异常 |
| T6 | **错误一致性**：§2 全部**执行期**错误码（1–20、99）逐条触发（19 为桥层契约错误，由 T15 覆盖） | 三引擎 `code` 与 `site` 相同；无未映射错误码漏出 |
| T7 | **降级一致性**：Windows/macOS/HarmonyOS 上 `jit = Force` | 不报错、结果与 Linux 解释器一致、diagnostics 有记录 |
| T8 | **NaN 与文本**：跨平台浮点边界 + 多语言字符串（含 4 字节码点） | 与 §11.3/§11.4 规则逐条相符 |
| T9 | **冻结决策回归**：装载 `flags.bit1=1` 的 `.fbc`；32 位构建/装载；非 Linux 上 `jit = Force` | 前两者明确拒绝（§9.9 / §11.6）；后者静默降级且结果与 Linux 解释器一致（§9.10） |
| T10 | **分配与重放**：含 `STR_CAT/DEC_*/DUR_*` 的函数触发 DEOPT 重放；循环内分配超过初始 `hwCap` | 重放结果值相等、`errCode/site` 一致；窗口扩容正确，16 仅在全局上限出现 |
| T11 | **TO_STR 黄金值**：§11.9 全类型格式 ×（±0 / NaN / Inf / 极端 Decimal / 4 字节码点插值 / Duration 全分解（零 `0s` / 负值 / 跨天 / 毫·微·纳秒分量）/ Regex round-trip `/pattern/flags` / 混合 `+` 双向 × 全标签类型 / DateTime × TZ∈{UTC, 含夏令时非 UTC}） | 三引擎输出逐字节一致；DateTime 行**固定 TZ** 采集（基准 TZ=UTC 黄金 + 非 UTC 附加用例），其余与黄金文件全等 |
| T12 | **混合类型差分**：§11.9 提升矩阵全组合（3 类型对称对 × 四则与比较 × 提升方向，含 2^53 边界、`0.1` 类浮点、除零、空区间判定）；**小数字面值精确构造**（`0.1` 字面值 → Decimal("0.1")，与 `0.1f64` 位模式可区分；指数形式 `3e2`/`1e-3` 的 scale 正确）；**显式窄化与超 Int64 字面值**（F64→I64 越界 → 13、DEC→I64 越界 → 9；超 Int64 整数字面值 → Decimal scale=0；>34 位有效数字**精确保留**——任意精度） | 三引擎结果与错误码逐位一致，与提升规则推导值全等；字面值构造、窄化失败码与 §11.9 规则全等 |
| T13 | **类型化局部变量与明确赋值**：全部 13 种 LocalType（10/11 自 v0.18 全槽位）的显式赋值/读取；读未赋值局部 → **汇编期拒绝**（非运行期错误）；`PUSH_NULL` 直存句柄型局部 → 拒绝；句柄型局部在后续 helper 调用（可能触发 GC）后仍有效；类型表破坏性用例（长度错/非法值）被加载器拒绝 | 明确赋值/空安全在汇编期强制（数据流含回边不动点，见 §5 循环降低模式）；零值填充**不可观察**（无任何用例可读到 0/null）；存活语义逐位一致；非法类型表拒绝且纳入 crc32 |
| T14 | **句柄 Marshal 与逃逸**：call 返回 `STR_CAT/DEC_ADD` 结果 → 窗口重置后 `get` 有效；`release` 后 `get` → None 且表项不重用（gen 校验）；DEOPT 重放产物值相等；逃逸区超配额 → 16；跨调用 ID 稳定性（常量稳定、分配型不保证） | 逃逸/释放/重放语义符合 §8.1 矩阵；pin/get/release 在并发下无竞态 |
| T15 | **统一包装 call\<T\>**：§8.2.1/§8.2.2 全类型组合（含错误入参：长度不符、元素类型不符、T 与返回类型不符 → 19）；call 与桥内部 invoke 对同一执行错误的 `code/site` 一致；三引擎差异对 call 不可见；异常转换清单逐条验证 | 全部契约错误 → 19 且 `site=-1`；执行错误与内部 invoke 逐位一致；无非 JitException/非 InterruptedException 异常逃逸 |
| T16 | **只编译一次去重**：多线程并发 `compile` 相同源码/相同 `.fbc`（含一方 Compiling 中另一方加入）；编译失败后的同键重入；不同源码并行编译 | 成功路径恰好执行一次管线（计数断言）、全部线程收到同一 `JitFunction`；失败共享等价异常；不同键互不阻塞 |
| T17 | **并发重复调用**：多线程并发调用同一 `JitFunction` 数百次（覆盖分配/循环/分支/DEOPT 触发/`call` 契约错误），期间宿主 GC 并发运行 | 每线程结果/错误码/site 与单线程基准**逐位一致**；线程间无状态串扰（局部隔离断言：线程写各自的句柄型局部互不可见）；无悬挂句柄 |
| T18 | **容器变更差分**：`LIST_APPEND/INSERT/SET/REMOVE`、`MAP_PUT/REMOVE` 全组合 ×（越界、常量容器目标 → 20、null 目标 → 6、tag 不符 → 8）× 三引擎；变更函数与 `DEC_TO_I64` mode=1 同单元 → 汇编期拒绝（§7 校验 11）；`FuncEntry.flags.bit0` 标记正确 | 三引擎变更结果与错误码逐位一致；宿主侧可见的容器终态一致；20/4/6/8 全部按 §2 触发；禁令用例编译期拒绝 |
| T19 | **迭代与快照语义**：§11.9 迭代规则全组合——List 迭代中 append/remove（快照长度）、Map 迭代中写键/删键（**fail-fast：修改同一 map → 23**；修改其它容器不受影响）、Range 步进溢出 → 3、String 逐码点；嵌套 for-in 的迭代器表行为（游标独立、出口 close、条目不随执行增长） | 三引擎迭代序列逐位一致；迭代语义与 §11.9 全等；无快照槽（0 槽/执行）；迭代器条目随调用回收、无泄漏 |
| T20 | **字符串切片/替换与正则（v0.6）**：STR_SUB（越界 → 4、`a==b` → 空串、`s[a..=b]` 前端折算等价性）；STR_REPLACE（空模式 → 14、多匹配全替换、替换串含模式子串）；正则字面量 ×（i/m/u 全组合、**任意书写顺序、重复幂等** × is_match/find/无匹配 → 0），同 (pattern, flags) 单元内同 ID、**编译次数 == 常量数**（一次编译断言）；非法 pattern → 加载期 `JitException(14)` | 三引擎结果/错误码/site 逐位一致；复用与去重断言成立；正则语义与 std.regex 一致（同版本 std 下跨平台确定） |
| T21 | **多重赋值与交换（v0.6）**：`(a, b) = (b, a)` 及 n 元推广 ×（值型/句柄型局部、RHS 含变更型调用与错误路径、`_` 忽略位仍求值、同变量 RHS 别名 `(a, a) = (b, a)`、嵌套于循环与分支） | 同时赋值语义逐位一致（先读后写）；隐藏局部不影响可观察行为（零值填充不可观察，§3.1）；三引擎结果/错误码/site 全等 |
| T22 | **源入口格式与自递归（v0.7）**：lambda 源入口全形态（无参/多参/容器参数 List/Map/`=>` 缺失 → 前端拒绝/具名与默认参数 → 拒绝/Regex 参数 → 拒绝）；返回类型推导 × `call<T>` 校验（T 与尾表达式不符 → 19；分发入口按 `FuncEntry.retType` 校验）；`recursive` 深度递归（参数逐位一致、`fnId` 归因随递归层修正、中等深度 × 三引擎、含变更型的递归函数受 §9.15 约束） | 非法源码前端拒绝；`call<T>` 结果类型识别全部正确；递归结果/错误码/site 三引擎逐位一致；retType 非法值被加载器拒绝 |
| T23 | **Compiler 门面与预定义函数（v0.8）**：注册/重名/超限/注销；名字解析（未注册调用 → SourceCompileException 含名字/位置/已注册清单；未定义标识符；形参遮蔽调用 → 拒绝）；user helper 调用桥（参数/返回 marshal × 全 LocalType 组合、impl 异常 → 99 + cause、返回句柄登记/逃逸/自动回收）；含预定义调用 → flags.bit0 + deopt 禁令；分发装载含 user hid 的 `.fbc` → 加载期拒绝；并发注册 + 编译 | 四需求全路径正确；异常信息含名字/位置/已注册清单；三引擎逐位一致；快照语义（注册变更不影响已编译产物）；分发拒绝正确 |
| T24 | **嵌套闭包、立即调用与注释（v0.9）**：按值捕获快照（声明后修改 `var` 对闭包不可见）、多层嵌套与遮蔽、`recursive` 绑定最近闭包（每层独立自递归；内层**裸** `recursive` 不可达顶层——v0.12 起经值化捕获可达，T28）、IIFE（`{=> a + b}()` 与带参变体）、注释剥离（单行/多行、多行**嵌套配平**、未闭合 → 编译错误、字符串字面量内不识别）、闭包逃逸使用 → 拒绝（first-class 合法形态由 T25 细化）、变更型嵌套闭包经 CALL_CLOSURE/CALL_FUNC 传递 | 目录函数数 == 顶层 + 嵌套闭包数（本用例不含值化 ⇒ 无适配器；含值化用例见 T28）；快照语义与词法绑定逐位一致；三引擎结果/错误码/site 全等；捕获未赋值变量 → 编译错误；注释剥离正确且不影响语义 |
| T25 | **first-class 闭包值（v0.10）**：闭包表达式求值（`closure_new` 分配、捕获快照逐位一致）；变量绑定/重赋值（同签名兼容、异签名 → 编译错误）；`CALL_CLOSURE` 调用（参数/返回全 LocalType 组合、`recursive` 自递归、嵌套捕获闭包句柄）；向下传参（CALL_FUNC 参数槽 12）与链内返回（retType=12）；逃逸拒绝（存容器/跨桥 call\<T\> → 19 或前端拒绝）；含 CALL_CLOSURE → flags.bit0 + deopt 禁令；`fnTable` 间接调用在 IBT 开启内核正确 | 闭包对象等值重建（重放安全）；三引擎结果/错误码/site 逐位一致；逃逸路径全部拒绝；LocalType 12/retType 校验正确 |
| T26 | **正则操作符（v0.11）**：`~` / `!~` ×（匹配/不匹配/无匹配/flags i-m-u 组合/空 replacement）；替换 ×（`g` 全局、省略修饰符 = 第 0 个、`/n` 各位次含越位 → 原串、多匹配连续扫描、replacement 含正则元字符与 `$` 字面保留、空 pattern 加载期拒绝；**三书写形态**——无 flags 字面量 `/\s//s/r/g`（闭合符+开启符相邻呈 `//`）、带 flags 字面量 `/[a-z]/i/s/r/g`（单 `/`）、Regex 变量 `re/s/r/g` 与 `re/s/r/1`（单 `/`），三形态同语义同产物）；词法（`!~` 单 token、替换段紧贴 `/` 优先于注释识别、**变量后 `//` 按注释识别、不开启替换段**、`-` 修饰符 → 词法错误）；优先级/结合性（高于加减低于乘除、左结合 × 与算术混排） | 四形式语义与 §11.9 全等；三书写形态（无 flags `//` / 带 flags 单 `/` / 变量单 `/`）产物逐字节等价；三引擎结果/错误码/site 逐位一致；分配型语义（重放等值）；优先级与结合性按文法全等 |
| T27 | **内存安全（v0.11）**：ctx 非托管内存配对释放 ×（正常返回 / 全部错误码路径含 1–20、-2 / 99 / DEOPT / 桥 Marshal 失败 / 宿主 GC 并发搬移期间调用）；句柄表四路径无泄漏断言（A 驻留有界、B/C/D 调用后归零）；`call<T>` 循环 10^6 次句柄表占用不增长；gen 递增与 tag 校验拦截 release 后旧 ID（invoke 路径） | 所有路径 ctx 配对释放（计数断言 malloc==free）；句柄表稳态零残留；无悬挂 ID 命中错配对象；三引擎行为一致 |
| T28 | **recursive 值化与外层递归（v0.12）**：顶层 `let outer = recursive` + 嵌套闭包内 `outer()` 与 `recursive()` 并存（双递归收敛 × 带参/无参顶层 × 深度 ≥ 3）；闭包层值化（IIFE 外层经 `let self = recursive` 传自身给内层）；适配器转发（实参 argc 不符 → 14、`fnId` 归因 entryFn 而非适配器、适配器帧 `locals[0]` 句柄槽不参与参数传递）；顶层签名含 Closure 参数 → 值化编译错误；值化求值的分配行为（窗口登记含之、deopt 重放等值重建、窗口回收无泄漏（§8.1 规则 6①））；值化引用不可逃逸（存容器 → 前端拒绝/19、跨桥 → 19） | 经捕获的外层调用与直接 `CALL_FUNC` 语义逐位一致（结果/错误码/site/fnId）；适配器对可观察行为零影响（目录计数按"源函数 + 隐藏适配器"断言）；三引擎全等 |
| T29 | **单元卸载（v0.13）**：卸载后调用 → 19（site=-1）× 三引擎；活跃调用排空（长调用 × `unload(timeout)` 超时恢复 Ready → 重试成功；`unload(None)` 阻塞至排空）；执行中调用不受卸载影响（结果逐位正确、不注入 -2）；并发双 unload 幂等且资产仅释放一次；**并发 compile（同指纹）与 unload 交错**（Unloading 期间到达 → 阻塞至卸载完成后按 Miss 重编，产出新 `JitFunction`、绝不返回旧句柄）；卸载 → 同源码 re-compile → 新 `JitFunction` 结果与基准一致、旧引用调用 → 19；编译缓存条目移除断言（管线重执行计数）；ConstTable 释放后常量对象 GC 可回收（弱引用观察）；code buffer/fnTable malloc==free 配对（T27 扩展）；A 槽 `gen`+1 后旧 ID 尽力拦截（tag/世代校验行为）；`isUnloaded` 状态转换正确 | 全部断言成立；三引擎行为一致；无悬挂执行、无双重释放、无泄漏；**并发交错与序贯语义等价** |
| T42 | **字符串字面量形态（v0.14，编号接 m2/m3 序列）**：多行 ×（两式定界 `'''`/`"""`、首行换行后起始、转义三引号不终止、单独 `\` → 编译错误、跨行/缩进逐字节保留、未闭合 → 编译错误）；原始串 ×（`#`×n 与引号匹配计数、verbatim（`\n` 不转义）、无插值、单/双引号两种、可跨行、EOF 未闭合 → 编译错误）；`>|` 锚定 ×（进入判定——**仅有效标记触发**；有效标记识别（前导仅缩进空白 + 首两个非空白符 = `>|`）；**非空白符之后的 `>|` 为字面内容且不触发、不截取**（`x >| y`、`>>|`、`a>|b`、`|>|` 行均原样保留）；**无有效标记的行（含空白/非空白）整行原样保留**；标记行与保留行混排（首/中/末位置组合）；**标记符号不进入产物**（前导缩进+标记消耗、单独 `>|` 行 → 空串、标记后 `>|` 为字面文本）；`>|>|asdfaf>|` → `>|asdfaf>|`、`>|    >|` → `    >|`；截取后正常转义与插值）；换行规范化（CRLF/CR → `\n`）；**异种引号内容（v0.18.9）**：`'"aa"'` 的 `"` 与 `"'aa'"` 的 `'` 逐字节进入产物、不参与定界配对（含混合连续串；多行内异种引号含三连为内容、不终止；同种引号转义/三连终止对照）；词法消歧（起始三引号最长匹配）；常量化（kind 3——**无格式变更**） | 各形态产物逐字节与黄金值一致；**异种引号为内容（产物逐字节含之，`'"aa"'` → `"aa"`、`"'aa'"` → `'aa'`）**；**产物中不含被消耗的标记与前导缩进**；编译错误 kind 正确（`MultilineHeadContent`/`UnterminatedMultilineString`/`UnterminatedRawString`）；三引擎结果一致；跨平台编译产物一致（换行规范化） |
| T43 | **字符串重复与日期差（v0.15）**：`s * n` ×（n ≤ 0 → 空串（含负值）；n=1；多字节 UTF-8 字符；`n * s` 换序；n 为 F64/DEC 的自动窄化（向零截断、NaN/越界 → 13、DEC 越界 → 9、负值 → 空串）；`n × len` 溢出 → 3；大 n 分配失败 → 99）；`dt1 − dt2` ×（正/负差、相等 → 零、跨年、Duration 值域边界 → 12）；两运算 × 分配路径（窗口登记 1 槽、逃逸、重放等值）；不含变更型 → deopt 无禁令对照 | 三引擎结果/错误码/site 逐位一致；窄化插入位置与报错码与 §11.9 全等；结果与 std 语义等价物逐位一致 |
| T44 | **if 双用法与分支类型（v0.15.1）**：语句用法 ×（`if c { 1 } else { "s" }` 类型互异且合法、分支末值经 `POP` 丢弃且**栈平衡无残留**、裸 if、嵌套于循环/分支、句柄型分支值同样丢弃）；值用法 ×（`let x = if …` / `x = if …` 同型通过；混合 I64/F64/DEC → 编译错误（不做提升）；句柄型 vs 值型 → 错误；容器分支元素类型不同 → 错误；无最终 else → 错误；作为实参/运算数/尾返回时分支不一致 → 编译错误）；明确赋值汇合 ×（全部分支赋值才视为已赋值——两种形式同规则） | 语句用法不引入任何类型约束（产物栈平衡逐位一致）；值用法类型规则与 §5 全等；三引擎结果/错误码/site 全等 |
| T45 | **Map 惰性迭代（v0.16.1）**：单遍断言（无预遍历——宿主侧 `iterator()` 调用计数 == 循环执行数、无 O(n) 预扫描）；模式序列（advance/key/value/close）与 close 幂等；嵌套循环（迭代器表独立游标）；`break`/`continue`（出口 close 汇聚、表条目不随执行增长）；**迭代中修改同一 map → 23**（写键/删键 × advance 触发）+ 修改他容器不受影响；坏游标/未推进取件 → 99（防御）；deopt 重放（新游标、旧条目随调用回收）；窗口账目（**0 槽/执行**） | 三引擎迭代序列/结果/错误码/site 逐位一致；23 与 std CME 对齐；表条目 ≤ 嵌套深度 |
| T46 | **Regex 互操作与运行期构造（v0.17）**：Regex 作参数（桥 `pin` → helper 使用；null/类型不符 → 19）与作返回（retType=9 逃逸 → `get` → Regex 实例；`call<T>` T=Regex）；CALL_FUNC 链内 Regex 传参/返回；嵌套闭包签名含 Regex；`s.regex()` ×（合法构造与字面量同语义——is_match/find/replace 结果逐位一致；非法 pattern → **14**、空 pattern → **14**（site=调用点）；恒无 flags；每次求值新对象、**不去重**（同 pattern 两构造 → 行为等价、ID 不同）；分配型窗口登记 1 槽 / 重放等值重建）；加载期与运行期拒绝分列（字面量 kind 10 → 加载期 14；`regex()` → 执行期 14） | 三引擎结果/错误码/site 逐位一致；Marshal/解包与既有句柄类型同路由；无泄漏（T27 模式） |
| T47 | **自动尾递归优化（v0.17）**：尾位置判定（体末表达式 / `if` 双分支 / 块末 / 嵌套组合 × 顶层与嵌套闭包；非尾位置——运算数、实参、`let` 右值——不优化）；深度 ≥ 10^6 尾递归**栈深恒定、不溢出**（宿主栈用量断言；对照组：非尾位置维持调用语义、栈深随深度增长）；优化与未优化**语义逐位一致**（结果/错误码/site；实参求值顺序与失败路径；变更型尾递归照受 §9.15 禁令）；回边产物（`STOREL` 逆序 + `LOOP_BACK <入口>`；操作数栈回基线；不发射 `RET`）；安全点（深尾递归中 `deadline` → `-2` 可取消）；`hasLoop`/§7 校验 6 由回边自然生效；T24/T28 非尾路径对拍 | 帧深恒定断言成立；三引擎结果/错误码/site 与回边模式逐位一致 |
| T48 | **容器自建与返回（v0.18）**：空字面值 ×（`{}`/`[]` 每次求值新实例——同一调用内两次求值 ID 不同、行为等价；上下文类型来源（局部注解 / 实参签名）；无上下文 → 编译错误）；List/Map 局部全流程（声明-赋值-变更-读-返回；明确赋值/空安全照常）；自建容器变更（MAP_PUT/LIST_APPEND 等——非路径 A 写许可；构造+变更函数 flags.bit0 照旧）；逃逸返回（retType=10/11 → 桥 `get` 得宿主对象；每次调用新对象——调用内 ID 稳定、跨调用不保证，§8.1 规则 4）；**非空字面值对照（仍为常量——写 → 20；字面值变量返回 v0.18.1：交付共享常量对象、ID 跨调用稳定、宿主只读契约、D 路径对路径 A no-op；闭包字面值变量返回 → 编译错误对照）**；窗口账目（构造每次登记 1 槽，hwCap 对账）；deopt 重放（纯构造路径等值重建）；`{}`/`[]` 降序产物（MAKE_MAP/MAKE_LIST 断言） | 三引擎结果/错误码/site 逐位一致；空/非空字面值语义分界正确；无泄漏（T27 模式） |

### §13.3 版本演进约束

1. 新增 opcode 只允许使用 §5 保留区段，并同步升 `verMinor`；语义变更升 `verMajor`。
2. 新增 JIT 后端（如 riscv64）只能是"新增一个 lowering 表 + 一个 ABI 映射行"，不得修改 §11 字节码语义。
3. 任何"解释器能跑、JIT 跑不了"的指令都不得进入字节码（`flags.bit1` 恒 0）。
4. **冻结决策不得被平台适配绕过**：M1 只支持 64 位宿主，且 JIT 仅在 Linux、且指令集在仓颉 SDK for Linux 支持范围内（当前 x86_64 / aarch64）生效（§9 附则 9–10）。任何"给某平台开特例"的补丁，只要它改变语义、改变可用性（在非 Linux 上抛错而 Linux 不抛）或要求 JIT 必须存在，一律拒绝；确需变更时按 §9 附则的变更流程走**范围变更**并重跑 §13.2。
