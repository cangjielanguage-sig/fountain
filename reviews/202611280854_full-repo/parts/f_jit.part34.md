# f_jit 模块审查报告（第 34/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/`（本部分 17 个源文件，全部位于 `src/compiler`、`src/macros`、`src/runtime`、`src/`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`）

> 本部分覆盖：`Token.cj`（词法单元/诊断分类常量）、`macros/*`（`@JitBind` / `@JitSignatures` / `@IgnoreJitBinding`）、`runtime/AnyHelpers.cj`（H78/H79/H80）、`runtime/DbgDump.cj`（转储与报告），以及 11 个测试文件。

## 发现

### [一般][存量] setter 名生成规则有两套实现，非 ASCII 属性名会得到两个不同的绑定名

- **位置**：`f_jit/src/macros/JitBind.cj:380`（`capitalize`）↔ `f_jit/src/ReflectRegistrar.cj:895`（`upperFirst`）；调用点 `JitBind.cj:352` 与 `ReflectRegistrar.cj:232`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑，「只改实现/近似重复且其中一处缺少边界判断」）+ §11（边界未处理）
- **证据**：静态确定
  - 宏侧：`s[0..1].toAsciiUpper() + s[1..]`。`String[Range<Int64>]` 是**按 UTF-8 字节下标**切片且「起止点必须位于字符边界上」（std `core_package_structs.md` §`operator func [](Range<Int64>)`，第 9380 行起），首字符为多字节时 `s[0..1]` 切在字符中间，得到非法 UTF-8 片段。
  - 反射侧：`unsafeBytes().clone()` 后仅当首字节是 `0x61..0x7A` 才减 `0x20`，再用 `String.fromUtf8` 还原——多字节首字符原样保留。
  - 「标识符可用中文」有文档依据：`docs/dev-guide/source_zh_cn/basic_programming_concepts/identifier.md:12`（`XID_Start` 含中文，示例含 `仓颉`）。
- **描述**：同一条约定（`mut prop foo` 的 setter 名为 `setFoo`）被实现两遍。ASCII 名下两者一致；中文/全角名（如 `mut prop 名字`）下宏生成 `"set" + 半个汉字 + "字"`，反射侧生成 `"set名字"`。反射注册会先按 `set名字` 占名并成功（`ReflectRegistrar.cj:231-244`），宏侧那条 `set<非法字节>` 名字不与它冲突，于是同时进表：被引用的 `set名字` 仍然是反射包装（`InstanceVariableInfo.setValue` 的 MCC 路径），宏承诺的「类型化静态赋值」静默失效，函数表里还多出一个永远不会被调用的非法 UTF-8 名字。`capitalize` 只用 ASCII 转换、其余原样保留，即可与反射侧完全对齐。
- **建议**：把「首字符大写」抽为单一规则并让两处同源——宏侧改为 `s.unsafeBytes()` 级操作或 `String.fromUtf8` 重建（非 ASCII 首字符不转换），或干脆规定「属性名必须是 ASCII 起始」并在宏里 `diagReport(ERROR)` 明确拒绝；补一条中文 `mut prop` 的 `JitBind` 用例（现有 `JitBindIgnore_test.cj` 只用了 ASCII 名）。

### [一般][存量] `@IgnoreJitBinding` 标在 `init` 上完全无效

- **位置**：`f_jit/src/macros/JitBind.cj:77`（`if (f.identifier.value == 'init')` 先于 `:83` 的 `ignored.contains`）；反射侧 `f_jit/src/ReflectRegistrar.cj:358`（构造器合并路径不查 `isIgnored`）
- **来源**：存量
- **判据**：review-checklist §3（「开关打开后走进空分支」/契约承诺但实现为空）+ §11（契约与实现不符）
- **证据**：静态确定 —— `Ignored` 名单在 `:69-72` 收集完成，构造函数分支在 `:77-82` 直接 `buildCtor` 并 `hasCtor = true`，`else if (ignored.contains(...))` 位于 `:83` 只覆盖普通方法与 `:95/:106/:118/:130/:137` 的静态/字段/属性分支；`ReflectRegistrar` 的 11 处 `isIgnored` 调用（`:144`、`:210-211`、`:250`、`:286`、`:308`、`:330`、`:518`、`:586`、`:619-620`）无一条在 `:358` 的构造器循环里。
- **描述**：`@IgnoreJitBinding` 的契约是「成员级退出标记，按名字跳过」（`IgnoreJitBinding.cj:22-30`），但 `@IgnoreJitBinding public init(...)` 仍会生成 `PublicCtor` 并进注册表（宏侧），反射侧也会退回 `ConstructorInfo.apply` 的自动包装（`ReflectRegistrar.cj:820-826`）。用户按文档标注后「编译通过、脚本仍能构造该类型」，属于静默失效。
- **建议**：把 `ignored` 判定提到 `init` 分支之前（`if (ignored.contains(f.identifier.value)) { () } else if (f.identifier.value == 'init') ...`），并在 `ReflectRegistrar` 的构造器循环里按同一名字过滤；或明确在宏注释与 README 里写「`init` 不支持忽略」，同时在 `IgnoreJitBinding` 里对 `init` 直接 `diagReport(WARNING)`。

### [一般][存量] `@JitBind` 静默丢弃接口的静态成员（不告警、不进 `statics`）

- **位置**：`f_jit/src/macros/JitBind.cj:94`、`:105`、`:117`（三条静态分支都带 `!isIface`）
- **来源**：存量
- **判据**：review-checklist §3（`match` 落到 `_ => ()` 吞掉分支）+ §14（只做了一半的分支 / 能力未接线）
- **证据**：静态确定 —— 宏文档 `JitBind.cj:40` 承诺「静态函数 / 静态只读字段 / 只读静态属性 → `PredefinedFunction`（进 `statics`）」，未排除接口；三条分支的 guard 显式加了 `!isIface`，落空后走 `:147 case _ => ()`，无 `diagReport`。仓颉接口允许静态函数：`docs/dev-guide/source_zh_cn/class_and_interface/interface.md:162`（`static func typename(): String`）。
- **描述**：`@JitBind` 修饰接口时，接口里的 `static func` / `static let` / 只读 `static prop` 既不进 `methods` 也不进 `statics`，也不像 `static var`（`:107-109`）那样发 WARNING。用户会以为「宏已覆盖」，实际脚本侧调不到，只能靠运行期「未注册函数」发现。
- **建议**：去掉静态分支上的 `!isIface`（接口静态成员生成 `$clsName.$nameTok(...)` 同样成立），或至少在 `case _ =>` 前补一条「接口静态成员未纳入注册面」的 `diagReport(WARNING)`，并在宏注释的「覆盖面」清单里写清接口静态成员的归属。

### [一般][存量] 宏内类型码表未含 15–19，`Any` / JSON / 泛型实参一律落成 14（HOST_OBJECT）

- **位置**：`f_jit/src/macros/JitBind.cj:430`（`codeOf`）、`f_jit/src/macros/JitSignature.cj:268`（`codeOf`，逐项复制）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）+ §2（字面量复制的码表）
- **证据**：`待确认` —— 宏侧静态可确定「表里只有 0–11 与 `_ => 14`」，与 `LocalType`（`f_jit/src/base/LocalType.cj:57-71`：`HOST_CLOSURE=13`、`ANY=15`、`JSON_VALUE..JSON_NULL=16..19`）不同步；缺的是「运行期是否按码严格比对绑定形参」的证据（`PredefinedFunction.params` 的消费点不在本部分）。
- **描述**：`@JitBind` / `@JitSignatures` 里写 `Any`、`JsonObject`、`Option<Int64>` 之类的形参或返回值时，`codeOf` 返回 14，`classNameOf` 返回 `'Any'`/`'JsonObject'`/`'Option'`。若注册/调用侧按「码 + 类名」查 id（`TypeRef_test.cj:50-53` 的注释与 `JitHost.registerSignature` 口径），这些签名会去查一个不存在的注册类，或被当成 `HOST_OBJECT` 参与类型匹配；M3 新增的 15–19 完全没有入口。
- **建议**：把码表收敛成**一份**（宏包内共享 `private func typeCodeOf(name)`），补齐 `12/13/15/16/17/18/19`；对仍无法静态映射的形态（`Option<T>`、`Array<T>`、复合类型）不要静默落 14，改为 `diagReport(ERROR)` 指明「不支持的类型形参」。

### [一般][存量] `DbgDump.report` 文档承诺 `dump` 为 null 时只输出行号，实现直接解引用

- **位置**：`f_jit/src/runtime/DbgDump.cj:148`（注释 `:146`）、解引用 `:168-169`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符 + 空值未处理）
- **证据**：静态确定 —— `:167-170` `unsafe { let p = dump; if (p.read(0) == 0) { return out } }`，此前无 `dump.isNull()` 判定；同文件的 `writeOnceStackRaw:95` 有 `dump.isNull()` 前置检查，`JitFunction.cj:608/689` 也都先判 null。
- **描述**：注释与 `report` 的第二个重载共同承诺「`dump` 为 null ⇒ 只有行号」，但 7 参重载对 null 会直接 `read(0)`，是空指针解引用（崩溃），而不是降级。当前两个生产调用点（`CompilePipeline.cj:350`、`test/diff/RealRunners.cj:449`）只传已分配的缓冲，所以问题潜伏；一旦有人按注释「传 null 省一个分支」就会炸。
- **建议**：`let p = dump; if (p.isNull() || p.read(0) == 0) { return out }`；5 参重载改为 `report(..., dump: CPointer<Int64>(0))` 的直接转发（见下条重复逻辑）。

### [一般][存量] `DbgDump.allocateDump` 不检查 `malloc` 失败就写首两格

- **位置**：`f_jit/src/runtime/DbgDump.cj:49`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 资源分配未判空）
- **证据**：静态确定 —— `:50` `let p = LibC.malloc<Int64>(count: HEADER_WORDS + maxNLocals)`，`:51-54` 立即 `p.write(0, 0); p.write(1, 0)`，无 `isNull()`；同仓同类分配都判空并降级：`f_jit/src/backend/NativeAssets.cj:75-78`（「失败 → None」）、`NativeAssets.cj:160`、`backend/CodeBuffer.cj:61`（还额外判 `UIntNative.Max`）。
- **描述**：`maxNLocals` 取自字节码目录全域（`CompilePipeline` 的 `maxNLocalsOf`），是可信值，但分配失败仍可能发生（容器内存吃紧 / 大函数）。失败时不是返回错误码，而是写地址 0 → 进程崩溃，绕过「编译期/运行期单一错误出口」的设计。该路径每次都分配（`JitFunction.cj:605`）。
- **建议**：`if (p.isNull()) { NativeMem.bumpMalloc(); return CPointer<Int64>(0) }`，调用方已有 `dump.isNull()` 判定（`JitFunction.cj:608`），按「无转储」降级即可；同时保持 `NativeMem` 计数对称（失败也计数或不计数要写清）。

### [一般][存量] `@JitSignatures` 只按函数名生成符号名，同包同名函数/成员函数会导致重定义或登记不生效

- **位置**：`f_jit/src/macros/JitSignature.cj:66`（`'__jitSigRegister_' + owner`）、`:67`（`'__jitSigApply_' + owner`）、`:68-74`（插入位置）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §14（接线缺失）
- **证据**：`待确认` —— 静态可确定生成名只由 `funcNameOf(input)`（`:107-116`，取 `func` 后第一个标识符）决定，无文件/位置/唯一化后缀；缺的是「宏系统对成员函数上的宏展开把声明插在类体内」这一行为的实证（当前仓内唯一用例 `JitSignature_test.cj:31` 是包级函数）。
- **描述**：两种触发面。(1) 同包内对**同名**函数（重载，或不同类的同名方法）各标一次 `@JitSignatures` ⇒ 生成两个同名的包级 `func __jitSigRegister_f`，直接重定义报错，且报错位置指向宏生成物而非标注处。(2) 标注在**成员函数**上时，生成的 `public func` / `private let` 落在类体内：登记不再发生在包初始化，而是每次构造实例时执行一次（`private let` 是实例字段初始化器），与文档「只要该包被初始化过，签名就已在表里」（`:64-65`）相反，并会重复登记同一条签名。
- **建议**：生成名加入唯一化成分（宏上下文里的声明位置/序号），或在 `expandSignatures` 里对 `owner` 做「已被占用则追加序号」；对成员函数标注直接 `diagReport(ERROR, input, '@JitSignatures 只能标注包级函数', ...)`，把限制写进宏注释的「边界」段。

### [一般][存量] `splitTopLevel` 只跟踪圆括号深度，泛型实参里的逗号会切断签名

- **位置**：`f_jit/src/macros/JitSignature.cj:119`（深度只在 `:126-130` 处理 `LPAREN`/`RPAREN`）
- **来源**：存量
- **判据**：review-checklist §11（边界未处理）+ §3（错误路径给出误导信息）
- **证据**：静态确定 —— 只有 `(`、`)` 增减 `depth`，`<`/`>`/`[`/`]`/`{`/`}` 一律不参与；`<` 在 `std.ast` 里是 `LT`/`SUB` 之类的普通 token。
- **描述**：`@JitSignatures[(HashMap<String, Int64>) -> Int64]` 会在 `<String, Int64>` 的逗号处切断，得到两组：第一组 `(HashMap<String`、第二组 `Int64>) -> Int64`；第一组进入 `parseSignature` 后报「签名必须写成 `(T1, T2) -> R`」（`:147-149`），错误文案与真实原因（不支持泛型实参）无关，标注者要自己猜。同类边界：`@JitSignatures[]`（空属性）不告警、静默生成一个空登记函数。
- **建议**：`<`/`>`/`[`/`]` 一并计入深度（注意 `>>` 与嵌套模板的配对），或对出现 `<` 的组直接给出「形参只支持单个类型名，不支持泛型实参」的定向诊断；`groups.size == 0` 时复用无属性重载的 WARNING。

### [一般][存量] `@JitSignatures` 与 `@JitBind` 同一张类型码表各写一份

- **位置**：`f_jit/src/macros/JitBind.cj:436-450` 与 `f_jit/src/macros/JitSignature.cj:269-283`（12 个 `case` + `_ => 14`，逐行同形）；`classNameOf` 亦然：`JitBind.cj:454-460` ↔ `JitSignature.cj:286-292`
- **来源**：存量
- **判据**：review-checklist §2（「字面量复制」：同一张状态码表散落多处）
- **证据**：静态确定 —— 两段 `match` 的 case 顺序、返回码、默认值完全一致，只有入参类型不同（`TypeNode` vs `String`）。二者同属 `macro package fountain::f_jit.macros`，可直接共享 `private` 工具函数。
- **描述**：`LocalType` 的码表已经是「唯一来源」（`base/LocalType.cj:141-149` 的注释也这么写），宏侧却有两份手抄副本，且都不含 15–19。任何一侧漏改都只会在运行期表现为「签名查不到」，编译期无任何报错。上一条（码表缺 15–19）只要两处不同步修，就会退化成「`@JitBind` 与 `@JitSignatures` 对同一类型给出不同码」。
- **建议**：抽到宏包内的共享文件（如 `macros/TypeCodes.cj`）并只保留 `typeCodeOf(name: String)` / `classNameOf(name, code)`；`JitBind` 侧先 `t.toTokens()[0].value` 再调同一函数。

### [轻微][存量] `MacroExpandDecl` 逐层下钻的循环在两个宏文件里各写一份

- **位置**：`f_jit/src/macros/JitBind.cj:199`（`unwrapMemberMacro`，循环在 `:203-205`）与 `f_jit/src/macros/IgnoreJitBinding.cj:39`（`identifierOf`，循环在 `:43-45`）
- **来源**：存量
- **判据**：review-checklist §2（同语义不同落点：一个返回声明、一个返回名字，前两步完全一致）
- **证据**：静态确定 —— 两处都是 `var inner: Decl = m.macroInputDecl; while (let md: MacroExpandDecl <- inner) { inner = md.macroInputDecl }`，随后一处 `inner`、一处 `inner.identifier.value`；区别只在返回类型。
- **描述**：同一「剥掉未展开的嵌套成员宏」的规则有两份。谁将来支持新的包装形态（例如再加一层 `MacroExpandDecl` 之外的转发），漏改一处就会出现「宏展开顺序不同 → 成员被重复绑定或被漏掉」，且极难复现。
- **建议**：合并为 `private func unwrapDecl(d: Decl): Decl`（`IgnoreJitBinding` 侧 `unwrapDecl(decl).identifier.value`），放在两个宏文件都能用的共享文件里。

### [轻微][存量] `DiagKind.DUPLICATE_REGISTRATION` 全仓零引用，实际诊断改用硬编码字符串

- **位置**：`f_jit/src/compiler/Token.cj:304`
- **来源**：存量
- **判据**：review-checklist §1（硬原则二：`internal class DiagKind` 的 `public static const` 成员，全项目无使用即死代码）+ §2（字面量复制）
- **证据**：静态确定 —— 全仓 `grep -rn "DiagKind.DUPLICATE_REGISTRATION"` 命中 0；同一错误实际以裸串抛出：`f_jit/src/Compiler.cj:71` `throw SourceCompileException('DuplicateRegistration', ...)`、`:75` `'NotImpl'`（后者也有现成常量 `DiagKind.NOT_IMPL`）。其余 17 个 `DiagKind` 常量均有 ≥2 处引用。
- **描述**：注释自称「常量在本包登记，供 §4.3.9 清单完整」，但注册冲突的实际诊断走字面量，常量永不产生。既有「常量无人用」，又有「字面量与常量并存」——改文案时漏改常量、或测试按常量断言会拿不到。
- **建议**：`Compiler.cj:71/75` 改用 `DiagKind.DUPLICATE_REGISTRATION` / `DiagKind.NOT_IMPL`；若确实不再需要该 kind，删除常量并同步 §4.3.9 清单注释。

### [轻微][存量] 三段「形参装配」循环逐行重复（三处仅差 `args` 偏移与前缀码）

- **位置**：`f_jit/src/macros/JitBind.cj:232-248`（`buildMethod`）、`:394-410`（`buildCtor`）、`:471-487`（`buildStaticFunc`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名/只改常量的重复）
- **证据**：静态确定 —— 三段结构相同：遍历 `params` → `codes += codeToken(p.paramType)` → `prelude += let $p = match (args[$(i)] as $pType) {...} + NL` → `callArgs += pTok`；差异仅两点：`buildMethod` 用 `args[i + 1]` 且 `codes` 预置 `14`（接收者），另两处用 `args[i]`。同一文件内 `buildMethod:251-260` 与 `buildStaticFunc:489-498` 的 `retCode`/`retName` 双重 `try/catch` 也是复制。
- **描述**：三个入口任一处改判据（例如给形参加 `retName`、或改 `typeMismatch()` 的降级方式）都要同步三遍；`args` 偏移差一处就变成「接收者被当成第一个形参」的错误绑定，且只在运行期表现为类型不符。
- **建议**：抽 `private func paramPrelude(params: Array<FuncParam>, offset: Int64, codes: Tokens): (Tokens, Tokens)` 一处生成 `codes`/`prelude`/`callArgs`，`buildMethod` 传 `offset = 1` 并在外面拼接收者码；`retCode`/`retName` 合并为 `private func retTokens(t: TypeNode): (Tokens, Tokens)`。

### [轻微][存量] `DbgDump.report` 两重载的整体结构逐行复制

- **位置**：`f_jit/src/runtime/DbgDump.cj:157-165` ↔ `:193-201`
- **来源**：存量
- **判据**：review-checklist §2（换控制流/同语义两份）
- **证据**：静态确定 —— 首行模板 `'（code=${code}，site=${site}）'`、`site < 0` 早退、`siteTable.lookup` 的 `Some/None` 两条文案，两处一字不差。
- **描述**：5 参重载存在的唯一理由是「没有转储缓冲」，而这正好可以用 `dump.isNull()` 在 7 参重载里覆盖（见上文空指针条）。现在两份模板各自维护，改模板（「逐字节冻结」的模板是三引擎对拍基准）时漏改一处就会让「有 / 无转储」两条路径的报告格式不一致。
- **建议**：5 参重载保留为便捷壳（`report(code, site, fnId, types, siteTable, nameTable?, dump)` 传空指针），把模板与站点查询收敛到一处；`slotText` 已按 `nameTable` 可缺省处理，`types` 在无转储时用不到。

### [轻微][存量] `X86Compile_test` 自建 `hex`/`nib`，与 `CodeDump.hex` 及另两个测试文件同款

- **位置**：`f_jit/src/compiler/X86Compile_test.cj:138`（`hex`）、`:149`（`nib`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制：同一张十六进制表）
- **证据**：静态确定 —— `CodeDump.hex`（`f_jit/src/compiler/CodeDump.cj:69`）同输入同遍历；差异只有大小写：`CodeDump.hex` 经 `hex2` 产出小写，本文件 `nib` 产出 `'A'..'F'`（断言里用的也是大写常量）。同名私有副本还有 `backend/X86Frame_test.cj:71`、`backend/X86Lower_test.cj:597`（各自带 `nib`）。
- **描述**：四个文件各持一份「字节数组 → hex 串」，是本部分最典型的复制粘贴。测试断言里 30 多个大写十六进制常量依赖大写形态，所以不能直接换 `CodeDump.hex` 而不改断言。
- **建议**：给 `CodeDump` 增加 `hexUpper`（或 `hex(bs, upper!: Bool = false)`），三个测试文件统一调用；顺带把 `recursiveCompilesWithFnTable:42-50` 内联复制的 `compile()` 加载流程（`:170-178`）改为「`compile(src, constBase, fnTableBase)` 增加一个参数」。

### [轻微][存量] 测试里的 `errKind`/`errText`/`countOf` 在 8+ 个文件里各写一份

- **位置**：`f_jit/src/compiler/TypeRef_test.cj:112`（`errKind`）、`:122`（`errText`）；`f_jit/src/compiler/UnaryNotShape_test.cj:101`（`countOf`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件复制；「测试里的准备代码」是误报边界，但这里是**断言口径**的复制，会漂移）
- **证据**：静态确定 —— `grep "func errKind"` 命中 `A4Frontend_test.cj:236`、`A7JsonSet_test.cj:66`、`AnyCastAux_test.cj:99`、`AnyCast_test.cj:222`、`AnyFrontend_test.cj:286/290`、`AstM2_test.cj:65`、`JsonAccess_test.cj:304/308`、`JsonLit_test.cj:235`、`NameResolver_test.cj:88`、`TypeRef_test.cj:112`；`grep "func countOf"` 命中 `A4Frontend_test.cj:310`、`AnyFrontend_test.cj:315`、`StrictFpCodegen_test.cj:79`、`UnaryNotShape_test.cj:101`。`TypeRef_test` 内部 `errKind`/`errText` 只有「取 `e.kind` / 取 `e.message`」一行之差。
- **描述**：同一段「跑 Parser、捕获 `SourceCompileException`、取字段」被复制十余份；其中 `AnyCastAux_test`/`AnyFrontend_test` 已出现「带 `PredefinedSnapshot` 的重载版本」，说明副本已经开始各自演化。断言口径（例如是否要求「必须抛出」而不是「拿到空串就通过」）无法统一收紧。
- **建议**：放进已有测试支撑包 `fountain::f_jit.test`（仓内已有 `test/TCase.cj` 等），提供 `DiagProbe.kindOf(src)` / `textOf(src)` / `countOf(text, pat)`；`TypeRef_test.errKind`/`errText` 先合并为 `errField(src, field)`。

### [轻微][存量] `buildStaticValue` 的 `fromVar` 形参从未被读取

- **位置**：`f_jit/src/macros/JitBind.cj:513`（声明）、`:114`（传 `true`）、`:126`（传 `false`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死参数）
- **证据**：静态确定 —— 函数体 `:515-531` 只用到 `ident`、`t`、`clsName`；`fromVar` 无任何出现。两个调用点分别来自 `VarDecl` 与只读 `PropDecl`。
- **描述**：这是「静态 `let` 与只读 `static prop` 共用一条生成路径」的残留参数；保留它会让人以为两种来源有差别（实际上 `v.declType` / `p.declType` 已在调用点选好）。
- **建议**：删参数与两个实参；若将来要按来源生成不同绑定，再显式加回来。

### [轻微][存量] `anyIs` 用 `let unused = ctx; let _ = unused` 占位

- **位置**：`f_jit/src/runtime/AnyHelpers.cj:53`
- **来源**：存量
- **判据**：review-checklist §1（局部变量赋值后只被丢弃）+ §10 可读性
- **证据**：静态确定 —— `:53-54` 两行只为消化未使用的 `ctx` 形参，函数体其余部分不再引用 `ctx`。
- **描述**：H79 是纯读算子、不需要 ctx，两行占位式「消除未使用告警」比直接 `let _ = ctx` 多一次无意义绑定；同类写法在 `anyValueOf`/`anyMatches` 都没有。
- **建议**：合并为一行 `let _ = ctx // H79 纯读，不使用 ctx`，或把 `ctx` 形参在调度表里统一忽略。

### [轻微][存量] `anyBox` 里 `code == LocalType.ANY` 是恒假条件，同一谓词在 Lowerer 也复制了三份

- **位置**：`f_jit/src/runtime/AnyHelpers.cj:44`
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支）+ §2（同一判定多处复制）
- **证据**：静态确定 —— `LocalType.isConvertible`（`f_jit/src/base/LocalType.cj:141-149`）对 `12`、`13`、`15` 显式返回 `false`，故 `!isConvertible(code)` 已覆盖 `15`，`|| code == LocalType.ANY` 永不单独成立；同款冗余谓词见 `compiler/Lowerer.cj:1005`（`&& code != LocalType.UNIT`）与 `:2646`（`&& code != LocalType.ANY`）。
- **描述**：注释「可转集之外（含 12/13/15）不得装箱」本身说明作者知道 15 已在集合外；多出来的判断让人误以为 `isConvertible` 会放行 15。三处重复也意味着「可转集」规则改一次要改三处。
- **建议**：删掉 `|| code == LocalType.ANY`，只留 `isConvertible` 一处判据；若想保留防御性写法，改为在 `isConvertible` 里断言并用同一个 helper（如 `LocalType.isBoxable(code)`）。

### [轻微][存量] `Token.cj` 的注释表与实现不一致（构造器数、运算符数、用例覆盖承诺）

- **位置**：`f_jit/src/compiler/Token.cj:24-33`（表格：5+16+12+24+1=58）、`:133-137`（「60 项两两比对」）
- **来源**：存量
- **判据**：review-checklist §10 可读性 / §13 文档一致性（同文件注释即契约）
- **证据**：静态确定 —— 枚举实际 63 个构造器（`grep -c "^    | "` 得 63）：关键字族含 `KwAs`、`KwIs`（19 项含 `Ident`），另有 `JsonLit`；运算符含 `StarStar`、`QuestionQuestion`（26 项）。`ordinal` 表 63 行。`Token.cj:136` 声称「写漏任何一项都会在 `Lexer_test.allSixtyKindsAreConstructible` 暴露」，但该用例（`Lexer_test.cj:50-110`）只列 60 项、断言 `n == 60`，`StarStar`/`KwIs`/`JsonLit` 均未列入；`ordinal` 编号互异性没有任何用例（若两项写重，`==` 会把两个不同 kind 判成相等）。
- **描述**：读者按注释会以为「58 个构造器、全表有测试兜底」。实际是 63 个，且有 3 个 kind 的 `==` 语义与编号唯一性完全无覆盖（当前编号确实互异，属「恰好正确」）。
- **建议**：更正表格为实际数量并注明 M2/M3 增量；把遗漏的 3 个 kind 补进 `Lexer_test` 的构造清单（断言 63）；加一条「63 个 kind 的 `ordinal` 两两互异」的用例，把 `ordinal` 的唯一性从「人工保证」变成「测试保证」。

### [轻微][存量] `HEADER_WORDS` 注释描述的是 3 格布局，实际是 2 格

- **位置**：`f_jit/src/runtime/DbgDump.cj:45`
- **来源**：存量
- **判据**：review-checklist §10 可读性 / §13（注释与实现不一致）
- **证据**：静态确定 —— 注释「首格哨兵 + fnId + nLocals（nLocals 占 1 格）」暗示 3 格，常量值为 `2`；实际布局是 `[0] = fnId + 1`（哨兵与 fnId 合并，`writeOnceStackRaw:102`）、`[1] = nLocals`（`:103`），函数头注释 `:34-35` 与 `:45-46` 的说明正确，只有这一行把「哨兵」当独立格。
- **描述**：`HEADER_WORDS` 是 `allocateDump` 与所有 `write` 偏移的唯一来源，注释差一格容易让人写出 `HEADER_WORDS + 1` 之类的偏移错误。
- **建议**：改为「首格 `fnId+1`（同时充当未填哨兵）+ 次格 `nLocals`，共 2 格」。

### [轻微][存量] `AnyHelpers_test` 同一用例挂了两个 doc 注释，`call` 只是转发

- **位置**：`f_jit/src/runtime/AnyHelpers_test.cj:177-185`（`:177-184` 与 `:185` 两段 `/** */` 紧邻）、`:110`（`call` 直接 `return invokeHelper(...)`，无额外语义）
- **来源**：存量
- **判据**：review-checklist §2（重复）/ §10 可读性
- **证据**：静态确定 —— `:184` 的注释块没有跟任何声明，`:185` 是第二条 doc；`call` 与 `invokeHelper` 签名同构（`ctx, hid, args` → `Int64`）。
- **描述**：孤儿注释块描述了「容器不变语义」，紧接的第二条只有一句，读者会以为是两个用例；`call` 这层包装让全文 40 余处调用多一跳，也掩盖了「测试直接驱动 helper 表」的意图。
- **建议**：合并两段注释；删除 `call`，全文直接调 `invokeHelper`（或把它改名成 `callH` 只差一字，不如去掉）。

### [轻微][存量] `X86Compile_test` 8 个用例只断言「产物非空」

- **位置**：`f_jit/src/compiler/X86Compile_test.cj:30`、`:37`、`:50`、`:57`、`:63`、`:69`、`:76`、`:83`
- **来源**：存量
- **判据**：review-checklist §10 可测试性 / §11（断言不覆盖契约）
- **证据**：静态确定 —— 这些用例统一 `@Assert(code.size > 0, true)`；真正验证编码内容的只有 `:88-136` 的 `checkedArithmeticUsesJno` / `ctxStoresAreQword` / `goldenFloatDivCastClosureLen`。
- **描述**：`branchCompiles` / `containerCompilesWithConstMirror` / `floatAndCompareCompiles` 等名字承诺「分支/容器/浮点比较能编出来」，但任何「编出错误指令序列」的回归都能通过——只要 `compileFunctionWith` 返回非空。这与同目录 `UnaryNotShape_test` 的「结构断言要落到具体 op 序列」口径不一致。
- **建议**：至少对每条用例断言一个特征字节（如分支用例断言 `Jcc` 的 `0F 8x`、容器用例断言 `H18/H01` 的 mov 立即数），或统一改为 `CodeDump.ops` 的助记符断言。

## 优化可行性方案

> 本部分没有「有基线」的性能方案。以下三条只是「值得下一轮补数据」的方向，按规则同时登记进「待验证假设」，不当作结论。

### [CPU] `DbgDump.report` 的逐条字符串拼接（无基线）

- **现状**：`report:174-181` 每条局部变量一次 `items.add('[i] ...')`，再由 `joinItems:233-244` 用 `out = out + it` 累加；`nLocals` 上界是目录全域（`maxNLocalsOf`），典型函数 < 32。
- **方案**：`ArrayList<String>` + 手写 join 换成一次性 `StringBuilder`（或 `String.join`）。
- **预期**：只在 `nLocals` 较大时减少 O(n²) 复制；错误路径单次执行，端到端可观测收益预计低于噪声。
- **代价**：无（输出必须逐字节不变，`DbgDump_test.reportTemplateIsByteExact` 可守住）。
- **验证**：`cjpm bench -O2` 构造 `nLocals = 64/256` 的伪帧，取 10 轮中位数；同时比对报告文本。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `report` 的字符串累加在 `nLocals` 大时成为可观开销 | `f_jit/src/runtime/DbgDump.cj:174-181`、`:233-244` | 单次耗时随 `nLocals` 的增长曲线 | 构造 8/32/128/512 槽的帧，跑 1e4 次 `report`，记中位数 |
| 2 | `anyAs` 每次命中都新登记 1 槽，高频 `as` 会先撞窗口（128）而非 CPU | `f_jit/src/runtime/AnyHelpers.cj:92-108` | 真实脚本里 `as` 的调用频次与窗口占用水位 | `WindowPool_test`/`AnyHostCast_test` 加计数埋点，跑典型脚本 10 分钟 |
| 3 | `@JitBind` 生成的「args 数组 → 逐参 match → 静态调用」在成员访问热点上仍有可观开销（相对直接反射路径的收益未量化） | `f_jit/src/macros/JitBind.cj:262-280` | 绑定调用 vs 反射调用的 ns/op | `PerfM2_test` / `CallPathBench_test` 同输入 `cjpm bench -O2` 对照 |

> 以上三条均无可复核基线，不计入模块统计，不进 `todo.md` / `tasks.md`。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/compiler/Token.cj` | .cj | ✅ | 注释表与实际构造器数不符（轻微）；`DiagKind.DUPLICATE_REGISTRATION` 零引用（轻微） |
| 2 | `f_jit/src/compiler/TypeRef_test.cj` | .cj | ✅ | `errKind`/`errText` 与 8+ 测试文件重复（轻微）；类型记法断言与 `Parser`/`AstShape` 实现一致 |
| 3 | `f_jit/src/compiler/UnaryNotDiff_test.cj` | .cj | ✅ | 差分口径完整（引擎数检查 + 绝对值锚定）；`countOf` 与 3 个文件重复 |
| 4 | `f_jit/src/compiler/UnaryNotShape_test.cj` | .cj | ✅ | 结构断言落到具体 op 序列，口径良好；`countOf` 属重复逻辑 |
| 5 | `f_jit/src/compiler/X86Compile_test.cj` | .cj | ✅ | `hex`/`nib` 重复 `CodeDump.hex`；8 个用例只断言非空（轻微） |
| 6 | `f_jit/src/compiler/X86Exec_test.cj` | .cj | ✅ | `@When[x86_64 && Linux]` 门控正确；三字段对拍（result/errCode/site）无缺口 |
| 7 | `f_jit/src/macros/IgnoreJitBinding.cj` | .cj | ✅ | `identifierOf` 的 `MacroExpandDecl` 下钻与 `JitBind.unwrapMemberMacro` 重复 |
| 8 | `f_jit/src/macros/JitBind.cj` | .cj | ✅ | setter 名分歧、接口静态成员静默丢弃、码表缺 15–19、`fromVar` 死参数、三段装配循环重复 |
| 9 | `f_jit/src/macros/JitSignature.cj` | .cj | ✅ | 生成名仅由函数名决定；`splitTopLevel` 不跟踪尖括号；码表与 JitBind 重复 |
| 10 | `f_jit/src/refineUnload_test.cj` | .cj | ✅ | 卸载/缓存语义覆盖到位（单元级逐出、闭包级保留）；仅全局 `CompileCache.reset()` 无清理，测试内可接受 |
| 11 | `f_jit/src/runtime/AnyHelpers.cj` | .cj | ✅ | 分支表与 `LocalType` 一致；`anyIs` 占位变量、`anyBox` 冗余判定（轻微） |
| 12 | `f_jit/src/runtime/AnyHelpers_test.cj` | .cj | ✅ | 双 doc 注释、`call` 转发（轻微）；A2 类界/窗口记账断言充分 |
| 13 | `f_jit/src/runtime/CanonKey_test.cj` | .cj | ✅ | 常量表↔运行期键逐类型对拍；并发用例 4 线程×100 轮，覆盖 open/next/close |
| 14 | `f_jit/src/runtime/DbgDump.cj` | .cj | ✅ | null 解引用（一般）、malloc 未判空（一般）、两重载复制、注释差一格 |
| 15 | `f_jit/src/runtime/DbgDumpM2_test.cj` | .cj | ✅ | 13/14 大类名呈现与「不取对象」契约一致 |
| 16 | `f_jit/src/runtime/DbgDumpM3_test.cj` | .cj | ✅ | 16–19 与 15 的呈现断言完整，含零回归对照 |
| 17 | `f_jit/src/runtime/DbgDump_test.cj` | .cj | ✅ | 转储三条件、首收敛点、模板逐字节均有覆盖；`report` 5 参重载仅一条用例 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 7 条（setter 名、init 忽略、码表缺 15–19、null 转储、malloc 判空、splitTopLevel、JitSignatures 命名）+ 设计 2 条（接口静态成员未接线、码表两处复制）；安全性：本部分无外部输入解析（`Token` 由 `Lexer` 产出、`DbgDump` 只读自有缓冲），无注入面 |
| §1 死代码 | 4 | 逐个 `private`/`internal` 符号全仓搜引用：`buildMethod`/`buildCtor`/`buildStaticValue`/`capitalize`/`codeOf`/`classNameOf`/`tk`/`splitTopLevel`/`parseSignature`/`buildStmt`/`funcNameOf`/`identifierOf`/`propagateFrozen`/`anyValueOf`/`anyMatches`/`classBoundHit`/`listAuxMatches`/`mapAuxMatches`/`beginDump`/`slotText`/`joinItems` 均有调用者；命中 4 条 = `DUPLICATE_REGISTRATION`（零引用）、`fromVar`（死参数）、`anyIs` 占位变量、`anyBox` 恒假子条件。`StarStar => 90` 等 ordinal 值仅需互异（已核对 63 项无重复） |
| §2 重复逻辑 | 8 | 已两两比对 30+ 函数体的「输入-输出-副作用」：码表（缺 15–19）+ 码表两份副本、setter 名×2（宏/反射）、参数装配×3、`report` 重载×2、`hex/nib`×4、`errKind/errText`×10、`countOf`×4、`MacroExpandDecl` 下钻×2；其余（`anyValueOf`/`anyMatches`/`writeOnce` 两重载）确认差异是承载形态（CPointer vs Array、值型 vs 句柄型），属有意展开 |
| §3 空实现 | 2 | `@IgnoreJitBinding` 对 `init` 的承诺落空、接口静态成员落进 `_ => ()`；`JitSignatures()` 无属性重载的「告警 + 原样返回」是有意行为，不算空实现 |
| §4 栈溢出 | 0 | 本部分无递归函数：`MacroExpandDecl` 下钻是 `while` 迭代（`IgnoreJitBinding.cj:43`、`JitBind.cj:203`），`splitTopLevel`/`parseSignature` 为单层扫描；无自引用结构遍历 |
| §5 OOM | 0 | `allocateDump` 的大小来自字节码目录 `maxNLocals`（可信、有界），`anyBox`/`anyAs` 单槽分配且受 `HandleTable.capacityLimit`/窗口上限约束；`report` 的 `ArrayList` 长度 = `nLocals`。无「按报文字段预分配」「只增不减容器」 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench；本部分无 `cjprof` 数据，三条疑似热点已全部降级为「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`AnyHelpers` 操作的是全局 `HandleTable`（其同步在 `HandleTable` 内部，不属本部分），`DbgDump` 只写 ctx 私有缓冲 |
| §6.3 并发串行 | 0 | 无 `spawn`（`CanonKey_test` 的 4 线程是测试本身，任务独立、无批内串行） |
| §6.4 低效算法 | 0 | 唯一 O(n²) 候选是 `report` 的字符串累加，`n` 为 `nLocals`（个位数到几十），且只在错误路径执行一次；无基线，已列入假设 #1 |
| §7 降堆内存方案 | 0 | 本部分无长生命周期容器：`DbgDump` 的缓冲由 `JitFunction` 每次调用分配/释放且已 `NativeMem` 计数，`AnyHelpers` 不持有跨调用状态；无「缩短生命周期/去副本」的可量化收益 |
| §8 降 CPU 方案 | 1 | 唯一候选是 `report` 的字符串累加改为一次性构建（方案见「优化可行性方案 [CPU]」）；无改前基线，只标「无基线（待验证）」，同时登记为假设 #1，不进修复清单 |
| §9 local mode 可行性 | 0 | 本部分函数内无「大临时对象」：宏在编译期执行（与运行期 local region 无关），`AnyHelpers` 每调用只产生 1–2 个句柄无大对象；`DbgDump` 的临时集合是 `nLocals` 个短串，峰值由 `nLocals` 界定，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 9 | 已核对本部分 6 个非测试 `.cj` 的边界/空值/错误路径：setter 名、init 忽略、码表缺 15–19、null 转储、malloc 判空、splitTopLevel、JitSignatures 命名、接口静态成员、码表两份副本；11 个测试文件只做逻辑核对（不把测试自身缺陷计为产品缺陷，只留 2 条轻微可读性） |
| §12 并发安全与锁粒度 | 0 | 无共享可变状态：`JitContext` 每次调用新建（`JitFunction.cj:605` 处分配 `dump`）、`DbgDump` 的静态成员全是 `const`/纯函数、宏在编译期单线程执行；`HandleTable.capacityLimit` 的改写只在 `AnyHelpers_test.p2_6` 内且 `finally` 还原（测试隔离问题，非产品并发缺陷） |
| §14 功能完备性与 README 覆盖 | 1 | 接口静态成员「承诺覆盖但未接线」（一般）；本部分无 README/`doc/**`（模块文档不在 `part34` 清单内，交由其它部分核对），故不做 README 符号对照 |
| 文件覆盖（§13 等） | 17/17 | 清单 17 个文件全部读完，无缺读；本部分无 `.md`，§13 的「文档↔实现」以代码内注释契约代替核对（命中 2 条轻微：`Token` 注释表、`HEADER_WORDS`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 13 |
| 优化方案（堆内存 / CPU） | 0 / 1（无基线，仅入假设） |

存量缺陷 22 条，是否纳入修复待用户决定。

## 总评

本部分（词法单元/诊断常量、三个宏、`AnyHelpers`、`DbgDump` 及其测试）整体质量良好：注释密度高且多数「为什么这么写」的解释可核（`diagReport(ERROR)` + `throw` 的双通道写法与 std 文档建议一致，不是冗余代码；`StarStar` 独立编号 90 的取舍也有说明）；`AnyHelpers` 的分支表与 `LocalType.isConvertible` 逐码对齐，A2 类界、窗口记账、`is` 不置错误的边界都写得清楚；`DbgDump` 的「首个收敛点获胜 / -1·-2 不转储 / 模板逐字节冻结」三条口径在实现与用例里一致。

风险集中在**宏与运行时的契约漂移**：同一套规则（setter 名、类型码表）在宏侧与反射侧各有一份实现，且宏侧那份在非 ASCII 名与 M3 新类型码上已经跑偏；`@IgnoreJitBinding` 对 `init`、`@JitBind` 对接口静态成员则是「文档承诺、代码静默不执行」这一类最难在测试里发现的问题。其次是 `DbgDump` 的两处健壮性缺口（null `dump` 直接解引用、`malloc` 失败不判空）：当前调用点都安全，但都偏离了同仓既有的防御约定。

无严重项与阻塞项。建议排期顺序：先修宏侧契约类（setter 名、init 忽略、接口静态成员、码表），它们都是「静默失效」，越晚发现越贵；`DbgDump` 两处健壮性各是一行守卫，可随手带上；其余重复逻辑与注释更正适合与相邻部分（`Lowerer`/`ReflectRegistrar`/其它测试文件）一并治理，避免只改一半。
