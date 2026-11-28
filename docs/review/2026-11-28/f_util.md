# f_util 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（67 个文件：48 个 .cj + 19 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 4 个分部分报告合并：`parts/f_util.part1..4.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] #1 CRC-32 条件编译在 Linux 非 x86/arm 目标上缺定义，与 README/design 的「其它架构始终纯软件」矛盾

- **位置**：`f_util/README.md:71`、`f_util/README_en.md:71`（承诺）；`f_util/doc/spec/accelerate-f-util-crc/design.md:205`（声称「CRC-32 的 stub 当初只判 `os != "Linux"`，本变更一并修正」）；`f_util/src/crc32_native_stub.cj:23`、`f_util/src/crc32.cj:101`
- **来源**：存量（快照模式无基线；blame 因整仓换行符重写全部落在 `4be871f2f`，不再提供逐行归属）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §14.1（承诺的能力在代码里没有入口）；fountain-baseline §7（不凭记忆断言平台能力）
- **证据**：静态确定 —— 三份 `Crc32Hw` 的 `@When` 并集为 `{Linux && x86_64} ∪ {Linux && aarch64} ∪ {os != "Linux"}`，缺 `Linux && arch ∉ {x86_64, aarch64}`；`crc32.cj:101/106` 无条件引用 `Crc32Hw`，因此该目标组合下 `f_util` 编译失败。对照 `crc64_native_stub.cj:24` 已改成 `os != "Linux" || (arch != "aarch64" && arch != "x86_64")`，说明同一变更里 CRC-32 的修正未落地
- **描述**：README 中英两版都写「其它 OS/架构始终纯软件」，design D7 也写「本变更一并修正」，但 `crc32_native_stub.cj` 仍只判 `os != "Linux"`。只要 cjc 支持 Linux riscv64 / loongarch64（design 明确把这两个架构当作目标），`f_util` 在这些平台上直接编译不过，而不是回退软件。同一仓库的 CRC-64 路径已是正确形态，属于改动漏项
- **建议**：把 `crc32_native_stub.cj` 的 `@When` 对齐 `crc64_native_stub.cj`（`os != "Linux" || (arch != "aarch64" && arch != "x86_64")`）；若确认不支持这些目标，则同步修正 README 与 design 的表述，不要留「已修正」的假记录

### [一般][存量] #2 README 的 FNV 段落描述的是未落地的 API，示例全部不可编译

- **位置**：`f_util/README.md:367-404`、`f_util/README_en.md:369-407`；对照实现 `f_util/src/Fnv.cj:47-205`（读取，未改）
- **来源**：存量
- **判据**：review-checklist §13（示例引用不存在的 API、规格与实现漂移）+ §14.2（公开 API 未文档化）
- **证据**：静态确定 —— 文档写 `Fnv64.fnv1a.compute(bytes)` / `.computeHex()` / `.initRegister()` / `Fnv64.all` / `for (v in Fnv64.all)`；仓内 `computeHex` 仅出现在 `.worktrees/f_jit/.autocode/tmp/fnvref/fnv_copy.cj`（临时草稿），`f_util` 内零命中。实际 API 是 `Fnv64.fnv1a(data: String|Array<Byte>)` 静态函数（`Fnv.cj:107-111`）、`Fnv.hash(width, variant, data)`（`Fnv.cj:49-53`）、`FnvHasher(width, variant).update()/finish()/reset()`（`Fnv.cj:182-203`）
- **描述**：整段 FNV 文档按早期「对象 + compute/computeHex」设计编写，最终实现换成了静态函数 + 统一入口 + `FnvHasher`，文档没有回写。照抄示例一行都编不过；同时真正需要说明的东西缺失：`Fnv1024` 只在「其他公开 API」里列了类型名，无示例无返回值口径；`FnvHasher` 只写了 `reset`；`Fnv.hash` 完全未出现；`README.md:404` 的自检路径写成 `src/fnv_test.cj`，实际文件是 `Fnv_test.cj`（Linux 构建区分大小写）。另有 `README.md:733` 把 `FnvWidth.bits` / `words` 写成 `prop`，源码是 `public func bits()` / `words()`（`Fnv.cj:220-238`）
- **建议**：整段按现实现重写：一次性入口 `Fnv32/64/128/256/1024.fnv1|fnv1a(data)`、统一入口 `Fnv.hash`、增量 `FnvHasher` 三段示例；补 `Fnv1024` 的 16 字返回口径；`FnvWidth`/`FnvVariant` 改成方法调用写法；测试路径改为 `Fnv_test.cj`。中英两版同时改

### [一般][存量] #3 `crc32` / `crc64` 的 `ToString` 泛型重载，文档返回类型写成 `UInt16`

- **位置**：`f_util/README.md:68`（`public func crc32<T>(s: T): UInt16`）、`f_util/README.md:85`（`crc64<T>` 同样写 `UInt16`）；`f_util/README_en.md:68`、`f_util/README_en.md:85`；源码 `f_util/src/crc32.cj:155`（`: UInt32`）、`f_util/src/crc64.cj:92`（`: UInt64`）
- **来源**：存量
- **判据**：review-checklist §13（API 签名与源码不符）
- **证据**：静态确定 —— 同一代码块内 `Array<Byte>` / `String` 重载写的是 `UInt32` / `UInt64`，只有泛型重载是 `UInt16`，属复制粘贴残留
- **描述**：`crc32<T>` / `crc64<T>` 的返回类型被写成 16 位。使用者若按文档声明变量（`let v: UInt16 = crc32(obj)`）会编译失败；若据此推断取值范围，会把 32/64 位校验值当成 16 位处理
- **建议**：`crc32<T>` 改为 `UInt32`，`crc64<T>` 改为 `UInt64`，中英两版四处同改

### [一般][存量] #4 README 称 `jamcrc` 也走 PCLMULQDQ 硬件路径，实现里只有 `isoHdlc` 与 `crc32c`

- **位置**：`f_util/README.md:71`、`f_util/README_en.md:71`；实现 `f_util/src/crc32.cj:80-91`（`classifyHw`）、`f_util/src/crc32.cj:39`（`jamcrc` 定义，`xorout = 0`）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现相反）
- **证据**：静态确定 —— `classifyHw` 只认 `poly=0x1EDC6F41 && xorout=0xFFFFFFFF`（CRC32C）与 `poly=0x04C11DB7 && xorout=0xFFFFFFFF`（ISO）；`jamcrc` 的 `xorout` 是 0，落到 `CrcHwKind.Unsupported`，`update` 直接走 `CrcEngine`
- **描述**：文档把 `Crc32.isoHdlc` / `jamcrc` 并列为硬件加速变体，实际 `jamcrc` 永远纯软件。依赖该结论做容量评估或选型会得到错误预期；也会让「为何 jamcrc 与 isoHdlc 吞吐差一个量级」变成反复排查的问题
- **建议**：删掉 `jamcrc`，或明确写「`jamcrc` 与 `isoHdlc` 只差 final xor，但当前未接线，仍走软件」。若确实想把 `jamcrc` 接进去，属于实现变更，另开条目

### [一般][存量] #5 `GeoHash.encode` 文档把经纬度参数写反

- **位置**：`f_util/README.md:304`、`f_util/README_en.md:306`（`encode(latitude: Float64, longitude: Float64)`）；源码 `f_util/src/geohash.cj:31`（`encode(longitude: Float64, latitude: Float64)`）
- **来源**：存量
- **判据**：review-checklist §13（API 参数与源码不符）
- **证据**：静态确定 —— 源码首参是经度、次参是纬度，且 `encode(coordinate:)` 的实现是 `encode(coordinate[0], coordinate[1])`，注释写明 `(longitude, latitude) = (coordinate[0], coordinate[1])`（`geohash.cj:60-64`）；`decode()` 返回 `(lng, lat)`（`geohash.cj:66-98`）
- **描述**：按文档用命名实参 `encode(latitude: 39.9, longitude: 116.4)` 直接编译失败；用位置实参则静默生成错误 geohash（纬度当经度用），而且错误不会以异常形式暴露。地理类错误一旦落库很难回溯
- **建议**：文档改成 `encode(longitude: Float64, latitude: Float64)`，中英两版同改；顺带写明 `decode()` 返回 `(longitude, latitude)`（当前只在中文注释里写了「经伟度」，英文版写的是 longitude and latitude，两版口径也不完全一致）

### [一般][存量] #6 `TimestampSequenceBuilder` 两个注册方法文档标 `: This`，源码返回 `Unit`

- **位置**：`f_util/README.md:625-627`、`f_util/README_en.md:643-645`；实现 `f_util/src/uuid.cj:646-654`（`registerSequenceGenerator(generator)` / `registerFileSequenceGenerator()`）、`f_util/src/uuid.cj:689-704`（`registerSequenceGenerator()`）
- **来源**：存量
- **判据**：review-checklist §13（签名与源码不符）
- **证据**：静态确定 —— 三个方法体最后一个「项」都是赋值语句（`seqGen = ...` / `closer = ...`），按 `define_functions.md:95-113` 的返回类型推导规则，函数类型为 `Unit`；README 却把 `registerFileSequenceGenerator` / `registerSequenceGenerator()` 写成 `: This`。对照 `TimeBasedUUIDBuilder` 同类方法确实显式返回 `This`（`uuid.cj:465-475`），说明是照抄上层包装类时写错
- **描述**：文档让调用方以为可以链式调用 `builder.registerFileSequenceGenerator().randomSeq`，实际拿到 `Unit`，编译失败。另外 `README.md:590` 把 `TimeBasedUUIDBuilder.registerSequenceGenerator(generator)` 的 `: This` 漏掉了（源码有），同一族方法三种写法并存
- **建议**：`TimestampSequenceBuilder` 三条改成无返回类型（或补 `: Unit`），`TimeBasedUUIDBuilder.registerSequenceGenerator(generator)` 补 `: This`；中英同步

### [轻微][存量] #7 文本模板段落仍宣称依赖 `ThreadLocalStringBuilder`，该依赖已不存在

- **位置**：`f_util/README.md:432-434`、`f_util/README_en.md:436-440`；`f_util/src/TextTemplate.cj:35-36`（仅注释）
- **来源**：存量
- **判据**：review-checklist §13（文档过期）
- **证据**：静态确定 —— 全仓 `grep ThreadLocalStringBuilder` 在 `f_util` / `f_base` / `f_log` 只命中两行注释，无任何类型引用或调用；`TextTemplate` 实际用 `StringGenerator`（`CaseFormat.cj:49` 同款）构造字符串
- **描述**：README 用两段文字要求使用者「不要在同方法内构造字符串时调用本类」，这条约束针对的是已经不存在的实现。使用者会为一个不存在的限制改写代码结构，也会误判该类的线程安全性
- **建议**：删除这两段，或改成当前真实约束（`format` 是否可重入、是否线程安全）

### [轻微][存量] #8 `doc/设计模式.md` 与 README 同段落逐字重复

- **位置**：`f_util/doc/设计模式.md:1-156` 与 `f_util/README.md:141-296`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑：同一份内容两处维护）+ §10（可维护性）
- **证据**：静态确定 —— 五个模式的接口/类声明、注释文字、参数名逐段一致（`Producer`/`Factory`、`Mediator`、`ResponsibilityChain`、`State`、`Strategies`），README 版仅多出代码块标题层级
- **描述**：同一份 API 说明有两个副本，任何签名调整只改一处就会漂移（本轮已发现 README 的 UUID/FNV 段落就是这种漂移的结果）。两处都没有指向源码的锚点，读者无法判断哪份是准的
- **建议**：保留 README 作为唯一对外说明，`设计模式.md` 改成概述 + 链接，或直接删除；若保留，至少在其中标注「与 README 同步维护」

### [轻微][存量] #9 `accelerate-f-util-crc` 变更内 proposal 与 design/spec 口径冲突（4 通道 / 64 字节 / 4 组常量 / 3 参数 ABI）

- **位置**：`f_util/doc/spec/accelerate-f-util-crc/proposal.md:28-31`；`f_util/doc/spec/accelerate-f-util-crc/design.md:143-181`、`f_util/doc/spec/accelerate-f-util-crc/specs/f-util-crc/spec.md:174-175`；实现 `f_util/src/crc64_native_x86.cj:46`（`CFunc<(UInt64, CPointer<Byte>, UInt64, CPointer<UInt64>) -> UInt64>`）
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移；同一变更目录内自相矛盾）
- **证据**：静态确定 —— proposal 仍写「4 通道 128 位折叠」「只处理 `len & ~63`」「3+1 组常量、4 份生成代码」「`CFunc<(UInt64, CPointer<Byte>, UInt64) -> UInt64>`」；design D5 / spec 已收敛为单块 16 字节、`len & ~15`、3 组常量、常量指针四参数 ABI，tasks 5.6 也说明「原计划的 4 通道未采用」，只有 proposal 没回写
- **描述**：变更包内三份文档给出两套算法与两套 ABI。后续维护者按 proposal 改代码会直接对不上机器码与调用点；评审时也无法判断「4 通道」到底是不是已放弃
- **建议**：proposal 的 `What Changes` 按 design/spec 终稿改写（单块、`len & ~15`、3 组常量、4 参数 ABI），或明确标注「本段为初版方案，已被 design D5 取代」

### [轻微][存量] #10 `crc32-hw-cfunc/design.md` 的交付物文件名与 CPU 探测方式同实现不符

- **位置**：`f_util/doc/spec/crc32-hw-cfunc/design.md:155-156`（交付物 `crc32_codegen_x86.cj` / `crc32_codegen_aarch64.cj` / `crc32_bench_test.cj`）、`f_util/doc/spec/crc32-hw-cfunc/design.md:31-32`（`cpuid` 叶子 1）；对照 `f_util/src/` 实际文件与 `f_util/src/crc32_native_x86.cj:203`（读 `/proc/cpuinfo`）、`f_util/doc/perf/crc32-codegen.md:13`（同样写 `/proc/cpuinfo`）
- **来源**：存量
- **判据**：review-checklist §13（链接/路径失效、规格与实现漂移）
- **证据**：静态确定 —— `f_util/src` 下无 `crc32_codegen_x86.cj` / `crc32_codegen_aarch64.cj` / `crc32_bench_test.cj`，实际是 `crc32_native_x86.cj` / `crc32_native_arm.cj` / `crc32_codegen_test.cj`；`crc32_native_x86.cj` 无 `cpuid` 调用，探测走 `/proc/cpuinfo` 的 `sse4_2` / `pclmulqdq`
- **描述**：交付物清单指向不存在的文件，读者按图索骥找不到实现；探测方式在两份文档里给出相反描述（design 说「不依赖 /proc」，tasks 1.3 与 perf 文档说用 /proc）。同一变更的 tasks 与 design 已经互相打脸
- **建议**：design §10 改成真实文件名；§3 与 tasks 1.3 统一成 `/proc/cpuinfo`（当前实现），或说明「曾计划 cpuid，最终改用 /proc/cpuinfo」并给出原因（原设计担心容器屏蔽 /proc，但实现里 aarch64 才有 auxv 回退）

### [轻微][存量] #11 `CaseFormat` 六个子类实现高度重复，属同构复制

- **位置**：`f_util/src/CaseFormat.cj:126-228`（`LowerUnderScoreCaseFormat` / `UpperUnderScoreCaseFormat` / `LowerHyphenCaseFormat` / `UpperHyphenCaseFormat`）、`f_util/src/CaseFormat.cj:70-124`（`PascalCaseFormat` / `CamelCaseFormat`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名/字面量的重复逻辑）
- **证据**：静态确定 —— 四个 delimiter 变体的 `convert` / `delimiter` / `isDelimiter` / `new` 逐行同构，差异只有 `DELIMITER`（`_` vs `-`）与 `toAsciiLowerCase` / `toAsciiUpperCase`；`Pascal` 与 `Camel` 的 `convert` 只差首字符大小写（`CaseFormat.cj:76-84` vs `103-112`），连 `if (builder.size == 0)` 分支都一致
- **描述**：六份几乎相同的状态机，改一条规则（例如连续分隔符折叠、缩写识别）要改六处，漏改就产生行为漂移。同时 `if (builder.size == 0)` 分支与末尾 `else` 在 `delimiter == false` 时完全等价，可读性上也在暗示不存在的差异
- **建议**：抽一个 `DelimitedCaseFormat(delimiter: Rune, upper: Bool)` 承载四个变体，`Pascal`/`Camel` 共用一个带 `firstUpper: Bool` 的基类；`convert` 里把首字符特例写成 `delimiter && builder.size > 0` 的前置守卫。差异点（分隔符、大小写、首字符）显式参数化，不引入额外分支

### [轻微][存量] #12 README 未说明 `CaseFormat` 对连续大写的拆分规则与不可逆性

- **位置**：`f_util/README.md:8-46`（CaseFormat 段落）；实现 `f_util/src/CaseFormat.cj:87-89`、`f_util/src/CaseFormat.cj:115-117`
- **来源**：存量
- **判据**：review-checklist §13（限制条件缺失）+ §10（语义与文档不符）
- **证据**：静态确定 —— `isDelimiter` 对 Pascal/Camel 源只判断 `ch.isAsciiUpperCase()`，因此 `"HTTPServer"` 会得到 `h_t_t_p_server`（每个大写字母都被当成一个分隔点），且 `Pascal → LowerUnderScore → Pascal` 不能还原。README 只写「六种风格互相转换」，示例全是单字母边界的规范写法
- **描述**：`f_orm` 宏用它把类名/字段名转列名，缩写命名（`URLPath`、`IDCard`）会生成 `u_r_l_path`、`i_d_card` 这类意外列名，且没有报错路径。文档不提示，使用者只会把它当 bug 反复反馈
- **建议**：README 补一句限制（连续大写按逐字母拆分、转换不可逆）；若要支持缩写，属于行为变更，需要单独条目 + 回归用例（现有 `CaseFormat_test.cj` 只覆盖规范命名）

### [轻微][存量] #13 `CaseFormat` / `DiffieHellmanKeyExchanger` 未显式声明 `public`，却被 README 当作对外能力

- **位置**：`f_util/src/CaseFormat.cj:20`（`abstract sealed class CaseFormat`）、`f_util/src/DiffieHellmanKeyExchanger.cj:83`；文档 `f_util/README.md:8-46`、`f_util/README.md:662-717`、`f_util/cjpm.toml:14`（description 列了「命名风格转换」）
- **来源**：存量
- **判据**：review-checklist 硬原则一配套的「可见性建议」；语言规则见 `cangjie_docs/docs/dev-guide/source_zh_cn/package/toplevel_access.md:17-21`（其他顶层声明默认修饰符为 `internal`）
- **证据**：待确认 —— 按该文档默认 `internal` 只在包及子包可见，而 `f_orm/src/macros/QueryMappersGenerator.cj:23` 跨模块 `import fountain::f_util.CaseFormat` 并在 `:118`/`:401`/`:443` 使用；两者不可能同时成立。缺的信息：本项目实际使用的 cjc 版本对顶层声明默认可见性的判定（`f_util/cjpm.toml` 声明 `cjc-version = "1.2.0"`）
- **描述**：这不是死代码（`CaseFormat` 被 `f_orm` 与测试使用），而是可见性表达不明确：README 把 `CaseFormat`、`DiffieHellmanKeyExchanger`（含它的 `public open key`）当模块能力展示，源码却不带 `public`。若默认确实是 `internal`，下游项目无法使用，README 与 `cjpm.toml` 的 description 都在承诺不存在的能力；若默认是 `public`，则应显式写出，避免跨 SDK 版本行为变化
- **建议**：给这两个顶层类型补 `public`（与 `f_base.StringGenerator`、`UInt128` 等对外类型的写法一致），或在 README 中把 `CaseFormat` 标为模块内部工具。不要按死代码处理，也不要直接删 README 段落，先确认下游依赖

<!-- 第 2 部分 -->

### [严重][存量] #1 `cityHash` 三种长度全都不可用：0–15 字节越界崩溃、16–127 字节只读首尾 24 字节、≥128 字节死循环后越界

- **位置**：`f_util/src/CityHash.cj:34-39`（短输入直接进 `weakHashLen32WithSeeds`）、`176-211`（该函数在 `184-202` 读 `offset + len - 8` / `offset + 8`）、`74-96`（尾部循环）、`132-139`（`fetch64` 无边界检查）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界 / 空集合未处理」、§4「无界循环」
- **证据**：静态确定 —— 三条都能只读代码判定：
  1. `len < 16`：走 `weakHashLen32WithSeeds(data, 0, len, …)`。`len < 8` 时 `186` 行算 `offset + len - 8 < 0`；`8 ≤ len < 16` 时先过 `len <= 16` 分支，随后 `201-202` 无条件 `fetch64(bytes, offset)` 与 `fetch64(bytes, offset + 8)`，后者读 `bytes[8..16]`，对 8–15 字节的数组越界。`fetch64` 里 `bytes[offset + i]` 没有任何检查 ⇒ `IndexOutOfBoundsException`。即 `cityHash("abc")`、`cityHash("12345678")` 必崩。
  2. `16 ≤ len < 128`：只调一次 `weakHashLen32WithSeeds(..., len, k0, k1)`，它只读 `offset+0..8`、`offset+8..16`、`offset+len-16..len-8`、`offset+len-8..len` 四处。`len ≥ 24` 时区间 `[16, len-16)` 的字节完全不参与运算 ⇒ 两个只有中间字节不同的输入必然同哈希（例如两个 100 字节、首 8/尾 8 字节相同的串）。
  3. `len ≥ 128`：`78` 行 `let remaining = len - pos`，`80` 行 `while (remaining > 0)`，循环体（`80-94`）只改 `tailOffset`、从不改 `remaining` ⇒ 死循环；`tailOffset` 每轮至少 +1、`88/90` 行读 `tailOffset + chunkSize - 16`，很快就会越过数组末尾 ⇒ 实际表现是先跑若干轮再抛越界（若数据足够长则表现为长时间空转）。
- **描述**：`cityHash` 是 `public` 顶层函数（三个重载：`String` / `Array<UInt8>` / 泛型 `T <: ToString`），仓内目前没有任何调用点（已全仓搜索 `cityHash`，只有定义处与 cjo 符号），属于对外 API 的潜伏崩溃点；任何下游拿它算短串就会挂。除崩溃外，16–127 字节的碰撞面会让它作为哈希键（去重、分片）直接失效。
- **建议**：不要在这份实现上做局部修补。按 CityHash 原始定义重写长度分派（`HashLen0to16` / `17to32` / `33to64` / `>64` 四个分支，每个分支显式检查可用字节数），或者直接用项目里已有、且有黄金值用例的 FNV / murmur 替代。`fetch64` 至少加 `offset + 8 <= bytes.size` 断言；`while (remaining > 0)` 改成 `while (tailOffset < len)` 并把 `chunkSize` 上限夹到剩余长度。必须补 `0/1/7/8/15/16/23/24/32/127/128/129` 长度的用例，否则修了也无人守。

### [严重][存量] #2 `murmurHash` 分块循环上界写错 + `tailLen == 8` 二次混合：≥32 字节的输入大部分字节不参与哈希

- **位置**：`f_util/src/MurmurHash3X128.cj:30`（`nblocks = len / 16`）、`39`（`for (offset in 0..nblocks : 16)`）、`71-72`（`tailStart = nblocks * 16`）、`77-108`（尾部处理，`97` 的 `else if (tailLen > 0)`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「边界差一 / 契约与实现不符」、§6.4「重复消费/漏消费」
- **证据**：静态确定 —— 官方区间语义：`start..end : step` 是左闭右开、`step` 为步长（`cangjie-docs/docs/dev-guide/source_zh_cn/basic_data_type/range.md:22-23`）。于是：
  - `offset ∈ {0, 16, 32, …} ∩ [0, nblocks)`。`len = 32 ⇒ nblocks = 2`，只有 `offset = 0` 一轮，`tailStart = 32`、`tailLen = 0` ⇒ 字节 `[16, 32)` 从未被哈希；`len = 48` 只哈希 `[0,16)`，`[16,48)` 全丢；`len = 4096 ⇒ nblocks = 256`，只有 `offset = 0,16,…,240` 共 16 轮，`[256, 4096)` 全丢。任何 `len ≥ 32` 的输入都至少丢 16 字节，长输入丢绝大部分。
  - `tailLen == 8`（即 `len % 16 == 8`）：先走 `77` 的 `tailLen >= 8` 分支读 8 字节并混入 `h1`，随后 `97` 的 `else if (tailLen > 0)` 成立（8 > 0），把同一批 8 字节重新组装成 `k1_tail` 再混一次 ⇒ `h1` 被重复异或。这与标准 MurmurHash3 x64_128 的 `case 8:` 语义不符。
- **描述**：`murmurHash` 是 `public`，仓内有真实调用：`f_codec/src/default/DefaultCodec.cj:87/109/121/182` 用它做"类型限定名 → 类型 ID"的注册与反查键，`fdbm/src/route/algorithms.cj:225/282` 用它做分片。类型名 32–47 字节时后 16 字节被忽略 ⇒ 两个只在第 16 字节之后不同的类型名会得到相同键，反序列化会按错误的 creator 构造对象（**数据错乱**，不是简单碰撞）；注意 `DefaultCodec.cj:185-187` 的注释明确把碰撞当成"128 位哈希理论碰撞、概率极低，暂不处理"，而本实现让它变成"改掉第 17 个字节就碰撞"的结构性碰撞。分片侧表现为长 key 的分布退化（可接受，但会掩盖真实倾斜）。
- **建议**：块循环改成 `for (i in 0..nblocks) { let offset = i * 16 … }`（或 `for (offset in 0..(nblocks*16) : 16)`），尾部按 `tailLen` 精确分支（`>= 16` 不应出现；`> 8` 处理 `k2`，`== 8` 只处理 `k1`，`1..7` 处理 `k1` 的部分字节），并删掉 `97` 的 `else if` 让 `8` 不再落进 `k1` 部分分支。补黄金值用例：至少 `0/1/7/8/9/15/16/17/31/32/33/48/127/128/4096` 长度，与独立的 Python/`murmur3` 参考实现对拍。
- **相关**：`39-43` 每 16 字节 `data[offset..offset+16]` 分配一个切片，再 `readLittleEndian`，见「优化可行性方案 O1」。

### [严重][存量] #3 `IdMaker` 的位布局与时间戳策略都错了：同毫秒多实例生成完全相同的 ID

- **位置**：`f_util/src/IdMaker.cj:26`（`startMillis` 只在构造时取一次）、`28-33`（`hostSerial << 53`、`startMillis << 12`）、`40-42`（`nextInt64` 只 `fetchAdd(1)`，不刷新时间、不检查序号溢出）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 边界」、§12.1「共享可变状态」
- **证据**：静态确定 ——
  1. **ID = 构造时刻 + 自增计数**。`startMillis` 是 `private let`，只在构造时求值；`nextInt64()` 永远返回 `base + n`（`base = serial<<53 | startMillis<<12`）。两个在同一毫秒内构造的 `IdMaker`（同 serial）得到同一个 `base`，第一个 `nextInt64()` 都返回 `base` ⇒ **主键冲突**。
  2. 该模式在仓内有真实触发路径：`fdbm/src/execute/executors.cj:898` 在**需要补分区列值的每条 INSERT** 上都会调 `IdMakers.forTable(...)`，`fdbm/src/idmaker/IdMakers.cj:87` 每次都 `new SnowflakeIdGenerator(serial)` → `new IdMaker(...)`。同一毫秒内的 N 条这类 INSERT 会拿到 N 个相同 ID。
  3. **位布局与雪花算法相反**：`hostSerial << 53` 把 10 位机器号放在最高位，`startMillis << 12` 把 41 位时间戳放在其下。时间戳不是最高有效字段 ⇒ 不同节点生成的 ID 按数值排序时先按机器号分组、再按时间（且时间还是"启动时刻"），跨节点完全不具备趋势递增/索引局部性，与 `docs/speech/speech.md:4731` 的「10bit主机号+41bit毫秒+12bit序号」描述也不一致。
  4. **12 位序号无溢出保护**：`fetchAdd` 单调加到 4096 后进位污染时间戳字段，此后 ID 里编码的时间不再对应任何真实时刻；`nextInt64` 也没有"同毫秒超过 4096 就等到下一毫秒"的分支。
- **描述**：`IdMaker` 被 fdbm 当作 snowflake 主键生成器（`SnowflakeIdGenerator`）。当前实现同时丢了"跨实例唯一"和"按时间有序"两个核心契约，重复主键会在 ORM 层表现为插入失败或覆盖；位布局错误会让按主键分页/排序的查询失真。
- **建议**：改成标准 snowflake：`((nowMs - epoch) << 22) | (serial << 12) | seq`；`nextInt64` 内部用 `synchronized`/CAS 维护 `(lastMs, seq)`：同毫秒 `seq++`（到 4095 自旋到下一毫秒），新毫秒重置 `seq=0`；并且 `IdMaker` 必须是**进程级单例**（按 serial 缓存），不能每条语句新建。补用例：同毫秒构造两个实例各取 1 个 ID 必须不同；同实例连取 5000 个必须单调且严格递增；跨"毫秒回拨"场景不得回退。

### [严重][存量] #4 `DiffieHellmanKeyExchanger` 的共享密钥计算不成立：先算完整 `g^ab` 再取模，指数是 63 位随机数

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:97-99`（`middle` = `(Decimal(BigInt(g)) ** ab_).toBigInt() % BigInt(p)`）、`84`（`protected var ab_ = random()`）、`100-102`（`random()` = `ThreadLocalRandom.current.nextInt64()`）、`91-95`（`key`）、`78-80`（`finish`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性」、§5「按输入规模不可行的物化」
- **证据**：静态确定（"不可能正确"，具体失败形态需实测）—— 协议要求算 `g^ab mod p`，实现却先算完整的 `g^ab`：
  - `g` 由 16 个随机字节组成（`semi` 里 `randomBytes(bytes: 16)`），量级 ≈ 2^127；`ab_` 是 `Int64` 随机数，量级可达 2^63。精确幂的位数 ≈ `127 × 2^63 ≈ 2^70` bit（约 10^20 字节），无论用哪种表示都不可能在内存里完成 ⇒ 要么 OOM/长时间卡死，要么依赖 `Decimal` 舍入。
  - `Decimal` 是"任意精度十进制，**允许操作过程指定结果精度及舍入规则**"（`stdlib/doc/libs/std/math_numeric/math_numeric_package_overview.md:41`）；`operator **（Int64）` 的文档只对"指数为负值且结果为无限小数"明确写"默认采用 IEEE 754-2019 decimal128 对结果进行舍入"（同目录 `math_numeric_package_structs.md:4904-4914`），正指数在默认上下文下是否精确展开**待确认**。但两种可能都不可用：按上下文精度舍入 ⇒ 128 位底数的 63 位次幂只剩 38 位有效数字，`% p` 与真实模幂无关；精确展开 ⇒ 结果位数 ≈ `127 × 2^63 ≈ 2^70` bit，必然 OOM/长时间卡死。无论哪种，Alice 算 `B^a`、Bob 算 `A^b` 都拿不到同一个值（失败是静默的：双方都得到一个非 `None` 的字符串）。
  - `nextInt64()` 的文档只写"获取一个 Int64 类型的伪随机数"（`stdlib/doc/libs/std/random/random_package_api/random_package_classes.md:733-744`），未限定非负；若取到负值，`Decimal ** 负数` 是小数，`.toBigInt()` 截断后基本为 0 ⇒ `middle` 返回 0（`0 % p == 0`）。此子项 `待确认`（需要实测 `nextInt64` 的取值范围）。
  - `g`、`p` 是随机字节而不是大素数/生成元，`p` 非素数时 `mod p` 的乘法群含零因子、`g` 也不保证是生成元 ⇒ 即使幂算对，协议也没有类注释（`22-35`）宣称的离散对数安全性。
- **描述**：这是"看起来实现了 DH、实际算不出正确共享密钥"的典型形态：接口签名完整、注释写了 7 步协议、`key()` 返回 `String`、`finish()` 返回 `BigInt`，没有任何错误路径。下游若把它当密钥交换用，会得到一个双方不一致的"密钥"，后续对称加密全部解不开（或退化成固定值）。
- **建议**：用 `BigInt` 的模幂（若标准库没有 `modPow`，先实现平方-乘 + 模约减）替换 `Decimal **`；`p`、`g` 改为固定 RFC 3526 素数群/生成元常量，私钥改用 `BigInt(true, 2048, rand: SecureRandom())` 这类接口生成真正的随机大整数（`BigInt` 的 `sign=true` 表示非负，见 `math_numeric_package_structs.md:160-178`，所以现有 `BigInt(true, g)` 至少符号是对的，问题在指数与模幂）。`middle` 对 `g ≤ 1 || g ≥ p` 做校验。若短期内不打算修，至少把类注释改成 `@Deprecated` 并注明"不可用于安全用途"，避免下游误用。

### [严重][存量] #5 `DiffieHellmanKeyExchangerServer.key`：对端可控的 `m` 使 `while (result == "0")` 永不退出

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:64-71`（`var result = "0"; while (result == '0') { ab_ = 0; result = super.key(m, p) }`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「无界循环 / 外部输入未校验」、§12.1「有界性」
- **证据**：静态确定 —— `super.key(m, p)` 返回 `middle(m, p).toString(radix: 36)`，`middle` 是 `m^ab mod p`。若对端传入 `m = p` 或 `m = 0`（`m` 是 `Array<Byte>`，完全由对端控制），则对任意 `ab > 0` 都有 `m^ab ≡ 0 (mod p)` ⇒ `result` 恒为 `"0"`；循环体只重置 `ab_`（重新随机）并重算，`m`/`p` 不变 ⇒ **死循环**，请求线程 CPU 100% 且永不返回。`m` 是 16 字节随机数时 `m % p == 0` 的概率虽低，但攻击者可以直接发 `m = p` 或 `m = 0`。
- **描述**：这是可被单个报文触发的 CPU DoS；同时 `p` 由对端给出，若 `p` 为 0 则 `% BigInt(0)` 抛异常（错误路径未处理）。同一函数里的 `ab_ = 0` 还会破坏实例状态（正在并发的 `finish()` 会踩到被清零的 `ab_`）。
- **建议**：删掉"结果为 0 就重试"的循环，改成对 `m` 做范围校验：`1 < m < p-1`，否则直接抛明确的协议异常并记录；`ab_` 改为 `let`/不可变（每次 `key` 用局部私钥），不要在多线程间共享可变字段。补用例：`m = p`、`m = 0`、`p = 0` 必须在有限时间内返回错误。

### [一般][存量] #6 `PathPattern.compile` 不走 `pretreat`：`{*name}`、`***`、连续 `/` 只在 `compileIfAbsent` 生效

- **位置**：`f_util/src/PathPattern.cj:101-103`（`compile(pattern)`）、`124-127`（`compile<T>(pattern, data)`）、`114-122`（`pretreat` 里的 `{*x}` / `***` / `//` 归一）、`153-156`（只有 `compileIfAbsent` 调 `pretreat`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§13（类注释即契约）、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 类注释承诺 `{*...}` 等价于 `/**/{...}`（`PathPattern.cj:40`）、多处 `//` 合并（`28`）。但 `pretreat` 只被 `compileIfAbsent` 调用（`154`）；`compile(pattern)` 与 `compile(pattern, data)` 直接 `parts(pattern, true)`。于是：
  - `compile("/a/{*rest}")` 不走 `^\{[a-zA-Z_]…}$` 分支（`{` 后是 `*`），落到 `714` 的复杂节点分支，`ComplexPathNode.matches` 对 `{*rest}` 的静态片段是空串（见 `888-914`）⇒ 等价于"匹配任意**单级**路径"，而注释承诺的是多级；
  - `compile("/a//b")` 注册一个空段节点，而 `matches()` 会先 `trimRedundantSlash`（`477-479`）把 `/a//b` 归一成 `/a/b` ⇒ 这条路由永远匹配不上；
  - `compile("/a/***/b")` 里的 `***` 不会被折叠成 `**`（`117`）。
  `fleet/src/server/FleetStore.cj:93` 与 `:113` 用的正是 `compile(pattern, …)`（MQ 主题模式由客户端给），所以这不是纯理论问题。
- **建议**：把 `pretreat` 收进 `doCompile` 的第一行（所有入口都归一），或让 `compile` 两个重载先 `let p = pretreat(pattern)` 再传下去；同时把 `trimRedundantSlash` 的 `replace("//","/")` 改成循环到不再变化（`"///"` 一次替换后仍是 `"//"`，见 `105`）。

### [一般][存量] #7 三处"同名注册"都静默覆盖，没有一条按基线要求启动失败

- **位置**：`f_util/src/PathPattern.cj:659-667`（`createPlaceholderRegexNodeIfAbsent` 以**变量名**为键，同名不同正则直接复用第一个节点）、`f_util/src/Mediator.cj:22-24`（`colleagues[colleague.name] = colleague`）、`f_util/src/StrategyPattern.cj:46-54`（`strategies[strategy.name] = strategy`，含批量重载）
- **来源**：存量（快照模式无基线可比）
- **判据**：`fountain-baseline.md` §4「同名注册（扩展 / 路由 / 插件）：启动直接失败，不做隐式优先级；后者静默覆盖前者 = 违规」；review-checklist §12.1「检查-然后-写入」
- **证据**：静态确定 —— 官方文档：`HashMap` 的 `[]=` 运算符"如果键存在，新 value 覆盖旧 value"（`stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:6197-6220`），而 `HashMap.add` 才是重复键抛异常的语义。三处都用了 `[]=`，所以：
  - `PathPattern`：`/x/{id:\d+}` 与 `/x/{id:[a-z]+}` 注册到同一父节点时，第二次 `regexPlaceholderPathNodes.get("id")` 命中，**新正则被丢弃**，第二条路由永远按第一条的正则匹配（既不报错也不生效）；
  - `Mediator` / `Strategies`：后注册的同事/策略悄悄替换先注册的，启动日志里没有任何痕迹。
- **描述**：路由/插件表是"配错就会把请求交给错误实现"的地方，静默覆盖把配置错误变成了运行期行为漂移，排查只能靠读代码。这类问题在 f_mvc 的路由装配期尤其危险（多个 Controller 可能声明同名占位符）。
- **建议**：三处都改成 `addIfAbsent` + 存在即抛带上下文的异常（`PathPattern` 的异常里带上两条 pattern 文本与变量名；`Mediator`/`Strategies` 带上 name）。若确实需要"热替换"语义，就显式提供 `replace(...)` 并在 README 写明，不要复用 `register`。

### [一般][存量] #8 `PathPattern` 同层多个候选节点的命中结果由 `HashMap` 遍历顺序决定，与类注释的优先级表不符

- **位置**：`f_util/src/PathPattern.cj:556-581`（`getComplexNode` 取 `complexPathNodes.values()` 第一个命中）、`582-608`（`getRegexPlaceholderNode`）、`627-634`（`getRegexNode`）、`609-626`（`getPlaceholderNode`）；优先级声明在 `42`，`get()` 的尝试顺序在 `254-358`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性（非确定性）」
- **证据**：静态确定 —— 官方文档明确"`HashMap` 并不保证按插入元素的顺序排列，因此遍历的顺序和插入的顺序可能不同"（`cangjie-docs/docs/dev-guide/source_zh_cn/collections/collection_hashmap.md:50`）。四个候选容器都是 `HashMap`（`506-510`），取值都是 `for (n in …values()) { if (n.matches(value)) return n }`，即"谁先被遍历到谁赢"。同时 `get()` 的实际尝试顺序是 精确 → `{name:re}` → `{name}` → 正则/通配 → 复杂段 → `*` → `**`（`256-324`），而注释写的是 `a>b=c=d>e=f=g>h`（`42`）——`{name}`（f）被排在 `*`/`?`/正则（b/c/d）之前，与注释相反。
- **描述**：同一层注册 `/api/{id:\d+}` 和 `/api/{name:\w+}` 时，"123" 同时命中两者，最终选中哪个由哈希顺序决定；不同进程、不同插入顺序、不同 SDK 版本都可能给出不同结果。对 MVC 路由来说这是"同样的代码在不同部署上命中不同 Controller"级别的不可复现缺陷。
- **建议**：候选节点改为有序结构（`ArrayList` 按注册顺序，或显式 `priority: Int64` 排序，同优先级按 pattern 字典序），并在 `get()` 之前按注释的优先级表定序；若确定要保留 `HashMap`，就必须在 `matches` 结果里返回"全部候选"由上层决定，不能靠遍历顺序。补用例：同层注册两个可同时命中的正则，断言多次运行/不同插入顺序下命中一致。

### [一般][存量] #9 `RegexPathNode` 的锚点逻辑写反：不以 `^` 开头的正则只做前缀匹配

- **位置**：`f_util/src/PathPattern.cj:823-833`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」
- **证据**：静态确定 ——
  ```cangjie
  if (!name.startsWith("^")) { prefix = "^" }
  else if (!name.endsWith("$")) { suffix = "$" }
  ```
  `else if` 挂在前一个 `if` 上：正则**不以 `^` 开头**时只补 `^`，永远不补 `$`；只有"已经以 `^` 开头且不以 `$` 结尾"才补 `$`。于是 `{id:\d+}` 编译成 `^(\d+)`，`regex.matches("123abc")` 为真 ⇒ 路径段 `"123abc"` 能匹配数值占位符，之后 `extractParsableVariableInPath<Int64>` 才失败（错误被推到参数绑定阶段，且错误信息指向解析而非路由）。
- **描述**：路由正则的语义应当是"整段匹配"（同类工具的 `[]` 也是整段），当前实现让正则成为前缀匹配，等于放宽了所有 `{name:regex}` 路由的约束；对把正则当校验用的调用方（如时间范围、枚举 `{direction:(before|after)}`）会放行 `beforeX`、`123abc` 这类带尾缀的输入，真正拒绝要到后续参数解析/业务校验才发生。
- **建议**：改成两条独立判断：`if (!name.startsWith("^")) { prefix = "^" }`、`if (!name.endsWith("$")) { suffix = "$" }`；补用例：`{id:\d+}` 必须拒绝 `123abc`、`{direction:(before|after)}` 必须拒绝 `beforeX`。

### [一般][存量] #10 `PathPattern` 的匹配路径会写共享 `patterns`，且读在锁外

- **位置**：`f_util/src/PathPattern.cj:48-50`（`mutex` / `patterns` / `originPatterns`）、`68-99`（`getPathNode`：`90` 行锁外 `patterns.get(len)`，`69-89` 的 `populateNode` 在锁内 `add` / 赋值）、`477-491`（`get` 从 `matches()` / `data()` 进入）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 迭代与修改并发」、§12.2「锁粒度」
- **证据**：静态确定（竞态窗口）+ 需实测（是否真的产生错误结果）—— 共享路径是实打实的：
  - `f_mvc/src/HttpRequestDistributorImpl.cj:19` 一个进程级 `private let patterns = PathPattern()`，`:43-45` 的 `getHandler(path)` 在每个请求线程上跑 `patterns.data<…>(path)`；
  - `fleet/src/server/FleetStore.cj:89-93` 用 `ConcurrentHashMap<MessageID, PathPattern>` 保存每个订阅的匹配器，`notify`（`81-87`）对每个 `PathPattern` 调 `data<T>(path)`；只要 MQ 投递线程多于一个，这些调用就是并发的（`ConcurrentHashMap` 只保证 map 本身，不保证 value 的线程安全）。
  `data()` → `get()` → `getPathNode(parts.size)`；当请求的段数大于当前 `patterns.size` 时，`populateNode`（`70-78`）会在锁内 `patterns.add(NonePathNode.INSTANCE)` 并写入新 `PathNode`——也就是说**匹配（读）路径会改共享容器**。而 `90` 行的 `patterns.get(len)` 在 `synchronized` 之外，与另一线程的 `add` 构成对 `ArrayList` 内部数组/长度的无同步读写。
- **描述**：`Mutex` 只包住了写，没包住读；`ArrayList` 不是线程安全容器（`ArrayList.get` 有边界检查，但并发扩容时的读没有可见性保证）。后果的严重程度取决于实现细节（可能只是读到 `None` 后多建一个节点，也可能抛异常/丢节点），但"每请求在全局锁内扩容 + 锁外读同一容器"本身已经同时是正确性缺陷和锁粒度问题：冷启动/首次访问长路径时，所有请求线程在这把实例锁上串行，且扩容临界区里还包含 `originPatterns` 回放（对每个 `**` 模式重跑 `this.parts` + 正则替换，见 `70-86`）。
- **建议**：分成读写两条路径：匹配时只读（`patterns` 用不可变数组 + 原子替换发布），`getPathNode` 未命中就直接返回 `None`，不要在匹配里创建节点；`compile` 阶段一次性把所有可能长度预热好（或用 `ConcurrentHashMap<Int64, PathNode>` 做长度索引，`addIfAbsent` 后发布）。若保留 `Mutex`，`getPathNode` 的读也必须进锁，并补一条并发用例：8 线程同时 `matches` 不同深度路径 + 另一线程 `compile`，断言无异常且路由结果稳定。

### [一般][存量] #11 `State.startup` 是无上限递归，状态机成环即栈溢出

- **位置**：`f_util/src/StatePattern.cj:43-52`（`startup` 里 `this.exec().startup()`）；`exec` 声明在 `35`，`continues` 默认 `true` 在 `27-31`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §4「无界递归 / 间接递归」
- **证据**：静态确定（递归结构）+ 待确认（实际深度取决于使用者实现）—— `startup` 每帧调用 `exec()` 取下一个状态再递归，没有任何深度计数、访问集合或环检测；`continues` 默认返回 `true`，实现者只要让某个状态 `exec()` 返回自身（状态机里非常常见）就是无限递归。仓颉不保证尾调用优化（checklist §4 明示），因此即使写成尾递归也不能作为保险。
- **描述**：这是框架骨架 API（仓内暂无实现类），一旦被业务状态机使用，误配一个自环就是 `StackOverflowError` 级崩溃，且栈深度由状态链长度决定、不受控。
- **建议**：改成循环 + 显式上限：`var s: State<D> = this; var depth = 0; while (s.continues) { if (++depth > MAX) { throw IllegalStateException(...) }; s = s.exec() }`；`MAX` 可用常量或配置；`exec` 返回 `State<D>` 而不是泛型 `S`（见 #19 的类型参数遮蔽）。

### [一般][存量] #12 `ValidationResponsibility.execute` 的默认空实现让"忘记覆盖"静默通过

- **位置**：`f_util/src/ResposibilityChain.cj:40-42`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §3「接口给了默认空实现，实现类忘记覆盖」、§11「静默失效」
- **证据**：静态确定 —— `public interface ValidationResponsibility<C, A> <: Responsibility<C, A, Unit> { func execute(arg: A): Unit {} }`：`execute` 给了空函数体，`ResponsibilityChain.executeAll`（`78-82`）只调 `check` 与 `execute`，返回 `Unit`、不检查任何结果。一个只实现了 `check` 的校验策略会稳定地"校验通过"，链式校验整体静默失效。
- **描述**：校验链的失败模式应当是"漏实现 → 编译报错"而不是"漏实现 → 全部放行"。当前形态把一个编译期可发现的问题推到了运行期，且没有任何日志/返回值能让调用方察觉。
- **建议**：删掉默认实现（强制实现类提供 `execute`）；如果确实要支持"只检查不执行"的策略，就提供显式的 `NoOpValidation` 类并让使用者主动选择。

### [一般][存量] #13 `Factory` / `Mediator` 用 `HashMap` 下标取缺失键：抛 `NoneValueException`，没有任何上下文

- **位置**：`f_util/src/Factory.cj:49-54`（`producers[TypeInfo.of<T>()]`）、`f_util/src/Mediator.cj:25-27`（`colleagues[arg.name]`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「错误处理缺失 / 静默或误导」、§10「错误处理」
- **证据**：静态确定 —— 官方文档：`HashMap` 的 `operator [](key)` 在键不存在时抛 `NoneValueException`（`stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:6147-6165`）。两处都直接把下标结果当值用：未 `assemble`/未 `register` 的类型或名字会得到一个不带键名、不带注册表内容的 `NoneValueException`，和"值本身是 `None`"的错误无法区分。同目录的 `Strategies.execute`（`59-64`）已经用 `match (strategies.get(name))` + `IllegalAccessException("there is no strategy…")` 做了正确示范，三处口径不一致。
- **描述**：工厂/中介者是启动装配期最容易"漏注册"的地方；当前失败信息无法定位是哪个类型/哪个名字漏了，排查成本高。`Factory.produce` 里 `producers[...]` 的取值与 `convert` 的 `TypeNotMatchException` 是两种完全不同的失败，调用方只能靠堆栈区分。
- **建议**：统一改成 `match (map.get(key)) { case Some(v) => …; case None => throw IllegalAccessException("… not assembled/registered: ${key}") }`；`Factory` 里把 `TypeInfo.of<T>()` 提到局部变量复用。

### [轻微][存量] #14 死代码清单（CityHash / PathPattern）

- **位置**：
  - `f_util/src/CityHash.cj:158-172`（`mur` 全文件无调用）、`151-154`（`rotate32` 只被 `mur` 调用）、`119`（`hashLen16` 里 `let mix = …` 算完不用）
  - `f_util/src/PathPattern.cj:522-536`（`PathNode` 的 5 个 `init` 重载无任何调用点；被用的是 `516` 的 `init()`、`519` 的 `(name, prev)`（各子类 `super(...)` 走它）与 `537` 的私有 6 参 `init`）、`731-733`（`func data(data: Any)` 无调用）、`494-501`（`extend<T> Option<T> where T <: PathNode { func matches(value: String) }` 无调用，`matches(Option<PathNode>)` 走的是 `453-455` 的私有重载）、`959-961`（`Mode.matching()` 无调用）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「无调用者 / 读了不用」；机械动作：`private` 全仓搜、`internal` 本包内搜
- **证据**：静态确定 —— 已逐个符号全仓搜索（`mur(`、`rotate32`、`PathNode(`、`.data(`、`Mode.matching`、`Option<PathNode>` 的 `matches`）：除定义处外零命中。`PathNode` 是 `open class`（无 `public`）⇒ 内部类型，其成员与 `init` 不属于对外契约。
- **描述**：`mur` 是 MurmurHash3 的 32 位混合函数，属于未完成的移植残留；`mix` 白算一次 64 位乘法 + 异或；`PathNode` 的 5 个构造重载与 `data(Any)`、`Option.matches`、`Mode.matching()` 是迭代过程中留下的兼容残留。
- **建议**：删除上述符号；`hashLen16` 直接内联 `return hashLen16Minimal(u, v) ^ UInt64(len)`（或删掉 `hashLen16Minimal` 保留一个）。

### [轻微][存量] #15 `CrcGf` 的 Barrett 约减"参考实现"与被测实现同构，无法证伪

- **位置**：`f_util/src/CrcGf.cj:58-75`（`barrettMu` 的 63 步移位减法）与 `f_util/src/CrcGf_test.cj:250-278`（`refBarrettMuLow` 逐行相同的移位减法）、`176-182`（`barrettReduce` 的公式实现）与 `158-173`（`refMod128` 同一套 hi/lo 异或约减）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「近似重复」、§10「可测试性」
- **证据**：静态确定 —— 测试文件开头声明"参考实现独立写在本文件里：不复用 `CrcGf` 的辅助函数，避免生成器自己证明自己"（`CrcGf_test.cj:21-25`），但 `refBarrettMuLow` 与 `barrettMu` 是同一套 `if (bit) { hi ^= 1<<i; lo ^= poly<<i; hi ^= poly>>(64-i); q |= 1<<i }` 的移位减法；`refMod128` 与 `barrettReduce`/`barrettMu` 也共用这套域约减。两者只有在"多项式移位方向/进位处理"上犯**同一种**错误时才会同时出错，测试照样全绿——`crc64HwXz256MatchesSoftwareRegression`（`CrcEngine_test.cj:433-450`）的存在说明历史上已经踩过一次"常量布局错、测试没发现"的坑。
- **描述**：`barrettMu` / `barrettReduce` 是生成式折叠核的数学基础，它们的正确性目前只被"同构实现"验证；`refCrc64Reflected`（`CrcGf_test.cj:29-44`）与 `CrcEngine_test.refUpdate` 是真正的独立参考（逐位、不查表），但那两条只验证表路径，不直接验证 `barrettMu` 的商。
- **建议**：`barrettMu` 的参考值改为"独立来源"：用 `BigInt` 直接算 `x^128 / (x^64 + poly)` 的商，或把已发布的 CRC-64 常量（`x^128 mod P`、`mu`）作为黄金值逐字对照；`barrettReduce` 用 `BigInt` 算 `(hi·2^64 + lo) mod P` 对拍，而不是再写一遍移位减法。

### [轻微][存量] #16 重复逻辑：`hashLen16` / `pretreat` / `Mediator` 与 `Strategies`

- **位置**：`f_util/src/CityHash.cj:117-128`（`hashLen16` 与 `hashLen16Minimal` 逐行相同，只多一次 `^ len`，且各自重算 `shiftMix(xorResult * k1) * k1`）、`f_util/src/PathPattern.cj:105` 与 `119`（`pretreat` 和 `trimRedundantSlash` 各做一次 `replace("//","/")`，`pretreat` 先替换再调 `trimRedundantSlash`）、`f_util/src/Mediator.cj:20-28` 与 `f_util/src/StrategyPattern.cj:41-64`（同一套 name→实现 注册表 + 按 name 分派，仅容器类型与异常口径不同）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「只改类型名 / 换控制流 / 近似重复」
- **证据**：静态确定 —— 三组都是"语义相同、实现两份"：
  - `hashLen16` 完全可以写成 `hashLen16Minimal(u, v) ^ UInt64(len)`，现在两处各算一遍 `shiftMix(xor*k1)*k1`；
  - `pretreat` 的 `p.replace("//","/")`（`119`）紧接着 `trimRedundantSlash(p)` 里又做一次（`105`），且单次 `replace` 处理不了 `"///"`；
  - `Mediator.execute` 与 `Strategies.execute` 都是"按 name 从 map 取实现并调用"，但缺失键时一个抛 `NoneValueException`、一个抛 `IllegalAccessException`（见 #13），属重复导致的行为漂移。
- **建议**：`hashLen16` 改为委托；`pretreat` 只保留一次归一（把 `"//"` 合并做成循环直到稳定，放进 `trimRedundantSlash`）；`Mediator` 收敛为 `Strategies` 的一层薄封装，或明确二者分工（Mediator 负责"同事"协作、Strategies 负责"选一个"）并在类注释写清差异，同时统一异常。
- **说明**：`CrcGf_test.cj:21-25` 与 `CrcEngine_test.cj:37-69` 各有一份逐位 CRC 参考实现，文件里已注明"不复用被测辅助函数，避免生成器自己证明自己"，属刻意独立，不计入重复。

### [轻微][存量] #17 未使用的 `import`（多处，证据等级"待确认"）

- **位置**：`f_util/src/MurmurHash3X128.cj:19-23`（`std.convert.*` 无可疑用法；`stdx.encoding.hex.*`、`fountain::f_data.DataParsable`、`fountain::f_util.exception.HashException` 全文件无引用，尤其 `HashException` 已 import 却一次都没抛）、`f_util/src/CityHash.cj:18/20`（`std.convert.*`、`fountain::f_data.*` 无引用）、`f_util/src/Factory.cj:20` 与 `f_util/src/StatePattern.cj:19`（`fountain::f_base.TypeInfos` 只 import 未用，两处都只用 `std.reflect.TypeInfo`）、`f_util/src/StrategyPattern.cj:18`（`ArrayList` 未用）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：待确认 —— 逐个符号在本文件内搜索无引用；但仓颉的扩展方法可能靠 import 引入（`UInt64.readLittleEndian`、`Int64.toUInt`），未跑编译器的 unused 告警，因此不做"可删"结论，只记录。
- **描述**：`MurmurHash3X128.cj` 里 `HashException` 的"幽灵 import"值得注意：它暗示作者原本打算做入参/长度校验，但实现里没有任何校验分支。
- **建议**：跑一次 `cjpm build` 看 unused import 告警后统一清理；`MurmurHash3X128.cj` 若确实不需要 `HashException`，删掉 import，若要保留就把"seed 为 0 / 空输入"之类的契约写清。

### [轻微][存量] #18 `CrcEngine_test` 的吞吐用例会留下全局状态，且失败路径不回滚

- **位置**：`f_util/src/CrcEngine_test.cj:344-373`（`Crc64Hw.setNativeEnabled(false)` 后没有 `try/finally`，`370` 的 `@Fail` 会跳过 `367` 的恢复）、`477-524`（`env.setVariable("F_UTIL_CRC_HW", …)` 改写进程环境，`520-523` 有 finally 但其它用例仍可能读到）、`406-425`（每轮 `setNativeEnabled(true)/resetForTest()` 依赖前一轮成功）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §10「可测试性」、§11「资源/状态不对称」
- **证据**：静态确定 —— `throughputCrc64SlicingAtLeastSixtyMegabytesPerSecond` 在 `351` 关闭硬件路径，只有顺序执行到 `367` 才恢复；一旦 `370` 的断言失败，后续所有 CRC-64 用例都会在"硬件被禁用"的状态下运行（对结果正确性影响不大，但会让 `crc64Hw*` 系列全部 SKIP，掩盖真实回归）。`env.setVariable` 修改的是进程级环境变量，与 `Crc64Hw` 的静态开关叠加，用例顺序会改变行为。
- **描述**：测试本身不影响生产，但这类"失败后污染后续用例"的写法会让性能门禁/硬件用例的失败难以定位。
- **建议**：所有 `setNativeEnabled` / `env.setVariable` 都放进 `try { … } finally { 恢复 }`；硬件用例统一用一个 `withNative(bool) { … }` 辅助函数；`Crc64Hw.resetForTest()` 在 `setUp/tearDown`（`@BeforeEach/@AfterEach`）里做，而不是散落在用例中。

### [轻微][存量] #19 注释/命名与实现不符（`semi` 示例、`Mediator` 的类型参数、`matches` 默认值）

- **位置**：`f_util/src/DiffieHellmanKeyExchanger.cj:37-47`（示例 `alice.semi(16)`，但 `54` 的签名是 `semi(gBytes!: Int32 = 16, pBytes!: Int32 = 16)`，命名参数不能按位置传）、`f_util/src/Mediator.cj:20`（`C` 类型参数在类体内零使用，只在 `where` 约束里出现）、`f_util/src/PathPattern.cj:434-441`（注释"不包含路径中的扩展名"，实现 `matches(path)` 调 `matches(path, true)`，即**包含**扩展名）、`f_util/src/StatePattern.cj:43`（`func startup<D>(): D` 遮蔽接口自身的 `D`，`TypeInfo.of<D>()` 打印的是方法类型参数，与外层 `prop data: D` 不是同一符号）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「语义与注释不符」、§10「可读性」
- **证据**：静态确定 —— 四处都能直接对照；`semi` 的命名参数/位置参数规则见 `cangjie-docs/.../function/define_functions.md`（命名参数用 `!` 声明、调用必须带名）。
- **描述**：`startup<D>` 的类型参数遮蔽是四处里唯一有功能风险的：它让 `match (this.data) { case x: D => … }` 的类型判定依赖调用点的推断，而不是接口的 `D`；其余三处是文档/命名瑕疵。
- **建议**：`semi` 示例改成 `alice.semi()` 或 `alice.semi(gBytes: 16, pBytes: 16)`；`Mediator` 去掉未用的 `C`（或把它用在 `execute` 的返回类型上）；`matches` 的注释改成"包含扩展名"；`startup` 去掉方法级 `<D>`，直接用接口的 `D`。

### [轻微][存量] #20 本部分缺少关键用例：`murmurHash` / `cityHash` / `IdMaker` / `DiffieHellman*` 零测试

- **位置**：`f_util/src/MurmurHash3X128.cj:28`、`f_util/src/CityHash.cj:34`、`f_util/src/IdMaker.cj:23`、`f_util/src/DiffieHellmanKeyExchanger.cj:53-113`；对照：CRC/FNV/PathPattern 都有专门 `*_test.cj`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §10「可测试性」；reviewer.md「发现的问题要能回答有什么用例覆盖」
- **证据**：静态确定 —— 本部分 19 个文件里 5 个是测试（`CaseFormat_test` / `CrcEngine_test` / `CrcGf_test` / `Fnv_test` / `PathPattern_test`），全仓 `*_test.cj` 中没有任何 `murmurHash` / `cityHash` / `IdMaker` / `DiffieHellman` 的引用。
- **描述**：`murmurHash` 是 f_codec/fdbm 的运行时依赖，`IdMaker` 是 fdbm 的主键生成器，两者都属于"错了上层只表现为偶发数据异常"的类型；#2、#3 能存活到现在，与"零黄金值用例"直接相关。
- **建议**：优先补三条：`murmurHash` 与独立实现的多长度对拍（含 `len % 16 == 8`、`len ≥ 32`）；`IdMaker` 同毫秒双实例唯一性 + 5000 次单调性；`PathPattern` 同层多正则的确定性（#8）。

<!-- 第 3 部分 -->

### [严重][存量] #1 `time:` 占位符的格式模板恒为单个反引号：`Regex.replaceAll` 把格式串当正则、把反引号当输入

- **位置**：`f_util/src/TextTemplate.cj:169-185`，关键行 `176`（`placeholder[formatStart..formatEnd].trimAscii().regex().replaceAll(...)`，两个实参分别是「一个反引号」和「反斜杠 + 反引号」）；产物消费点 `Value2TimeString.doFormat`（`:311-313`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§10「正确性」
- **证据**：静态确定 ——
  1. `replaceAll` 的接收者是先由**格式串**构造出来的 `Regex`，形参却是 `(input, replacement)`：仓内三处同 API 调用都传「被替换的文本 + 替换值」（`f_app/src/App.cj:400`、`f_orm/src/base/Condition.cj:81`、`f_util/src/PathPattern.cj:66`），`f_regex` 也没有给 `Regex` 加过两参重载（`f_regex/src/ExtendRegex.cj:35-37` 是 `doReplace*`）。所以这里的实际语义是「在字符串 `` ` `` 中把匹配 `format` 的部分换成 `\`` 」。
  2. 当 `format` 不匹配单个反引号（`yyyy-MM-dd`、`HH:mm:ss` 等全部如此），`replaceAll` 原样返回 input，即 **`format` 的值变成 `` ` ``**。随后 `DateTime.format("`")` 只会输出一个反引号（或按模式字面量输出），日期永远不会被格式化。
  3. 反向也坏：`format` 被当成正则编译（`.regex()`），含 `(`, `)`, `*`, `[` 等元字符的日期模板会在这里抛 `RegexException`。
  4. 不带反引号的写法更早失败：README 的写法是 `` time:`FORMAT` ``，而仓库里的演讲材料 `docs/speech/speech.md:3287`（`.worktrees/dbware/` 下同一份）给的示例是 `{time:yyyy/MM/dd}`（无反引号）⇒ 反引号找不到时 `formatStart` 被算成 0、`formatEnd` 为 -1 ⇒ 落到 `:178` 抛 `IllegalArgumentException`。
- **描述**：`time:` 是 README 明确承诺的三类格式化能力之一（`f_util/README.md:437`、类注释 `TextTemplate.cj:39`），当前实现下**任何** `time:` 占位符都不可能输出正确时间：带反引号输出 `` ` ``，不带反引号直接抛异常。同一文件里 `number:` 分支的格式解析是正常的，说明这是 `time:` 分支独有的写法错误（把「转义格式串里的反引号」写成了对正则做替换）。
- **建议**：删掉 `.regex().replaceAll(...)`，改为对 `format` 做纯字符串级转义（把「反斜杠 + 反引号」还原成「反引号」），或直接不做转义、把转义的解释放到 `DateTime.format` 层；同时把 `time:` 分支的 `template[formatEnd - 1]`（见 #15）改回 `placeholder[formatEnd - 1]`。补用例：格式串为 `yyyy-MM-dd`（反引号包裹）时对固定 `DateTime` 断言输出、格式串为 `(yyyy)` 时不抛异常、不写反引号的 `{time:yyyy/MM/dd}` 明确报「必须用反引号包含」而不是落到通用错误。

### [严重][存量] #2 README 与类注释承诺的 `regex:` 占位符在实现里完全不存在

- **位置**：承诺源 `f_util/src/TextTemplate.cj:38-39`、`f_util/README.md:436`；缺失面 `f_util/src/TextTemplate.cj:136-188`（`addPlaceholder` 只识别 `time:` / `number:`）、`:266-277`（`Value2String` 的 4 个实现里没有正则版）、`:115`（只遍历 `[TIME_FORMAT_PREFIX, NUMBER_FORMAT_PREFIX]`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现」、§14.2「README 承诺的功能不存在」、§3「公开契约承诺有行为」
- **证据**：静态确定 —— 全文件搜 `regex:` 只命中两行注释（`:38`、`:51`），`addPlaceholder` 里没有任何以 `regex:` 分支构造的占位符对象；`Value2String` 的封闭子类集合是 `OriginValue2String` / `Value2PlainString` / `Value2TimeString` / `Value2NumberString`（`:270-273` 的 match 也已穷举），不存在「map 中第一个匹配该正则的 key」这条取值路径。
- **描述**：文档写的是「占位符用 `regex:` 开头的表示这是一个正则表达式……用 map 中找到的第一个匹配这个正则表达式的 key 所对应的值替换」。实际行为是把这个串当普通 key 去精确查表：`{regex:user_\d+}` 会走 `Value2PlainString` → `HashMap["regex:user_\\d+"]` → `NoneValueException`（map）或 `TextTemplateException`（对象）。使用者按文档写就是运行期异常，且异常信息指向「字段不存在」，与真实原因（该能力没实现）无关。
- **建议**：二选一，不要留中间态。要能力：给 `Value2String` 加 `Value2RegexString`，在 `addPlaceholder` 里识别 `regex:` 并保存正则，`doFormat` 里遍历 map 的 key 找首个 `matches` 的项（文档已明确「只接收 map」，可以在类型上限定并给出清晰异常）。要下线：删掉 README（中英两版）和类注释里的这两段，并在 CHANGELOG 标注移除。

### [严重][存量] #3 `UInt128.fromBytes` 的长度校验只构造了异常对象、没有 `throw`：任何非 16 字节输入都静默产出错值

- **位置**：`f_util/src/UInt128.cj:59-73`，关键行 `60-62`（`if (bytes.size != 16) { HashException("Invalid bytes length, expected 16 bytes, but it is ...") }`，无 `throw`）；受影响入口 `:32-40`（`tryParse` / `parse`）、`:24`（`DataParsable<UInt128>` 实现）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「错误处理缺失或静默 / 契约与实现不符」、§10「正确性」
- **证据**：静态确定 ——
  1. 花括号里是一个「构造 `HashException` 实例」的表达式语句，结果被丢弃，函数继续往下执行；`HashException` 在仓内**唯一**的使用点就是这一行（全仓 `grep HashException` 只有定义、这行、以及 `MurmurHash3X128.cj:23` 的未使用 import），也不存在「构造即抛」的语法。
  2. 长度 < 16 时循环只填 `bytes.size` 个字节，其余位保持 0：`tryParse("4142")`（2 字节）得到 `0x41420000…0000`，而 `toString()` 给出 32 位十六进制串，看起来完全合法。长度 > 16 时 `:69` 的 `(15 - i) * 8` 变负，被 `UInt64(...)` 包成巨大的移位量，结果取决于移位运算符对超宽移位的定义（`待确认`），但无论哪种都不是「报错」。
  3. 契约侧：`DataParsable.tryParse` 的语义在仓内有明文约定——「不能解析、或数值超出表示范围 → None，与其他类型 `tryParse` 一致」（`f_data/src/base/DataParsable.cj:39-51`）。`UInt128.tryParse` 对非 32 位十六进制输入返回 `Some(错值)`，直接违反该契约。
- **描述**：这是「写好了校验、忘了 throw」的典型形态：`parse("abc")` 不抛、不返回 `None`，而是返回一个永远对不上的 128 位值。`UInt128` 是 `f_codec` 的类型指纹键（`f_codec/src/default/DefaultCodec.cj:45-46,960`）与 `f_jit` 的编译去重键（`f_jit/src/bytecode/Fingerprint.cj:51-81`）；一旦有人用 `Config.getData<UInt128>`（`f_config/src/Config.cj:238` 只要求 `T <: DataParsable<T>`）或手工 `parse` 读一个 8/24 位十六进制串，就会得到静默错键——查不到缓存、误命中都必须靠现象反推。
- **建议**：`HashException(...)` 前补 `throw`；同时把 `fromBytes` 改成只接受 `Array<Byte>` 长度严格等于 16（`tryParse` 里先判 `x.size == 16` 再 `fromBytes`，让「串长不对」走 `None` 而不是异常）。补用例：`tryParse("")`、`tryParse("41")`、`tryParse("41" * 15)`、`tryParse("41" * 17)`、32 位串往返。

### [一般][存量] #4 非十进制数字格式三处错：负数符号丢失、宽度多补 1 位、`X` 的转大写分支永远不执行

- **位置**：`f_util/src/TextTemplate.cj:442-449`（`radix != 10` 分支）；`443`（`BigInt(true, number.reScale(0, …).toBigInt().toBytes())`）、`446`（`"${prefix}${0 * (integer - 1)}${string}"`）；`342-348`（`x`/`X` 分支）、`345`（`if (prefix[0] == b'X')`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§1「恒真恒假分支」；判据依据 README 承诺（`f_util/README.md:443-445`：「`x X` 表示转化成 16 进制」「`+` 对正数前置 +，`(` 对负数用括号包含」）
- **证据**：静态确定 ——
  1. **符号**：`BigInt(sign: Bool, magnitude: Array<Byte>)` 的 `sign=true` 表示非负（第 2 部分 #4 已按 `math_numeric_package_structs.md:160-178` 核实过同一 API）。这里恒传 `true`，且整个 `radix != 10` 分支**完全没有用到 `symbol`**、也没有处理 `prefixPlus` / `enclosedInParentheses`。所以 `-255` 走 `x###` 得到 `0xff` 这类正值输出。
  2. **宽度**：`prefix = "0" + formatter[0..1]` ⇒ `prefix[0]` 恒为 `'0'`，`upperCase` 永远保持 `false`，`X###` 输出小写；同时 `prefix` 是 `"0X"`（大写前缀 + 小写数字），自相矛盾。
  3. **补位**：十进制分支用 `integer - l`（`:423-430`），十六/八进制分支写成 `integer - 1`。`x###`（`integer = 3`）格式化 `255`（`l = 2`）会补 2 个 `0` 得 `0x00ff`（4 位数字），正确值应是 `0x0ff`；只有 `l == 1` 时巧合正确。另外八进制的 `prefix` 是裸 `o`/`O`（`:340`），与 `0x` 的口径也不一致。
- **描述**：三个缺陷同源（该分支是后来补的、没有和十进制分支对齐），会同时影响「负数走十六进制」「定宽十六进制列对齐」「`X` 大写风格」三类输出。定宽输出的典型用法（报文/日志里的定宽十六进制列）会整体右移并在左侧多出 `0`，属于「看起来格式化成功了，但列宽和符号都错」。
- **建议**：符号统一在分支外处理——先按 `symbol` 判断正负，`radix != 10` 时对绝对值取 `toBytes()` 并显式带负号（或按 `enclosedInParentheses` 加括号）；补位改成 `integer - l`；`X` 判定改成 `formatter[0] == b'X'` 并让 `prefix` 与 `upperCase` 共用一个变量。补用例：`x###`/`X###` × `{0, 1, 15, 255, -255}` 十组黄金串。

### [一般][存量] #5 `Value2NumberString` 的空值兜底被写成丢弃的表达式：空串仍会走 `Decimal.parse("")`

- **位置**：`f_util/src/TextTemplate.cj:406-410`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「读了不用 / 不可达语句」、§3「`case None => ()` 当兜底把错误吃掉」的反向形态（兜底写了但没生效）、§11「错误处理缺失」
- **证据**：静态确定 —— 函数返回类型是 `String`，`noneConverter` 是 `?String`，所以 `if (value.isEmpty()) { noneConverter }` 只能是**丢弃取值的表达式语句**（也无法作为隐式返回）；控制流无条件继续到 `:410` 的 `Decimal.parse(value)`。空串进 `Decimal.parse` 必抛解析异常，`noneConverter` 在这条路径上永远不生效。
- **描述**：调用方传 `noneConverter: "-"` 期望「字段为空时输出 `-`」，实际得到一条从 `Decimal.parse` 冒出来的解析异常，且异常信息里没有字段名，排查会指向数字格式而不是空值。
- **建议**：改成 `if (value.isEmpty()) { return noneConverter ?? "" }`（返回类型若要保留 `String`，就用 `??` 给默认值）；顺带给 `Decimal.parse` 包一层 `try`，把非法数字统一转成 `TextTemplateException("field ${getter.placeholder()} is not a number: ${value}")`。

### [一般][存量] #6 进程级模板缓存无容量上限，且 `f_log` / `f_llm` 的真实调用点可能喂运行期拼接的模板串

- **位置**：`f_util/src/TextTemplate.cj:54`（`private static let templates = ConcurrentHashMap<String, TextTemplate>()`）、`:68-75`（`compile` 无条件 `computeIfAbsent`）、`:80-82`（键含模板原文）
- **来源**：存量（快照模式无基线可比；设计文档已把它记为「已知问题」）
- **判据**：review-checklist §5「缓存键无界 / 无界容器」、§7 候选 4「有界化」
- **证据**：静态确定（结构）+ 待确认（增长率）——
  1. 缓存没有容量、TTL、淘汰；每条 value 是 `TextTemplate`，内含 `ArrayList<Value2String>`，其中 `OriginValue2String` 保存 `template[start..end]` 的**副本**（`:94/96`），所以每个条目常驻「模板长度的若干倍」。
  2. 两个真实调用点：`f_log/src/base/Logger.cj:51/62/72/87/95/106/114/125/133/144/152` 每条带参日志都 `TextTemplate.compile(message, prefix: "{", suffix: "}")`；`f_llm/src/agents/AgentTask.cj:232` 用 `promptsTemplate`（来自 agent 配置）编译。日志 message 由调用方拼串（`"req ${id} failed"`）时，模板基数 = 实际日志种类数，随进程运行单调增长且永不回收。
  3. 设计文档已把这条列为「不在本次范围；若后续出现模板串动态生成再单独处理」（`f_util/doc/spec/fix-text-template-cache-key/design.md:61`，Non-Goals 与 Risks 各一处）。也就是说风险成立的前提（动态模板）在 `f_log` 上已经具备，只是没人量过规模。
- **描述**：这是「缓存把不可信基数变成常驻内存」的形态：失控时表现为 RSS 随运行时间上升、GC 后不回落，且没有任何拒绝路径（没有上限判断、没有告警）。第 1 部分已把它放进待验证假设 #4，本部分确认代码位置与增长机制，作为缺陷记录（不是性能猜测）。
- **建议**：给缓存加有界化：容量上限 + LRU（`f_cache.HeapCache` 已在 `f_regex/src/RegexFromString.cj:20` 用于正则缓存，同一套设施可复用），或改用「弱引用键 + 定时清理」；同时给 `compile` 加一条长度上限（超长模板不进缓存，直接编译一次用完即弃）。验收口径：跑 24h 日志压测，断言条目数与 RSS 达稳态。

### [一般][存量] #7 空 `prefix` / `suffix` 让 `doCompile` 进入死循环并向 `compiled` 无限累加

- **位置**：`f_util/src/TextTemplate.cj:83-127`（循环体 `92-126`），入口 `:65-67`（`compile(template, placeholder: "")` 会把空串同时当 prefix/suffix）、`:68-75`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §5「无界增长导致 OOM」、§11「无界循环 / 外部输入未校验」
- **证据**：静态确定 —— 取 `prefix = suffix = ""`、`template` 非空（`templateLength = n > 0`）：`prefixLength = suffixLength = 0`；`end = indexOf("") = 0`、`tmp = indexOf("", 0) = 0`。循环里分支一要求 `end > 0`（不成立），分支二要求 `end < 0 || tmp < 0 || end >= n || tmp >= n`（全不成立）⇒ 既不 `break` 也不 `add` 原文；随后 `start = end + 0 = 0`、`end = 0`，`addPlaceholder(template, 0, 0, i)` 拿到空 placeholder，走 `:139-142` 添加一个 `Value2PlainString` 后返回；`start = 0`、`end = indexOf("", 0) = 0` ⇒ **下一轮状态完全相同**。每轮向 `compiled` 追加一个对象，没有任何出口。
- **描述**：`compile` 是公开 API，分隔符完全由调用方给；传空串看似"不解析占位符"，实际是请求线程 100% CPU 空转 + `ArrayList` 无限增长 ⇒ 卡死或 OOM。仓内现有调用点都传非空分隔符，所以这是潜伏缺陷，不是当前线上问题。
- **建议**：`compile` 入口做参数校验：`prefix.isEmpty() || suffix.isEmpty()` 直接 `throw IllegalArgumentException`（或按「整串作为原文」返回，但必须显式写清）；`doCompile` 里再加一条兜底——若一轮循环没有推进（`start` 与 `end` 与上一轮相同）就抛异常，避免以后别的边界再触发同类死循环。

### [一般][存量] #8 `computeBytes` 对合法输入抛异常、乘法溢出静默回绕，且声明返回 `Option` 却从不返回 `None`

- **位置**：`f_util/src/Utils.cj:25-34`（关键行 `29` 的 `matched.groupCount() >= 2`）、`:36-57`（关键行 `57` 的 `throw`、`41-55` 的连乘）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「边界 / 契约与实现不符」、§10「错误处理」
- **证据**：静态确定 ——
  1. 正则 `^(\d+)([kmgtpezyKMGTPEZY]?)[bB]?$` 固定有 2 个捕获组，`groupCount() >= 2` 恒成立，所以**总会**进入 `computeBytes(num, unit)`。对 `"123"`（无单位）和 `"10b"` / `"10B"`（`[bB]?` 吃掉字母、组 2 为空）而言 `unit == ""`，`computeBytes(n, "")` 落不进任何 `if`，直接执行到 `:57` 抛 `IllegalArgumentException("not supported byte unit: ")`。
  2. 仓内已有旁证：`fmq/src/config/MQConfig.cj:183-186` 的注释明确写「不用 `f_util.computeBytes`：该实现对单位分组的取值在本 SDK 上不稳定（大写单位会落到『not supported byte unit』），这里用显式字节扫描」——即下游已经踩过并绕开了它。
  3. `n * 1024 * … ` 全用 `Int64` 连乘，`Y`/`Z`/`E` 档必然溢出（`"9Y"` 回绕成负数），没有任何上界检查。
  4. 返回类型声明为 `Option<Int64>`，但两个重载的所有路径要么返回值、要么抛异常，`None` 从未出现；`find(...).getOrThrow()`（`:27`）对不匹配的串也直接抛 `NoneValueException`，而不是返回 `None`。
- **描述**：一个「解析 123KB / 24M」的小工具，对三种最自然的写法（纯数字、`10b`、非法串）分别给出「异常」「异常」「无上下文 `NoneValueException`」，且溢出时给出错误的正/负值。使用者按 `Option` 契约写 `match` 兜底会全部落空。
- **建议**：`unit` 为空时按字节返回 `n`；`b/B` 归一化后再分派（或干脆用 `match (uniteq) { case "" | "b" => n; case "k" | "kb" => checked(n, 1024); … }`）；所有乘法用 `try { n * k } catch (_: ArithmeticException) { None }` 收敛为 `None`；不匹配的串返回 `None` 而不是 `getOrThrow()`。补用例：`"123"` / `"10b"` / `"10KB"` / `"9Y"`（溢出）/ `"abc"`。

### [一般][存量] #9 `TreeNode.transform` 对「父节点不在集合内」的节点直接 `map[parentId]`，抛无上下文的 `NoneValueException`

- **位置**：`f_util/src/TreeTransformer.cj:53-60`，关键行 `58`（`map[parentId].addChild(t)`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「空集合 / 缺失键未处理、错误处理缺失」、§10「错误处理」
- **证据**：静态确定 —— `HashMap` 的 `operator [](key)` 在键不存在时抛 `NoneValueException`（第 2 部分 #13 已按 std 文档 `collection_package_class.md:6147-6165` 核实同一语义）。`transform` 只把 `parentId == emptyId` 的节点归入 `root`，其余一律 `map[parentId]`；当调用方传进来的集合被过滤过（分页查询只取了一部分行）或存在脏 `parentId` 时，父节点不在 `map` 里，整批转换在第一个孤儿节点处中断，异常里既没有 `parentId` 也没有该节点的 `id`。
- **描述**：树装配是「数据本身可能不完整」的典型场景（按条件筛选、软删除、权限过滤都会造成孤儿）。当前实现把「数据不完整」呈现为 `NoneValueException`，与「map 里存的值是 None」无法区分，调用方只能靠堆栈位置猜。`TreeNode` 是 `public interface`（对外扩展点），仓内暂时零引用（全仓 `grep TreeNode` 只命中定义处），属对外 API 的潜伏缺陷。
- **建议**：`match (map.get(parentId)) { case Some(p) => p.addChild(t); case None => throw IllegalArgumentException("node ${t.id} references missing parent ${parentId}") }`；若要支持「容忍孤儿」，就加一个 `orphanToRoot: Bool = false` 参数把策略显式化，而不是靠异常表达。补用例：父缺失、自引用（`id == parentId`）、重复 id + `ignoreDuplicate=false`。

### [一般][存量] #10 `F_UTIL_CRC_HW` 的语义在三份实现里不一致，且 CRC-64 的 `on` 与 `auto` 完全等价（配置项无效果）

- **位置**：`f_util/src/crc32_native_x86.cj:194-199`、`f_util/src/crc32_native_arm.cj:159-164`（只把 `"0"` 视为关闭）；`f_util/src/crc64_native_x86.cj:283-307`、`f_util/src/crc64_native_arm.cj:275-299`（三态解析）；`f_util/src/crc64_native_x86.cj:276-281` + `:238-257`（`On` 从未被使用）；承诺源 `f_util/src/CrcGf.cj:24`（`enum CrcHwMode` 注释「`on` 强制尝试」）
- **来源**：存量（快照模式无基线可比；第 1 部分「范围外提示 #2」已提出 CRC-32 侧不一致，本部分落实为发现并补上 `On` 无效这一半）
- **判据**：review-checklist §14.1「接线缺失（配置项被读取却从未使用）」、§1「死配置字段 / 恒不成立的开关分支」、§13「规格与实现漂移」
- **证据**：静态确定 ——
  1. **两套语义**：CRC-32 的 `envEnabled()` 是 `v != "0"`，于是 `F_UTIL_CRC_HW=off`、`auto`、`garbage` 全部**开启**硬件；CRC-64 的 `parseMode()` 是 `off/0` → Off、`on/1` → On、其它 → Auto。同一环境变量在两族 CRC 上含义不同，运维按文档设 `off` 时 CRC-32 依然会走机器码（`crc32_native_x86.cj:165` 是 `ensureReady` 里唯一的开关判断，其定义在 `:194-199`）。
  2. **`On` 是死值**：全文件只有 `isOff()`（`crc64_native_x86.cj:276-281`）和 `modeNameForTest()`（`:207-213`）会 `match (mode())`；`On` 与 `Auto` 在 `isOff()` 里同走 `_ => false`，`ensureReady()` 的能力判断（`hasPclmul()` / `make()` 失败回退）对两者一视同仁。也就是说「`on` 强制尝试」从未实现：CPU 不支持或代码页分配失败时，`on` 一样静默回退表路径，没有任何告警。
  3. **测试没兜住**：`CrcEngine_test.cj:477-529` 的三态用例只断言「值一致 + `off` 不进机器码 + `auto`/`on` 进机器码」，在有能力且分配成功的机器上三者同时成立，因此 `On` 的无效性不会被测出来。
- **描述**：这是「配置写了、分支也写了、但语义没接上」：`On` 只影响 `modeNameForTest()` 的输出。运维想强制关闭（CRC-32 侧设 `off`）或想确认是否真的进了硬件，都得不到预期行为。
- **建议**：把模式解析收敛到 `CrcGf`（或新增平台无关的 `CrcHwSwitch`）供 CRC-32/CRC-64 共用，统一接受 `off/0`、`on/1`、其它=`auto`；`On` 要么实现成「忽略 CPU 能力探测、强制 `make()` 失败即抛/告警」，要么删掉该枚举值并同步改注释与测试。补用例：`F_UTIL_CRC_HW=off` 时两族 CRC 都必须 `available == false`。

### [一般][存量] #11 CRC 硬件开关的共享静态状态存在无同步读写：`mode()` 是热路径上的惰性初始化，`resetForTest` 与注释语义相反

- **位置**：`f_util/src/crc64_native_x86.cj:284-293`（`mode()` 在锁外写 `modeState` / `modeResolved`）、`:150`（`update` 第一行 `isOff()` 就在锁外调用它）、`:43`/`:149`/`:193`（`lastNative` 无同步写）、`:197-199`（`setNativeEnabled` 写 `forcedOff` 无同步）；`f_util/src/crc64_native_arm.cj:276-285`、`:109`、`:174-176` 同构；`f_util/src/crc32_native_x86.cj:146-148`（`nativeEnabled` 无同步写）与 `:113`（`update` 无同步读）、`:145`（注释「重新打开需要 `resetForTest()`」）对 `:150-157`（`resetForTest` 不重置 `nativeEnabled`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §12.1「惰性初始化（`if (x == None) { x = ... }` 的首次赋值竞态）」「发布逸出 / 可见性」、§11「语义与注释不符」
- **证据**：静态确定（存在并发读写）+ 待确认（危害形态）——
  1. **并发路径成立**：`Crc64.update` → `CrcEngine.update` → `Crc64Hw.update`（`f_util/src/CrcEngine.cj:205-215`）是每个 CRC-64 计算的必经之路，多个请求线程会同时进入 `update`（`crc32_codegen_test.cj:110-130` 的 `crc32cConcurrentMatches` 已经按 4 线程并发跑过同族 API，说明并发是预期用法）。`update` 的第一句 `isOff()` → `mode()` 在 `synchronized(lock)` **之外**执行，首次调用会写 `modeState` / `modeResolved`；而 `ensureReady()` 在锁内也会走 `isOff()` → `mode()`，两条路径对同一对字段一读一写、无同步。
  2. **后果有限但不为零**：`parseMode()` 是纯函数、两次写的是同一个值，所以最坏是「两个线程各读一次环境变量」，不会产生错误模式；但 `lastNative` 被 `call()` 无条件写、被 `lastUsedNativeForTest()` 读，并发下断言结果不可信（这正是 `CrcEngine_test` 三态用例的判据来源）。`forcedOff` 由测试钩子写、`isOff()` 读，同样无同步。
  3. **注释与实现相反**：`crc32_native_x86.cj:145` 写「测试/诊断钩子：关闭后立刻回退软件；**重新打开需要 `resetForTest()`**」，而 `resetForTest()`（`:150-157`）只清 `ready` / 函数指针 / `codes`，`nativeEnabled` 保持 `false`——关掉后调 `resetForTest()` 并不会重新打开，必须显式 `setNativeEnabled(true)`（`crc32_codegen_test.cj:102` 就是这么写的，说明作者也知道，但注释没改）。
- **描述**：并发面本身危害低（幂等写），所以不按「数据竞争 ⇒ 严重」定级；真正需要改的是「热路径上做惰性初始化」这个结构：每个 `update` 都要读一次可能触发写入的 `mode()`，在首次调用与 `resetForTest` 并发时行为不可预测，而 `resetForTest` 还会与正在执行机器码的线程竞争（代码页不 `munmap`，所以不会崩，但 `codes.clear()` 之后已经没有对象持有它，见 #13 的注）。
- **建议**：模式解析做成「构造期一次性解析 + `let` 字段」（或在 `CrcHwMode` 的静态初始化里解析），`isOff()` 只读不可变值；`lastNative` / `failAlloc` 这类测试钩子用 `AtomicBool` 或全部收进 `synchronized(lock)`；`resetForTest()` 里同时把 `nativeEnabled` 置回 `true`，与注释对齐。

### [轻微][存量] #12 死代码清单（TextTemplate / code_buffer / Crc32Hw）

- **位置**：
  - `f_util/src/TextTemplate.cj:55`（`private static let mutex = Mutex()` 全文件零引用）、`:24`（`import std.sync.Mutex` 只为它存在）、`:18` 的 `Map` 未使用（其余 `ArrayList/TreeMap/HashMap/ConcurrentHashMap/LinkedHashMap` 都有使用）、`:237-239`（`init(indexText: String)` 无调用点，`ValueGetter` 只走 `:228` 的两参 `init`）
  - `f_util/src/code_buffer.cj:61-67`（`rawPointer()` 的两个分支返回同一个 `ptr`，`if (sealed)` 是恒假/恒真装饰）、`:27`（`private var ptr` 只写一次，可 `let`）
  - `f_util/src/crc32_native_x86.cj:86-92`、`f_util/src/crc32_native_arm.cj:68-74`、`f_util/src/crc32_native_stub.cj:25-27`（`Crc32Hw.available()` 全仓零调用；调用方用的是 `availableFor(kind)`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「无调用者 / 未使用的 import / 恒真恒假分支」；机械动作：`private` 全仓搜、`internal` 本包及子包搜
- **证据**：静态确定 —— 四个符号都做了全仓搜索：`mutex` 只命中声明与 import；`Map` 在文件内只命中 import 行；`ValueGetter(` 只命中构造点 `:138`（两参）；`Crc32Hw.available()` 用 `grep -rn "Crc32Hw.available()"` 零命中（`Crc64Hw.available()` 反而被 `CrcEngine_test.cj:482/561/…` 使用，属「仅测试使用」的可见性信息，不判死代码）。
- **描述**：`TextTemplate.mutex` 是缓存键那次变更的残留，而且设计文档还替它编了一个不存在的用途——`f_util/doc/spec/fix-text-template-cache-key/design.md:51` 写「原来 `Mutex` 字段**用于其它路径**，不参与 compile」，实际上它一次都没被用过。`rawPointer` 的双分支是 W^X 改造时留下的占位判断。
- **建议**：删 `mutex` / `Mutex` import / `Map` import / `ValueGetter.init(indexText:)` / 三份 `Crc32Hw.available()`；`rawPointer()` 直接 `return ptr`；`ptr` 改 `let`。`available()` 若确实要给诊断用，就在 `fprobe` 或其他模块接一个真实调用点，否则按死代码删。

### [轻微][存量] #13 重复逻辑：CRC 硬件开关/状态管理在 x86 与 arm 两份实现里逐行复制，`crc16/32/64` 三个包装类同构

- **位置**：
  - `f_util/src/crc64_native_x86.cj:276-307`（`isOff` / `mode` / `parseMode`）与 `f_util/src/crc64_native_arm.cj:268-299` **逐行相同**（仅 `hasPclmul` vs `hasPmull` 不同）；`resetForTest`（`crc64_native_x86.cj:220-236` vs `crc64_native_arm.cj:197-212`）、`setNativeEnabled`（`:197-199` vs `:174-176`）、`lastUsedNativeForTest` / `modeNameForTest` / `forceAllocFailureForTest` 亦同构
  - `f_util/src/crc32_native_x86.cj:194-212`（`envEnabled` + `cpuFlags`）与 `f_util/src/crc32_native_arm.cj:159-186`（`envEnabled` + `cpuFlags`）**逐行相同**；`available` / `availableFor` / `update` / `call` / `setNativeEnabled` / `resetForTest`（`:86-157` vs `:68-127`）骨架一致
  - `f_util/src/crc16.cj:107-124`、`f_util/src/crc32.cj:93-126`、`f_util/src/crc64.cj:62-79`：同一个 `CrcEngine` 上的 `initRegister/update/finish/compute×3` 五件套，只有位宽与包装类型不同
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「只改类型名 / 跨文件复制」；判据要求点名语义差异
- **证据**：静态确定 —— 逐行比对后差异只有三处：`@When` 目标、CPU 能力探测函数（`pclmulqdq+ssse3` / `crc32` / `pmull`）、以及 CRC-64 的 `constsXz/Iso/Redis` 分组数量（x86 多一组 `constsNorm`）。其余（模式解析、开关、状态复位、错误回退）没有任何差异，属纯复制。
- **描述**：`@When` 让同一时刻只编译一份，所以这不是「编译两遍」的浪费，而是**漂移风险**已经发生：`ensureReady` 的返回值口径在 arm 版只认反射核（见 #14）、`envEnabled` 与 `parseMode` 两族语义不同（#10）、`resetForTest` 在三份里做的事都不一样（#11）。每次改开关语义都要记得改 4 个文件，而其中一个必然漏。`crc16/32/64` 的同构包装类风险较低（`crc32` 多了 `hwKind` 分派、`crc64` 没有），但同样属于「加一个 `crc8` 就再抄一遍」。
- **建议**：把与平台无关的部分（模式解析、`envEnabled`、开关/复位状态机、`lastNative`）抽到 `CrcGf.cj` 同级的平台无关类型（如 `CrcHwSwitch`），x86/arm 只保留 `hasXxx()` 与两份机器码数组；`Crc16/32/64` 的 `compute/update/finish` 可以用一个 `Crc<W>` 泛型包装消掉三份胶水（`Crc32.update` 的硬件分派作为特化）。抽取前先补 #10 的语义统一，否则会把错误口径复制到新类型里。

### [轻微][存量] #14 `crc64_native_arm.ensureReady` 只以反射核为准：normal 核分配失败/未就绪时被连坐，`available()` 与 `updateNormal()` 口径相反

- **位置**：`f_util/src/crc64_native_arm.cj:214-232`（`ensureReady` 返回 `fn.isSome()`）、`:144-151`（`updateNormal` 先 `if (!ensureReady()) return None`）、`:96-102`（`available` 返回 `fn.isSome() || fnNorm.isSome()`）；对照 `f_util/src/crc64_native_x86.cj:238-257`（返回 `fn.isSome() || fnNorm.isSome()`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复导致的行为漂移」（x86 与 arm 同一函数的返回口径不同）
- **证据**：静态确定 —— arm 版 `ensureReady` 先 `fn = make()`、`fnNorm = makeNormal()`，最后只返回 `fn.isSome()`。若 `REF_CODE` 的代码页分配/密封失败而 `NORM_CODE` 成功（`failAlloc` 会同时置两者失败，但 `mmap`/`mprotect` 失败可以是单次的），`available()` 返回 `true`（因为 `fnNorm.isSome()`），而 `updateNormal()` 因 `ensureReady()` 为 `false` 永远返回 `None` ⇒ 正常域核（`ecma182`/`we`）永远用不上，且外部无法从 `available()` 判断出来。x86 版没有这个问题。
- **描述**：结果不会算错（都回退表路径），但「`available()` 说有硬件、实际一次都没进」会让诊断与性能回归排查方向跑偏；两平台同一 API 行为不一致本身也是维护陷阱。
- **建议**：`ensureReady` 返回 `fn.isSome() || fnNorm.isSome()`，并把「反射核是否就绪」与「正常域核是否就绪」拆成两个判断（`update` 用前者、`updateNormal` 用后者），与 x86 版对齐；若按 #13 抽出公共开关类型，这条会自然消失。

### [轻微][存量] #15 `time:` / `number:` 分支的转义判断用 `template` 下标去查 `placeholder`，且错误文案是 copy-paste

- **位置**：`f_util/src/TextTemplate.cj:151`（number 分支 `template[formatEnd - 1]` 与「反斜杠字符」比较）、`:172`（time 分支同一行）、`:157`（number 分支抛的消息写成 `time format must be followed ...`，把「数字格式」写成了 time）、`:178`（time 分支同一消息，属正常）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「边界 / 语义与注释不符」、§2「近似重复（一块少了边界判断）」
- **证据**：静态确定 —— `formatEnd` 是相对 `placeholder` 的下标（`placeholder = template[start..end].trimAscii()`，`:137`），而这一行却在 `template` 上取 `formatEnd - 1`；只有 `start == 0` 且没有被 `trimAscii` 削掉前缀字符时两者才指向同一字符。占位符前有任何文本（如 `前缀 {number:...}`）时，读到的就是模板里另一个字符，「反斜杠 + 反引号」的转义判断随机成立/不成立 ⇒ 带转义反引号的格式串时而抛 `IllegalArgumentException`、时而把转义反引号留给 `Decimal` / `DateTime` 解析。`:157` 的文案则把数字格式的报错写成了 time。
- **描述**：`time:` 分支当前因 #1 已经全坏，这条在修 #1 时容易被一起带过，但它是独立的基址错误，修完 `replaceAll` 仍会留坑。
- **建议**：两处都改成 `placeholder[formatEnd - 1]`；`while` 条件里的 `placeholder.size` 保持不变（不要混用 `template.size`）；`:157` 的消息改成以 `number format must be followed ...` 开头。补用例：格式串本身含「反斜杠 + 反引号」的写法，以及占位符前后带空格、带前缀文本两种位置。

<!-- 第 4 部分 -->

### [严重][存量] #1 `GeoHash.encode` 的置位方向与区间收缩方向相反，整个半球坍缩成同一个哈希

- **位置**：`f_util/src/geohash.cj:38-57`（`encode` 的经纬度分支，关键 `:41-47`、`:49-55`）；受害方 `:66-91`（`decode`）、`:112-124`（`tryParse` 末尾的 `encode(lng, lat)`）
- **来源**：存量（快照模式无基线；blame 落在 `4be871f2fd`）
- **判据**：review-checklist §11「逻辑错误 / 语义与命名不符」+ §10「正确性」
- **证据**：静态确定 —— `if (midlng >= longitude)` 成立表示输入点落在**下半区**，位被置 1，但分支里执行的是 `lowlng = midlng`（把区间收缩到**上半区**）。区间从此永远背离输入点，下一轮比较也就失去意义。按源码逐行复算（与 `decode` 的位语义一起）：
  - `encode(10.0, 10.0) = 0x0000000000000000` → `decode` = `(-179.99999992, -89.99999996)`
  - `encode(-10.0, -10.0) = 0xffffffffffffffff` → `decode` = `(179.99999992, 89.99999996)`
  - `encode(116.4, 39.9) = 0x0`、`encode(-73.9, 40.7) = 0xaaaaaaaaaaaaaaaa`
  每个轴的位只由该坐标的**符号**决定（正 → 全 0，负 → 全 1），于是四个象限只剩 `0x0` / `0x5555…` / `0xaaaa…` / `0xffff…` 四个可能值，64 位编码退化成 2 位。
- **描述**：`decode`（`:74-89`）与 `tryParse`（`:115-121`）都把位 1 解释为「取上半区」，与 `encode` 的区间更新正好相反。因此 `decode(encode(x))` 不但不落在 x 的格子里，还把整象限压成 2 个值；`parse(toString(h))` 同理不成立（`toString` 输出的 32 个四进制字符由位直接拼出，`tryParse` 再 `encode` 回来必然翻面）。任何「按 geohash 前缀做邻域检索 / 空间分桶」的用法都会完全失效，且不会抛异常，只给出错误结果。`f_util/src/geohash.cj` 在仓内无调用者（`grep GeoHash` 只命中 README 与 `GeoHashException` 的引用），因此这个 P0 一直没被下游暴露。
- **建议**：把两个分支的区间更新对调（`midlng >= longitude → highlng = midlng`，`else → lowlng = midlng`，纬度同理），或保留区间更新、把比较改成 `longitude >= midlng`；`tryParse` 末尾不要依赖 `encode` 重算，直接从已收缩的区间取中点构造。补用例：`encode(116.4, 39.9).decode()` 与原点误差小于 1 个格（约 1e-6 度量级）、`parse(toString(h)) == h`、四个象限各 1 例。

### [一般][存量] #1b `GeoHash.tryParse` 不校验串长、`encode` 不校验坐标范围，`parse` 的失败面只剩「非法字符」

- **位置**：`f_util/src/geohash.cj:105-124`（`tryParse` 全循环没有长度判定）、`:31-60`（`encode` 不检查 `longitude ∈ [-180,180]`、`latitude ∈ [-90,90]`）、`:125-127`（`parse`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「空集合/空串未处理、边界校验缺失」+ §3「契约承诺有行为」
- **证据**：静态确定 —— 每个 rune 只贡献 2 位，`tryParse` 对 0/1/31/33 个字符的输入都照常收缩区间并返回 `encode(lng, lat)`：`GeoHash.parse("")` 返回 `encode(0.0, 0.0)`（不抛 `GeoHashException`），31 字符的串也被接受。README `:315`、`:317` 明确写「把**四进制字符串**转成 GeoHash」，`toString()` 固定输出 32 个字符（`62 ..= 0: -2` 共 32 轮），接口契约是 32 位；`encode(200.0, 100.0)` 同样不报错，静默给出越界坐标的哈希。
- **描述**：`GeoHashException` 只在出现 `0-3` 以外字符时才会抛（`:126`），长度与取值范围这两个更常见的输入错误全部静默通过。配合 #1，`parse("")` 与 `parse("0" * 32)` 都没有可用的语义，使用者无法区分「空串」「半截串」「合法串」。
- **建议**：`tryParse` 入口加 `if (hash.size != 32) return None<GeoHash>`（`String.size` 是字节长度，见 `std/core/core_package_api/core_package_structs.md:6181-6189`），循环末尾再从区间中点取值而不是重新 `encode`；`encode` 对越界坐标抛 `GeoHashException` 或明确截断并在注释里写清。补「空串 / 31 字符 / 33 字符 / 越界坐标」四个负例。

### [严重][存量] #2 `UUID.timestampNanos` / `timestamp` 三个版本分支全部算错：v1/v6 溢出抛异常，v7 写入端错位、读回端量纲错

- **位置**：读侧 `f_util/src/uuid.cj:116-173`（`timestampNanos`，关键 `:168`、`:171`）、`f_util/src/uuid.cj:174-183`（`timestamp`）；写侧 `f_util/src/uuid.cj:392-409`（`unixTimeBased`，关键 `:397`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「边界/数值错误、错误处理缺失」+ §10「正确性」；整数溢出语义见 `std/overflow/overflow_package_overview.md:7`（默认抛异常）
- **证据**：静态确定，三处独立错误：
  1. **v1/v6 溢出**：`n` 是 1582-10-15 起算的 100 ns 计数，2026 年约 `1.40e17`；`:171` 的 `n * 100` = `1.40e19`，超过 Int64 上限 `9.22e18` ⇒ 抛 `OverflowException`。临界点约 1874 年（`9.22e18 / 100 / 1e7 s ≈ 292 年`，1582 + 292），即**所有现代 v1/v6 UUID 取 `timestampNanos` 都会抛异常**，`timestamp` 先读它，同样抛。同文件 `:711-712` 的注释（“1582 年至今的纳秒数超过 Int64 上限……必须拆成秒 + 纳秒余数”）证明作者知道这个量装不下 Int64，`timestampNanos` 却又原样乘了 100。
  2. **v7 死表达式 + 量纲错**：`:168` 的 `n * 10000` 是 match 分支里的**孤立表达式**（没有赋值给 `n`），值被丢弃；随后 `:171` 只乘 100，而 v7 时间戳是毫秒，正确换算应是 ×1e6。
  3. **v7 混入随机位**：`:149-151` 把 `values[6] & 0xf`（v7 布局里 byte6 的低 4 位，即 `rand_a` 的高 4 位）与 `values[7]`（`rand_a` 低 8 位）拼进了时间戳，12 位随机数污染时间。
  4. **v7 写侧错位**：`:397` 用 `(millis >> (7 - i) * 8)` 往 6 个字节里写 48 位 `unix_ts_ms`，位移应按 6 字节算成 `(5 - i) * 8`。结果是 `(ms << 16) mod 2^48`：`ms = 1.76e12` 时该字段解码回来是 8944 年（复算值 `0xc82cc0000000`），并且每 `2^32 ms ≈ 49.7 天`回绕一次，跨周期的字符串不再单调。
- **描述**：README `f_util/README.md:534`、`:538` 把 `timestampNanos` / `timestamp` 列为公开能力，`:577` 写明 v7「基于 UNIX 时间戳」；实际三条路径都不能用。下游已经踩到：`fdbm/src/idmaker/IdMakers_test.cj:194` 的注释直接写「`timestampNanos` 对 1582 年起算会超出 Int64，故单测自行解码」，并在 `:195-210` 手写了一份位解码绕过该公开属性——这是缺陷被外部绕开的直接证据。v7 的写侧错误还会让任何外部工具（数据库 `uuid_extract_timestamp`、其他语言的 UUID 库）读出错误时间，`fdbm` 的 v7 主键也受影响。
- **建议**：把「1582 起算 100 ns」这个量从 `Int64` 纳秒口径里拿掉——`timestampNanos` 改成返回 `timestamp` 派生值（`(DateTime.UnixEpoch, Duration)` 或 `timestamp.toUnixNanoseconds` 之类的可用口径），v1/v6 分支不做 ×100，`timestamp` 用「秒 + 余数」拼 `Duration`；v7 写侧改 `(5 - i) * 8`，读侧只取 `values[0..5]` 组成 48 位 ms 并 `× 1e6`，`values[6]` 的低 4 位与 `values[7]` 归 `rand_a` 不参与时间；删掉 `:168` 的孤立表达式。补 v1/v6/v7 三个 `timestamp` 往返用例（固定字节数组，断言具体 `DateTime`）。

### [严重][存量] #3 `qpow` 的 UInt64 乘法溢出，`isPrime` 对大于 2^32 的输入直接抛 `OverflowException`

- **位置**：`f_util/src/prime.cj:31`（`ans = (ans * aa) % m`）、`:34`（`aa = (aa * aa) % m`）；调用链 `:44`（`millerRabin` 里 `qpow`）→ `:68`（`isPrime` 里 `millerRabin`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「数值溢出、错误处理缺失」+ §10「正确性」；溢出默认抛异常见 `std/overflow/overflow_package_overview.md:7`
- **证据**：静态确定 —— `aa < m`，只要 `m > 2^32`，平方链就会触到 `2^64`：例如 `p = 4294967311`（2^32 后的素数）时平方链为 `2 → 4 → 16 → 256 → 65536 → 4294967296`，下一步 `4294967296² = 2^64` 溢出。默认整数运算溢出抛 `OverflowException`（`wyhash.cj:36-37` 正是显式加 `@OverflowWrapping` 才敢做无检查乘法，`prime.cj` 没有任何标注），所以 `isPrime(p)` 在 `p > 2^32` 时不是返回 `false`，而是抛异常。另一个独立问题：`:63` 的基集合 `[2,3,5,7,11]` 只保证 `p < 3,474,749,660,383` 内确定，超过后存在强伪素数（当前被溢出先挡住，修好溢出后会暴露）。
- **描述**：`isPrime(p: UInt64): Bool` 的入参契约是 UInt64 全域，`UInt64` 是它的唯一卖点；实际可用范围只有 2^32 以内的幸运值和 2^32 以上的必炸。`qpow` / `millerRabin` / `isPrime` 三个都是 `public`，README `f_util/README.md:408-418` 只抄了注释没有写上限。仓内无调用者（`grep isPrime|qpow|millerRabin` 除 README 外零命中），所以属于「对外 API 一用就炸」，不是线上事故。
- **建议**：`qpow` 改用 128 位中间量（`f_util` 已有 `UInt128`；或 `std.math.numeric.BigInt` 的 `%`），并给 `m == 0` / `m == 1` 明确语义；`isPrime` 先做小素数试除与 `p < 3.47e12` 的确定界检查，超出后改用 12 基或 BPSW；把「支持范围」写进函数注释与 README，不要留 `UInt64` 全域的假契约。

### [一般][存量] #4 `UUID.tryParse` / `parse` 两侧都错：接受尾部垃圾、拒绝大写、`Nil` / `Max` 无法往返

- **位置**：`f_util/src/uuid.cj:192-251`（`tryParse`，关键 `:225-246` 的字节循环、`:247-249` 的 variant 门槛、`:196-221` 的 `doParse`）；`:189-191`（`parse` 抛 `IllegalArgumentException`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「边界校验缺失 / 契约与实现不符」+ §3「公开契约承诺有行为但实现打折」
- **证据**：静态确定，按源码复算：
  - `:193` 只校验字节长度 36；循环在 `i == 16` 就退出，**不检查 rune 迭代器是否耗尽**。`"f47ac10b58cc4372a5670e02b2c3d479zzzz"`（32 个 hex + 4 个垃圾字符）被成功解析成 `f47ac10b58cc4372a5670e02b2c3d479`。
  - `:247` 的 `values[8] >> 6 != 2` 硬性要求 RFC 变体，于是 `UUID.parse(UUID.Nil.toString())`（变体 0）与 `UUID.Max`（变体 3）都抛 `IllegalArgumentException` —— `parse(x.toString()) == x` 这个 `Parsable` 基本契约不成立，也读不进 NCS / 微软变体的存量 UUID。
  - `doParse`（`:196-221`）只认 `r'a'..r'f'`，大写 UUID（很多系统默认大写输出）一律 `None`。
- **描述**：三个现象同一根因——手写解析只做到「能凑够 16 字节」，既没有收尾校验，又额外加了一个比 RFC 更严的变体门槛，且大小写支持不对称（同文件的 `ether` 解析就支持大写）。`parse` 抛 `IllegalArgumentException`，而同类「读值失败」的 `timestamp`（`:180`）抛 `UUIDException`，同一类型的错误出现两个异常族，调用方无法统一捕获。
- **建议**：循环结束后断言 `iterator.next()` 为空；变体判定改成 `(values[8] & 0xc0) == 0x80`（RFC 变体是 `10xxxxxx`），或把变体检查从 `tryParse` 下沉到需要它的地方；hex 解析抽成大小写都收的 `private func hexValue(c: Rune): ?Byte` 供 `tryParse` 与 `ether` 共用；`parse` 改抛 `UUIDException`。补 Nil/Max/大写/尾垃圾/缺 `-` 五种用例。

### [一般][存量] #5 `UUID.sha1` 生成的 v5 与 RFC 9562 不一致（byte 6/7 取摘要的 sha[18]/sha[19]）

- **位置**：`f_util/src/uuid.cj:359-377`（关键 `:366-370`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「契约与实现不符」；契约源 `f_util/src/uuid.cj:33-35`（`reference https://www.ietf.org/archive/id/draft-ietf-uuidrev-rfc4122bis-00.html`）与 README `:564-570`（「version 5」+ `sha1` 签名）
- **证据**：静态确定 —— v5 规定取 SHA-1 摘要前 16 字节，仅把 byte6 高 4 位置为版本、byte8 高 2 位置为变体；实现把 byte6、byte7 改成摘要的第 18、19 字节（`sha[18] & 0xf | 5 << 4`、`sha[19]`），其余取 `sha[i]`。这四个字节覆盖了 name 的哈希值，与任何标准实现（Python `uuid.uuid5`、Java `nameUUIDFromBytes`）都不相等。
- **描述**：`UUID.sha1("x")` 看起来是 v5，但按名字生成同一 UUID 的跨语言约定失效——多语言共用一张按名字派生 ID 的表时会对不上，而且不会有任何报错。注释 `:351` 自己也在讨论这段布局「原文是 md5_low，此处应该是一个错误」，说明这块是照图抄写时出的偏差。`randomSha1` 只做随机哈希，不受影响。
- **建议**：`values[i] = if (i == 6) (sha[6] & 0xf) | (5 << 4) else if (i == 8) (sha[8] & 0x3f) | (2 << 6) else sha[i]`，即只用 `sha[0..15]`；补黄金值用例（对 RFC 9562 附录测试向量断言）。

### [一般][存量] #6 序列号扩展点不满足 `serialSeq` 语义：同一刻度返回同一序号；生成器恒返 0 时无界自旋

- **位置**：`f_util/src/uuid.cj:689-704`（`registerSequenceGenerator()`，关键 `:696-702`）、`:650-688`（文件版，关键 `:666-668`）、`:497-501`（`genTimestampAndSequence` 的 `while`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「逻辑错误」+ §12.1「有界性」
- **证据**：静态确定 —— `last >= timestamp` 分支直接 `return seq`（文件版 `:667` 同样是 `seq`），既没有 `fetchAdd` 也没有写回文件，于是同一 100 ns 刻度内的第 2、3… 次调用拿到**完全相同**的序号。`TimeBasedUUIDBuilder.generate`（`:577-580`）把该序号写进 byte8/byte9，只要 node 固定（`node(...)`、`eth0()`、`ether(...)`），两次调用就产出逐字节相同的 UUID。另外 `genTimestampAndSequence` 用 `while (timestamp == 0 || seq == 0)` 等非零序号，用户注册的 `(Int64) -> UInt16` 生成器若恒返回 0 就会无界自旋，没有重试上限也没有超时。
- **描述**：`serialSeq` 的语义是「同一时间戳内单调递增的序号」，实现变成「同一刻度内所有 UUID 共用一个序号」。仓内主用方 `fdbm` 每次额外 `randomNode()` 取 6 字节随机 node，所以重复没暴露（`fdbm/src/idmaker/IdMakers.cj:71`），但「按机器 MAC 生成 node」才是 v1 的标准用法，那条路上会产生重复主键。默认构造器里的 `AtomicUInt16` 版本（`:632-635`）反而是正确的递增实现，被 `registerSequenceGenerator()` 替换后行为退化。
- **建议**：同刻度分支改成「原子自增并返回旧值」（`seq.fetchAdd(1)`，CAS 竞争时重取），文件版在同刻度分支把 `seq + 1` 写回；`genTimestampAndSequence` 加最大重试次数，超限抛 `UUIDException`。补「同一 node 连续生成 10^5 个 UUID 无重复」的用例（`fdbm` 现有用例只覆盖随机 node）。

### [一般][存量] #7 `TimeBasedUUIDBuilder` 的可变字段无任何同步，也没有线程安全声明

- **位置**：`f_util/src/uuid.cj:446-501`（`version` / `timestamp` / `seq` / `uid` 由 `randomSeq` / `serialSeq` / `UID` 写）、`:567-585`（`generate` 读）、`:646-654`（`registerSequenceGenerator` / `registerFileSequenceGenerator` 在 mutex 外替换 `seqGen` / `closer`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护、发布逸出」+ §12.2（锁粒度）
- **证据**：静态确定 —— `TimestampSequenceBuilder.timestampAndSequence`（`:707-721`）用 `mutex` 保护了时间戳/序号的计算，但结果写回 `TimeBasedUUIDBuilder` 的四个普通 `var`，`generate` 再读它们，两步之间没有任何 happens-before。两个线程共用同一 builder 时：线程 A 可能读到自己的 `timestamp` + 线程 B 的 `seq`（错配），也可能两边都拿到同一对 `(timestamp, seq)` 而与各自的 node 组合失效；`registerSequenceGenerator` 替换闭包同样在锁外。类为 `public`，README `:586-618` 未提线程安全。
- **描述**：缺陷已被下游发现但没回写：`fdbm/src/idmaker/IdMakers.cj:34-36` 的类注释写「builder 的 `timestamp`/`seq` 字段非线程安全，`nextStringId()` 必须持锁（D10）」，并在 `:70-72` 用外部 `Mutex` 串行化。`f_util` 自己既没有文档也没有内建同步，下一个使用者不会知道这条隐含约束。
- **建议**：把 `serialSeq` + `node` 合并为原子的 `nextUUID(...)`（内部持锁，临界区只覆盖字段写入与 16 字节组装，不放 I/O），或至少在类注释与 README 明确「非线程安全，必须外部串行化」；`registerSequenceGenerator` 系列替换 `seqGen` 时取同一把 `mutex`。补 8 线程共用 builder 的断言用例。

### [一般][存量] #8 文件序列号生成器把磁盘 I/O 放在 UUID 生成锁内，并硬编码 `/tmp`、临时文件不清理

- **位置**：`f_util/src/uuid.cj:650-688`（`file.read` / `seek` / `write` / `flush`）、`:709-721`（`synchronized(mutex)` 内调用 `seqGen(timestamp)`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §6.2「锁内做 I/O」+ §12.2「临界区是否只保护不变量」
- **证据**：静态确定 —— `timestampAndSequence` 在 `synchronized(mutex)` 内调 `seqGen(timestamp)`，文件版每次调用要做 seek + read + seek + write + flush（5 次系统调用，含一次落盘），全部在锁内；`genTimestampAndSequence` 的 `while` 还会在序号为 0 时重复取同一把锁。`:651` 的 `Directory.createTemp('/tmp')` 硬编码 Linux 临时目录，`@When` 没有加平台限制（同文件的 `etherName` 就加了 `@When[os == 'Linux']`），临时目录与 `yyyyMMddHHmmssSSS` 命名的文件在 `close()` 后也不删除。
- **描述**：启用文件版后，全进程取号被串行化到一次 `fsync` 的延迟（毫秒级，随磁盘抖动），UUID 生成吞吐掉到 IOPS 量级；这属于「可选扩展点把主路径变成阻塞路径」。`/tmp` 硬编码让 Windows 上调用直接抛文件异常（`f_util/cjpm.toml` 声明了 mingw 目标），临时文件残留则是每次进程启动新建一个目录 + 一个文件。
- **建议**：文件版改成「启动读一次 + 按区间预分配（例如一次领 64 个序号写回）」，把 I/O 移出每次取号的锁；临时目录走 `std.env` 的临时目录 API 或加参数，`close()` 里删文件；至少补 `@When[os == 'Linux']` 或文档标注平台限制。

### [一般][存量] #9 输入边界缺失：`node(Array)` 不校验 6 字节、`ether` 长度不足报 `UnreachableException`、`randomMd5/randomSha1` 的 `bytes` 未校验

- **位置**：`f_util/src/uuid.cj:564-566`（`node(node: Array<Byte>)` → `node[i]`，i 取到 5）、`:513-550`（`ether` 的 `parse(itr.next())`）、`:314-316`、`:356-358`（`randomMd5` / `randomSha1`）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §11「空集合 / 边界未处理、错误处理缺失」
- **证据**：静态确定 —— `generate`（`:582`）对每个 UUID 调 `node(i - 10)`，i = 10..15 ⇒ 索引 0..5，数组短于 6 直接 `IndexOutOfBoundsException`；`ether` 传入少于 17 个 rune 的串时 `parse(None)` 抛 `UnreachableException`（把「格式不对」报成「不可达」）；`randomMd5(bytes: -1)` 只会在 `SecureRandom.nextBytes` 里炸，负值和超大值都没有前置校验。
- **描述**：三个 `public` 入口都把调用方错误变成不相关的运行时异常，排障时看不到真实原因；`randomMd5(bytes: 10^9)` 还会按调用方给的长度一次性分配。仓内调用点（`fdbm` 用 `randomNode()`）不会踩到，但这是对外契约的一部分。
- **建议**：`node(Array)` 前置 `if (bytes.size < 6) throw UUIDException(...)`；`ether` 解析失败抛 `UUIDException("bad ether address ...")`；`randomMd5/randomSha1` 校验 `bytes > 0` 并给上限（例如 1024）。

### [轻微][存量] #10 死代码：未使用的 `stdx.crypto.crypto.*` import、`timestampNanos` 里的孤立表达式

- **位置**：`f_util/src/uuid.cj:24`、`:168`
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §1「未使用的 import、读了不用的表达式」
- **证据**：静态确定 —— `uuid.cj` 内没有任何 `SecureRandom` / `SM4` 等 `stdx.crypto.crypto` 包符号（随机源走 `f_random.ThreadLocalRandom`，SecureRandom 在它内部），`stdx.crypto.digest` 的 `MD5`/`SHA1` 是另外一行 import；`:168` 的 `n * 10000` 位于 match 分支末尾且未被赋值，作为语句其值被丢弃（这是 #2 的可见症状）。
- **建议**：删掉 `:24`；`:168` 按 #2 重写。这一维可以在 `cjlint` 里常态化（`unused import` 应报 warning）。
- **备注**：本部分其余私有符号已逐个搜过：`geohash.cj` 的 4 个 `MAX/MIN` 常量各 4 处使用；`uuid.cj` 的 `h`、`hex`、`toString(withDash:)`、`generate`、`timeLowFirst`、`genTimestampAndSequence`、`emptyCloser`、`timeStart`、`mutex`、`seqGen`、`closer` 均有调用；`wyhash.cj` 的 `SECRET0-3`、`mix`、`r4`、`r8` 均有调用；`internal` 的 `UUID(values:)`、`TimeBasedUUIDBuilder.init`、`TimestampSequenceBuilder.init`/`timestampAndSequence`、`SequenceResource(...)` 均被同类使用。`SequenceResource` 虽是 `public struct`，构造器为 `internal`，仓外不可构造，但其 `public` 成员在类内被真实调用，不判死代码。

### [轻微][存量] #11 重复逻辑：同文件两份手写十六进制解析（大小写行为不一致）+ 五处 version/variant 打戳

- **位置**：`f_util/src/uuid.cj:196-221`（`tryParse` 内 `doParse`）与 `:518-541`（`ether` 内 `parse`）；打戳逻辑 `:321-324`（md5）、`:332-335`（random）、`:363-375`（sha1）、`:395-407`（unixTimeBased）、`:427-441`（custom）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §2「同语义不同写法、字面量复制；近似重复里少了一处边界判断往往是缺陷」
- **证据**：静态确定 —— 两个 hex 转换函数的输入/输出/副作用一致（Rune → Byte），唯一差别是 `parse` 支持大写、`doParse` 不支持，且 `doParse` 用魔法值 16/17 当分隔符与非法哨兵；这正是 #4「大写 UUID 被拒」的成因。五处构造函数都在重复这两组打戳常量——`(x & 0xf) | (v << 4)` 与 `(x & 0x3f) | (2 << 6)`（md5/random 写成两步 `&= …` + `|= …`，其余写成生成器里的单表达式），控制流一处原地改数组、一处 `Array(16){...}`，`unixTimeBased` 的位移错误（#2）就出在生成器那一版。
- **建议**：抽 `private func hexValue(c: Rune): ?Byte`（大小写都收）与 `private func stamped(version: Byte, bytes: Array<Byte>): Array<Byte>`，5 个构造函数共用；分隔符哨兵改用 `?Byte` 表达，不用 16/17。

### [轻微][存量] #12 带副作用的 `prop` + 两段式 builder：连续两次 `node(...)` 产出完全相同的 UUID

- **位置**：`f_util/src/uuid.cj:477-488`（`randomSeq` / `serialSeq` 是 `prop`，每次读都改字段）、`:551-566`（`node` / `randomNode` 依赖上一次读 `serialSeq` 的结果）
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §10「可读性 / 命名与语义」+ §11「语义与命名不符」
- **证据**：静态确定 —— `generate`（`:567-585`）用的是字段 `this.timestamp` / `this.seq`，不读 `serialSeq` 就不刷新。`builder.serialSeq.node(1)` 之后再 `builder.node(1)`，两次的 timestamp/seq/node 全同 ⇒ 相同 UUID。`prop` 在 Cangjie 里是属性访问语义，读者不会预期 `builder.randomSeq` 有副作用。
- **建议**：改成 `nextUUID(node: Int64)` / `nextUUIDRandomNode()` 这类一次返回 UUID 的方法，把「刷新时间戳与序号」变成显式动作；或至少把 `randomSeq`/`serialSeq` 改成普通方法并加注释说明「每个 UUID 必须紧跟一次刷新」。

### [轻微][存量] #13 测试只覆盖 `random()`，v1/v6/v7、parse 边界、序列唯一性全裸奔

- **位置**：`f_util/src/uuid_test.cj:21-31`
- **来源**：存量（blame `4be871f2fd`）
- **判据**：review-checklist §14「示例/用例覆盖不足」+ §10 可验证性
- **证据**：静态确定 —— 唯一用例断言 v4 的 `version == 4`、`variant == 2` 与 `toString` ↔ `parse` 往返；#2（三个版本的时间戳）、#4（Nil/Max/大写/尾垃圾）、#5（v5 黄金值）、#6（固定 node 的序号唯一性）涉及的分支零覆盖。`geohash.cj` / `prime.cj` 在本模块也没有任何 `*_test.cj`。
- **建议**：按各条建议补最小用例集；`geohash` 至少一条「四象限 + 往返」，`prime` 至少一条对 2^32 以上的素数（如 `4294967311`）断言 `isPrime` 返回 `true` 且不抛异常。测试文件属本部分，补测不会扩大改动面。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分只有 `CaseFormat.cj` 一个实现文件，其余为文档；其自身的性能/内存改进（每次 `convert` 新建 `StringGenerator` 与目标实例）没有改前基线，按硬规则不进本节，见「待验证假设」。故本部分优化方案计数为 0 / 0。

<!-- 第 2 部分 -->

> 以下都不是缺陷，是"修 #1/#2/#10 时顺手可做"的改进；全部**无性能基线**，因此只作为下一轮补数据的候选，不进 `tasks.md`。

### [CPU] O1 `murmurHash` 去掉每 16 字节的切片分配

- **现状**：`MurmurHash3X128.cj:39-43` 每处理一个 16 字节块就 `data[offset..offset+16]` 生成一个切片，再对它做两次 `readLittleEndian`；块数 = 输入长度 / 16，分配次数与输入大小线性相关。
- **方案**：改为直接在 `data` 上用 `UInt64.readLittleEndian(data[offset..offset + 8])`（或按字节组装），删掉中间 `blockSlice`；尾部同理。
- **预期**：每 MiB 少 65536 个切片对象；GC 次数与分配量下降（幅度未知）。
- **代价**：需确认 `readLittleEndian` 接受"从任意偏移开始的切片"且不复制（std 签名如此，但要在目标 SDK 上核对）。
- **验证**：`cjpm bench -O2` 对 1 MiB 输入跑修复前后各 10 轮，比中位数与四分位距；`cjprof heap` 看分配量。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] O2 `PathPattern` 把匹配期扩容移出请求路径

- **现状**：`getPathNode` 在匹配线程上按 `parts.size` 懒建节点（`68-99`），首次访问某种深度的路径会在实例锁内 `add` + 回放 `originPatterns`（含正则替换与 `split`）。
- **方案**：启动期把所有已注册路由的段数预热好（`compile` 结束时按 `patterns.size` 补齐），匹配期只读；或把 `patterns` 换成 `Array<PathNode>` + 原子替换发布。
- **预期**：请求路径不再取锁、不再分配节点（收益取决于长路径请求占比）。
- **代价**：`compile` 后新增长度仍可能未命中，需要"未命中直接返回 `None`"的语义（不影响正确性，只是不再自动补节点）。
- **验证**：`cjprof` 跑 10 分钟路由压测，比较 `getPathNode` 的自耗时占比与锁等待时间；同时用 #10 的并发用例验证无竞态。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] O3 `Fnv.hash` 复用 `FnvCore`，避免每次调用 4 个数组

- **现状**：`Fnv.cj:53-56` 每次 `hash()` 都 `FnvCore.of(...)`，构造 `basis`、`state`、`scratchA`、`scratchB` 四个 `Array<UInt32>`（1024 位时各 32 个 limb，合计 512 B）+ 结果数组；`Fnv32/64/128/256/1024` 的每个入口都走这条路径（`84/92/104/112/124/133/142/…`）。
- **方案**：给 `FnvHasher` 增加"一次性算完但复用内部缓冲"的静态入口，或用 `ThreadLocal<FnvCore>`（`reset()` 已实现）复用 4 个数组；`Fnv64.fnv1a` 这类高频入口不再走 `Array<UInt64>` 中转。
- **预期**：单次哈希的堆分配从 5 个数组降到 0–1 个；对 f_jit 的常量指纹（每次编译大量调用）收益最明显。
- **代价**：`ThreadLocal` 常驻内存（每线程 ~512 B）；需保证 `reset()` 后 `basis` 不被改写。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 10 万次 `Fnv64.fnv1a` 的 `cjpm bench -O2`。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 3 部分 -->

> 不是缺陷，是"还能更好"。全部**无性能基线**，只作为下一轮补数据的候选，不进 `tasks.md`。

### [CPU] O1 `Crc32.update` 的 ISO 路径把整段前缀拷一份再交给机器码，改成传 `(data, aligned)` 与 CRC-64 对齐

- **现状**：`f_util/src/crc32.cj:97-104` 对 `hwKind == Iso` 先算 `aligned = data.size - data.size % 16`，然后 `Crc32Hw.update(CrcHwKind.Iso, crc, data[0..aligned])`。`data[0..aligned]` 是 `Array` 切片 ⇒ **新建并复制** `aligned` 字节；4 KiB 帧（`aligned = 4096`）就是每次 `update` 多分配并拷一份 4 KiB，随后机器码再读一遍。CRC-64 侧已经是「传整段 + 传处理长度」的形态（`crc64_native_x86.cj:148`、`:175-195` 用 `aligned` 参数 + `acquireArrayRawData`，零拷贝），说明这个改法在本仓库已被验证可行。
- **方案**：把 `Crc32Hw.update(kind, crc, data)` 改成 `update(kind, crc, data, aligned)`（x86/arm/stub 三份签名同步），x86 侧用 `aligned` 做 16 对齐检查，arm 侧忽略（其循环自带尾字节处理）；`Crc32.update` 传 `data` 与 `aligned` 原值，不再切片。测试里的直接调用点（`crc32_codegen_test.cj:202/206/224`）同步改签名。
- **预期**：每次 ISO-HDLC `update` 少 1 次 `Array` 分配与 `aligned` 字节 `memcpy`；4 KiB 帧上等于把「拷 4 KiB + 算 4 KiB」降为「算 4 KiB」，收益上限取决于 `memcpy` 在单次 4 KiB CRC（README 记的 475 ns 量级）中的占比。
- **代价**：内部签名变更（`Crc32Hw` 是 `internal` 类，不破坏对外 API）；需保证 `aligned <= data.size` 的校验从 `Crc32.update` 移到被调方。
- **验证**：同一机器、同 SDK、`-O2`，4 KiB × 10^5 次 `Crc32.isoHdlc.compute`，改前改后各 10 轮取中位数与 IQR；`cjprof heap` 对照分配字节数（应减少 ≈ 4 KiB × 次数）。等价性用 `Crc32.isoHdlc` 的全长度对拍（`crc32_codegen_test.cj:143-157` 已覆盖 0/1/3/15/16/17/…/65536）。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 4 部分 -->

> 不是缺陷。以下三条都**没有改前基线**，只作为下一轮补数据的候选，不进 `tasks.md`。

### [CPU] O1 `UUID.toString` 每 UUID 一次 `StringGenerator` + 36 次 `append` + 一次字节缓冲拷贝

- **现状**：`:85-101` 每次 `toString()` 新建 `StringGenerator`（内部一个 `ArrayList<Byte>`），循环 16 次、每次 2 次 `append(Rune)` 加 4 次 `append(r'-')`，最后 `toString()` 再把整个缓冲复制成 `String`。`fdbm` 的 uuid 主键、`f_http` 的上传路径（`MultipartFormDataParser.cj:101`）、`f_egraph` 每事件的 `session` 默认值都在这条路径上。
- **方案**：预分配 36 字节 `Array<Byte>`，用 256 项 ASCII 表直接写 `hex`，返回 `String.fromUtf8(bytes)`（或 `String.fromAscii`，按 SDK 可用 API 选）；`toString(radix: 16)` / `toHexString()` 复用同一份 32 字节写入逻辑。
- **预期**：每次转换少 1 次 `ArrayList` 分配与 36 次方法调用，字节缓冲只分配一次。占比未知，需 profile。
- **代价**：`StringGenerator` 自带 UTF-8 编码语义，改成手写 ASCII 需要保证只写 `0-9a-f-`（都是 ASCII，安全）；代码量略增。
- **验证**：`cjprof record` 跑「10^6 次 `UUID.random().toString()`」（`-O2`，同机），看 `toString` 自耗时与分配字节数；改前改后各 10 轮取中位数与 IQR。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] O2 `wyhash` 用边界检查索引，std 的同款实现用 `arrayGetUnchecked3`

- **现状**：`f_util/src/wyhash.cj:53-101` 直接 `arr[pos]` 逐字节读取，4/8 字节读取函数（`:130-137`）每次 4~8 次边界检查；`std` 的同名实现（`cangjie_runtime/stdlib/libs/std/core/hashable.cj:996-1046`）用的是 `arrayGetUnchecked3<UInt8>`，其余逻辑逐行相同（本次已逐段对比 `size<4` / `==4` / `<8` / `<=16` / `>48` 五个分支与 `mix`，确认是忠实移植）。
- **方案**：在 `size`/`start` 已在前置校验过（`size <= arr.size - start`）之后，把 `r4`/`r8` 换成内部 unchecked 读（`unsafeGet` / `arrayGetUnchecked`，按 SDK 可用 API），或在模块内加一层 `@OverflowWrapping` 的裸指针读。
- **预期**：每次 hash 少 `len` 次边界检查；`f_bloom` 的布隆过滤器（`f_bloom/src/BloomFilter.cj:61`，`seeds` 个 seed 各算一次 hash）是唯一仓内调用点，收益随 `seeds` 放大。
- **代价**：必须在 `wyhash` 入口补 `start >= 0 && size >= 0 && start + size <= arr.size` 校验，否则 unchecked 读会越界（当前是抛异常兜底，改错就变内存安全事件）。
- **验证**：`cjpm bench -O2` 对 `wyhash(bytes, size: 64/1024)` 各 10^6 次，改前改后中位数 + IQR；等价性用现有 `wyhash` 输出对拍（新实现必须逐位相同）。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] O3 `UUID` 以 `Array<Byte>(16)` 存值，每个实例多一次堆分配

- **现状**：`f_util/src/uuid.cj:37-40` 的 `values: Array<Byte>` 让每个 `UUID` 结构体持有一个 16 字节数组对象（对象头 + 16 B，约 40 B/实例），且 `==`/`compare` 都是逐字节读数组。`fdbm` 按行生成主键、`f_egraph` 每个事件一个 `session`，实例量大但生命周期短。
- **方案**：把 `values` 换成 `UInt128`（`f_util/src/UInt128.cj` 已有 `toBytes`/`fromBytes`）或两个 `Int64`；`toString` 走 `UInt128.toBytes()` 按需生成，`compare` 改成两次 `Int64` 比较，`BigInt(true, values)` 只在 `toString(radix:)` 里按需转。
- **预期**：每个 UUID 少 1 次堆分配、结构体从「8 B + 堆对象」变成 16~20 B 内联；`==`/`compare` 少一次指针追随。
- **代价**：`compare` 的字节序语义要重算（当前是大端逐字节），`toData`/`tryFromData`/`custom`/`md5`/`sha1` 全部要改取值方式；`UInt128` 自身的 `hashCode` 低位碰撞问题（part3 #11 提及）会影响 `Hashable` 质量，需要一并评估。
- **验证**：`getAllocatedHeapSize()` 前后差 / 10^6 个 UUID 的分配次数与峰值；`cjprof heap` 看 `Array<Byte>` 是否从热点分配列表中消失。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

<!-- 第 1 部分 -->

> 无性能测试数据，均不作为结论，不进 `todo.md` / `tasks.md`。相关实现文件属 part2–part4，此处只记录本轮读文档时形成的线索。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ISO-HDLC 硬件路径每次 `update` 都切 `data[0..aligned]`，4 KiB 帧会多一次整段拷贝，可能抵掉部分硬件收益；README 的 4 KiB 475 ns 未说明是否已包含该拷贝 | `f_util/src/crc32.cj:97-104`（范围外，part3）；文档 `f_util/README.md:92` | 4 KiB 输入下切片拷贝的耗时占比 | `cjprof record` + 分段计时（拷贝前后各打点），同机 `-O2`，4096 B × 10^5 次，取中位数与 P99 |
| 2 | `Crc32Hw.ensureReady` 每次 `update` 都进一次 `Mutex`，多线程小包场景下锁竞争可能成为串行点（perf 文档只给了「几十 ns」的单线程估计） | `f_util/src/crc32_native_x86.cj:158-176`（范围外，part3） | 8/16 线程下的锁等待时间与吞吐曲线 | 多线程 4 KiB bench，对比 `nativeEnabled` 开关两态；辅以线程状态采样（BLOCKED 占比） |
| 3 | `CaseFormat.convert` 每次调用分配一个 `StringGenerator` 与一个目标实例；宏展开期按字段数批量调用，分配量可能可观 | `f_util/src/CaseFormat.cj:48-63` | 单次分配字节数、在宏展开总耗时中的占比 | `cjprof heap` 或 `getAllocatedHeapSize()` 前后差，输入 10^5 次转换；同时测 `-O2` 下总耗时 |
| 4 | `TextTemplate` 的进程级静态缓存键含模板/前缀/后缀且无容量上限，模板串若由运行期数据拼接会无界增长 | `f_util/src/TextTemplate.cj:54,68-70`（范围外，part3）；设计已承认为已知问题 `doc/spec/fix-text-template-cache-key/design.md:25,61` | 真实调用方的模板串基数与增长率 | 在各模块 `compile` 调用点加计数埋点，跑 24h 稳态负载，观察条目数与 RSS |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `CrcEngine.update` 每次调用 `acquireArrayRawData` 3/5/9 次（数据 + 2/4/8 张表）在小帧场景下开销显著，可能抵消切片收益 | `f_util/src/CrcEngine.cj:238-277`、`281-363`、`366-407` | 4 KiB 帧的单次 acquire/release 占比 | `cjprof record` 跑 f_protocol 帧校验场景（4 KiB × 10 万帧），看 `acquireArrayRawData` 自耗时；与"只在构造期 acquire、长期持表指针"版本对照 |
| 2 | `Fnv.update` 在逐字节循环里 `match (variant)` 分支，1024 位长输入是热点 | `f_util/src/Fnv.cj:314-325` | 自耗时占比、输入规模 | `cjpm bench -O2` 对 1 MiB × {FNV1, FNV1A} × {W64, W1024} 各 10 轮；再用 `cjprof` 看 `mulPrime` / `update` 占比 |
| 3 | `PathPattern.matches` 每请求都 `trimRedundantSlash` + `split` + 多次 `HashMap` 查找/正则匹配，是路由瓶颈 | `f_util/src/PathPattern.cj:477-491`、`174-179`、`627-634` | 端到端 P99 与 `matches` 自耗时 | 对 f_mvc 的 100 条路由、10 万次请求压测，`cjprof` 取 `PathPattern.get`/`matches` 自耗时；再与"预编译段数组"版本对照 |
| 4 | `murmurHash` 在 f_codec 序列化热路径上（每次编解码一次）的切片分配占 GC 压力的一部分 | `f_util/src/MurmurHash3X128.cj:39-43`；调用方 `f_codec/src/default/DefaultCodec.cj:87` | 分配量与 GC 次数 | 跑 f_codec 编解码基准（1 万对象），`cjprof heap` 比较修复前后 `getAllocatedHeapSize()` |
| 5 | `IdMaker` 的 CAS 在 fdbm 批量插入（单线程/多线程）下不构成瓶颈，但"每条需补 ID 的 INSERT 都 new IdMaker"会额外分配 | `f_util/src/IdMaker.cj:28-42`；`fdbm/src/execute/executors.cj:898` | 每语句分配对象数、插入吞吐 | 1 万条 INSERT 的分段计时 + 分配量埋点；修正 #3 后再测一次 |

<!-- 第 3 部分 -->

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ISO-HDLC 硬件路径每次 `update` 的 `data[0..aligned]` 整段拷贝可能吃掉相当一部分硬件收益（第 1 部分待验证 #1 已提出，本部分确认位置与机制，见 O1） | `f_util/src/crc32.cj:99-103` | 4 KiB 下单次拷贝耗时占 `compute` 的比例 | `cjpm bench -O2`：`compute(data)` vs 去掉切片版（`Crc32Hw.update(data, aligned)`），4 KiB × 10^5 次，中位数 + IQR |
| 2 | `Crc32Hw.ensureReady` 每次 `update` 都进一次 `Mutex`，多线程小包场景可能成为串行点（第 1 部分待验证 #2） | `f_util/src/crc32_native_x86.cj:159-179`、`f_util/src/crc32_native_arm.cj:129-144` | 8/16 线程下锁等待时长与吞吐曲线 | 多线程 4 KiB bench，对比 `F_UTIL_CRC_HW=0` 与 `=1` 两态；线程状态采样看 BLOCKED/WAITING 占比（CPU profile 看不出来） |
| 3 | `TextTemplate.compile` 在每条带参日志上都要拼一次缓存键（3 段字符串拼接 + 2 次 `size` 转十进制）再查 `ConcurrentHashMap`，可能是 `f_log` 的单次固定开销 | `f_util/src/TextTemplate.cj:69,80-82`；调用点 `f_log/src/base/Logger.cj:51` | 单次 `compile` 命中路径耗时占一条日志总耗时的比例 | `cjprof record` 跑日志压测（10 万条模板固定的日志，8 线程），看 `cacheKey` / `compile` 自耗时；与「调用方缓存编译结果」版本对照 |
| 4 | `TextTemplate` 静态缓存的条目增长率在真实 `f_log` 用法下可能远超「模板种类数」 | `f_util/src/TextTemplate.cj:54,68-75`；见 #6 | 24h 稳态负载下的条目数曲线与 RSS | 在 `compile` 命中/未命中处加计数埋点，跑 24h 观察条目数是否收敛；同时记 `getAllocatedHeapSize()` 与 RSS |
| 5 | `Crc64Hw.mode()` 无同步惰性初始化在首次并发 `update` 时的可见性问题（#11）在 x86 与 arm 上是否表现为重复 `getenv` 之外的行为（如 `modeState` 读到中间值） | `f_util/src/crc64_native_x86.cj:284-293`、`crc64_native_arm.cj:276-285` | 并发首次调用的实际行为 | 8 线程同时首次调用 `Crc64.xz.compute`，统计 `modeState` 观测值；或在 `mode()` 里加临时计数看 `parseMode` 被调次数是否 > 1 |

<!-- 第 4 部分 -->

> 没有性能测试数据支撑的猜测，不作为结论，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `UUID.toString` 的 `StringGenerator` + 36 次 append 在按行生成主键时占单次取号耗时的主要部分 | `f_util/src/uuid.cj:85-101`；调用方 `fdbm/src/idmaker/IdMakers.cj:71` | `toString` 自耗时占比、单次分配字节数 | `cjprof record` 跑 10^6 次 `UUID.random().toString()`（`-O2`），对比 O1 实现 |
| 2 | `wyhash` 的逐字节边界检查在布隆过滤器多 seed 场景下是可测开销 | `f_util/src/wyhash.cj:53-101`；调用方 `f_bloom/src/BloomFilter.cj:61` | 每次 hash 的 ns 与边界检查占比 | `cjpm bench -O2`，`size = 64/1024`，`seeds = 1/8`，对比 std 的 unchecked 版本 |
| 3 | `UUID` 每实例一次 16 字节数组分配在 fdbm 批量生成时占分配量的大头 | `f_util/src/uuid.cj:37-40` | 分配次数与单实例字节数、GC 次数 | `getAllocatedHeapSize()` 前后差 + `cjprof heap`，输入 10^6 个 UUID |
| 4 | `registerFileSequenceGenerator` 的单次 `fsync` 延迟（毫秒级）会让并发取号吞吐掉两个数量级 | `f_util/src/uuid.cj:650-688` | 单次取号延迟 P50/P99、并发吞吐 | 打开文件版，8 线程 × 10^4 次取号，分段计时 + 线程状态采样（BLOCKED 占比） |

## 文件覆盖

> 与 `files/f_util.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/README.md` | .md | ✅ | — |
| 2 | `f_util/README_en.md` | .md | ✅ | — |
| 3 | `f_util/doc/perf/crc32-codegen.md` | .md | ✅ | — |
| 4 | `f_util/doc/spec/accelerate-f-util-crc/design.md` | .md | ✅ | — |
| 5 | `f_util/doc/spec/accelerate-f-util-crc/proposal.md` | .md | ✅ | — |
| 6 | `f_util/doc/spec/accelerate-f-util-crc/specs/f-util-crc/spec.md` | .md | ✅ | — |
| 7 | `f_util/doc/spec/accelerate-f-util-crc/tasks.md` | .md | ✅ | — |
| 8 | `f_util/doc/spec/crc32-hw-cfunc/design.md` | .md | ✅ | — |
| 9 | `f_util/doc/spec/crc32-hw-cfunc/proposal.md` | .md | ✅ | — |
| 10 | `f_util/doc/spec/crc32-hw-cfunc/tasks.md` | .md | ✅ | — |
| 11 | `f_util/doc/spec/crc64-x86-hw-fix/design.md` | .md | ✅ | — |
| 12 | `f_util/doc/spec/crc64-x86-hw-fix/proposal.md` | .md | ✅ | — |
| 13 | `f_util/doc/spec/crc64-x86-hw-fix/tasks.md` | .md | ✅ | — |
| 14 | `f_util/doc/spec/f-jit-m1/specs/f-util-fnv/spec.md` | .md | ✅ | — |
| 15 | `f_util/doc/spec/fix-text-template-cache-key/design.md` | .md | ✅ | — |
| 16 | `f_util/doc/spec/fix-text-template-cache-key/proposal.md` | .md | ✅ | — |
| 17 | `f_util/doc/spec/fix-text-template-cache-key/spec.md` | .md | ✅ | — |
| 18 | `f_util/doc/spec/fix-text-template-cache-key/tasks.md` | .md | ✅ | — |
| 19 | `f_util/doc/设计模式.md` | .md | ✅ | — |
| 20 | `f_util/src/CaseFormat.cj` | .cj | ✅ | — |
| 21 | `f_util/src/CaseFormat_test.cj` | .cj | ✅ | — |
| 22 | `f_util/src/CityHash.cj` | .cj | ✅ | — |
| 23 | `f_util/src/CrcEngine.cj` | .cj | ✅ | — |
| 24 | `f_util/src/CrcEngine_test.cj` | .cj | ✅ | — |
| 25 | `f_util/src/CrcGf.cj` | .cj | ✅ | — |
| 26 | `f_util/src/CrcGf_test.cj` | .cj | ✅ | — |
| 27 | `f_util/src/DiffieHellmanKeyExchanger.cj` | .cj | ✅ | — |
| 28 | `f_util/src/Factory.cj` | .cj | ✅ | — |
| 29 | `f_util/src/Fnv.cj` | .cj | ✅ | — |
| 30 | `f_util/src/Fnv_test.cj` | .cj | ✅ | — |
| 31 | `f_util/src/IdMaker.cj` | .cj | ✅ | — |
| 32 | `f_util/src/IsUUID.cj` | .cj | ✅ | — |
| 33 | `f_util/src/Mediator.cj` | .cj | ✅ | — |
| 34 | `f_util/src/MurmurHash3X128.cj` | .cj | ✅ | — |
| 35 | `f_util/src/PathPattern.cj` | .cj | ✅ | — |
| 36 | `f_util/src/PathPattern_test.cj` | .cj | ✅ | — |
| 37 | `f_util/src/ResposibilityChain.cj` | .cj | ✅ | — |
| 38 | `f_util/src/StatePattern.cj` | .cj | ✅ | — |
| 39 | `f_util/src/StrategyPattern.cj` | .cj | ✅ | — |
| 40 | `f_util/src/TextTemplate.cj` | .cj | ✅ | — |
| 41 | `f_util/src/TextTemplateCacheKey_test.cj` | .cj | ✅ | — |
| 42 | `f_util/src/TreeTransformer.cj` | .cj | ✅ | — |
| 43 | `f_util/src/UInt128.cj` | .cj | ✅ | — |
| 44 | `f_util/src/Utils.cj` | .cj | ✅ | — |
| 45 | `f_util/src/code_buffer.cj` | .cj | ✅ | — |
| 46 | `f_util/src/crc16.cj` | .cj | ✅ | — |
| 47 | `f_util/src/crc32.cj` | .cj | ✅ | — |
| 48 | `f_util/src/crc32_codegen_test.cj` | .cj | ✅ | — |
| 49 | `f_util/src/crc32_hw_kind.cj` | .cj | ✅ | — |
| 50 | `f_util/src/crc32_native_arm.cj` | .cj | ✅ | — |
| 51 | `f_util/src/crc32_native_stub.cj` | .cj | ✅ | — |
| 52 | `f_util/src/crc32_native_x86.cj` | .cj | ✅ | — |
| 53 | `f_util/src/crc64.cj` | .cj | ✅ | — |
| 54 | `f_util/src/crc64_native_arm.cj` | .cj | ✅ | — |
| 55 | `f_util/src/crc64_native_stub.cj` | .cj | ✅ | — |
| 56 | `f_util/src/crc64_native_x86.cj` | .cj | ✅ | — |
| 57 | `f_util/src/crc_check_test.cj` | .cj | ✅ | — |
| 58 | `f_util/src/exception/GeoHashException.cj` | .cj | ✅ | — |
| 59 | `f_util/src/exception/HashException.cj` | .cj | ✅ | — |
| 60 | `f_util/src/exception/IdException.cj` | .cj | ✅ | — |
| 61 | `f_util/src/exception/TextTemplateException.cj` | .cj | ✅ | — |
| 62 | `f_util/src/exception/UUIDException.cj` | .cj | ✅ | — |
| 63 | `f_util/src/geohash.cj` | .cj | ✅ | — |
| 64 | `f_util/src/prime.cj` | .cj | ✅ | — |
| 65 | `f_util/src/uuid.cj` | .cj | ✅ | — |
| 66 | `f_util/src/uuid_test.cj` | .cj | ✅ | — |
| 67 | `f_util/src/wyhash.cj` | .cj | ✅ | — |

合计：`.cj` 48 个 / `.md` 19 个 / 共 67 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：`CaseFormat.convert` 空串、单字符、首尾分隔符、六向互转均手工推演通过；语言特性：结合 `define_functions.md:95-113` 修正了两处「无返回类型=Unit」的误判（`semi` / `TreeNode.transform` 是类型推导，不是丢弃返回值），避免了误报；设计：文档与实现的契约对齐问题见 #2–#6 |
| §1 死代码 | 0 | 逐个符号搜索：`private` 仅 `sectionStart`（3 处使用）与 `DELIMITER`（每类 2 处使用）；`protected` 的 `withDelimiter`/`convert(ch,…)`/`delimiter`/`isDelimiter`/`new` 均在基类 `convert`（`CaseFormat.cj:50-59`）被调用并被子类覆盖；`public` 成员所在顶层类型非 public，但 `f_orm/src/macros/*` 与 `CaseFormat_test.cj` 有引用，不算死代码；`import StringGenerator` 已使用；无 `return` 后语句、无恒真/恒假分支 |
| §2 重复逻辑 | 2 | #11（六个子类同构，逐行比对 6 个 `convert` + 4 个 `delimiter` + 4 个 `isDelimiter`）；#8（`设计模式.md` 与 README 逐字重复，跨文件比对 5 个模式段落） |
| §3 空实现 | 0 | `CaseFormat` 无空函数体、无 `TODO`、无吞异常；文档中 `ValidationResponsibility.execute {}` 是刻意的 no-op 默认实现（`ResposibilityChain.cj:41`，范围外），语义上等价于标记接口，不计 |
| §4 栈溢出 | 0 | `CaseFormat` 全程单层 `for (ch in text.runes())`，无递归、无间接递归；本部分文档未描述递归遍历（PathPattern / TreeTransformer 的递归在 part2 / part3，不在本部分主张） |
| §5 OOM | 0 | 本部分实现无容器、无预分配、无全量物化、无按不可信长度开数组；`TextTemplate` 静态缓存无上限属范围外（`TextTemplate.cj:54`），已在待验证假设 #4 记录 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 `cjprof` / `cjpm bench` 原始输出；README 中的 MB/s 与 ns 是变更当时的数据，无法归因到具体行，全部转为待验证假设 #1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无锁代码；文档提到的 `ensureReady` 锁属 part3，且临界区内只是读 `ready`，无 I/O/解析，不构成大粒度锁 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 队列；未发现「提交后立即 get」形态 |
| §6.4 低效算法 | 0 | `CaseFormat.convert` 为 O(n) 单遍 + O(1) 追加，分隔符判断 O(1)；无嵌套循环、无 `remove(at: 0)`、无循环内字符串拼接 |
| §7 降堆内存方案 | 0 | 无基线数据，`CaseFormat` 每次分配的 `StringGenerator`/目标实例未量化，只能留在待验证假设 #3 |
| §8 降 CPU 方案 | 0 | 同上；合并子类（#11）是维护性收益，未测出 CPU 收益，不写成优化结论 |
| §9 local mode 可行性 | 0 | `CaseFormat` 每次调用的临时对象极小，且返回的 `String` 由 `StringGenerator` 产出后逃逸；无峰值内存对照数据，按 §9 只能判「待验证假设」，本轮不单列 |
| §11 现有代码的 BUG（存量） | 0 | 本部分源码仅 `CaseFormat.cj`：空串、单字符、首尾分隔符、非 ASCII rune、源=目标格式均核对通过，无边界/空值缺陷；另有 3 条跨文件线索见「范围外提示」，按要求不计入本表 |
| §12 并发安全与锁粒度 | 0 | `CaseFormat` 的静态单例无可变状态：`convert` 每次 `to.new()` 生成新目标实例，`sectionStart` 只写在新实例上；`LowerUnderScore` 等 `new()` 返回共享单例但自身无字段，故无线程共享写路径 |
| §14 功能完备性与 README 覆盖 | 2 | #2（FNV 公开 API 未按现实现文档化：`Fnv.hash`、`FnvHasher.update/finish`、`Fnv1024`）；#4（README 承诺的 jamcrc 硬件路径不存在）；另 `Crc16/Crc32/Crc64` 的 `name` / `checkValue` 字段未进 README，属次要参数，仅记录不计数 |
| §13 文档一致性 | 7 | #2/#3/#4/#5/#6/#7/#10 共 7 条文档与代码不符或过期；其余 `.md` 已逐份与源码/相邻文档对照，无新增不一致 |
| 文件覆盖 | 20/20 | 与 `files/f_util.part1.txt` 逐行对应，无缺失（见上表） |

### 范围外提示（不计入本部分统计，供对应部分复核）

1. `f_util/src/geohash.cj:31-60`：`encode` 在「值落在区间下半」时置位 1 并把下界抬到中点（`midlng >= longitude → lowlng = midlng`），`decode`（`:66-98`）却把位 1 解释为上半区，`encode → decode` 不可逆（`encode(-90, 0)` 解回约 `+180`）。属 part4。
2. `f_util/src/crc32_native_x86.cj:193-198`：`envEnabled()` 只把 `"0"` 视为关闭，其余（含 `off`/`auto`）都视为开启；与 CRC-64 的三态解析（`crc64_native_x86.cj:295-308`）不一致，同一个环境变量在两族 CRC 上语义不同。属 part3。
3. `f_util/src/TextTemplate.cj:54,68-70`：进程级 `ConcurrentHashMap` 无容量/淘汰，键含模板原文；设计文档已列为已知问题（`doc/spec/fix-text-template-cache-key/design.md:25`）。属 part3。

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5（#1–#5） | 另 #11–#13、#19 属正确性/可读性；语言特性方面核对了单引号字符串（`strings.md:9`）、返回类型推导（`define_functions.md:85-95`）、`as` 返回 `Option`（`typecast.md:54`），未发现误用 |
| §1 死代码 | 1（#14） | 已逐个 `private` / 内部类型成员全仓搜引用（`mur`、`rotate32`、`PathNode` 的 5 个 `init`、`data(Any)`、`Option.matches`、`Mode.matching`）；`public` 顶层 API 不判（`DiffieHellman*`、`Mediator`、`Strategies`、`cityHash` 仓内零引用只作信息）；接口实现/父类覆盖不判 |
| §2 重复逻辑 | 2（#15、#16） | 已把 19 个文件的函数体按"输入→输出→副作用"两两比对：`hashLen16`/`hashLen16Minimal`、`pretreat`/`trimRedundantSlash`、`Mediator`/`Strategies` 三组重复（#16），以及测试侧 `refBarrettMuLow`/`refMod128` 与被测实现同构（#15）；CRC 逐位参考实现（`refCrc64*` 与 `CrcEngine_test.refUpdate`）属刻意独立，不计 |
| §3 空实现 | 1（#12） | `ValidationResponsibility.execute` 空体；`Producer.produce` 默认抛异常（非空实现，但把编译期问题推到运行期，已在 #13 一并记录）；`IsUUID`、`State.continues` 的默认实现有语义、非空 |
| §4 栈溢出 | 1（#11） | `State.startup` 递归无上限、无环检测；`PathPattern` 的正则/复杂段匹配是循环不是递归；`Fnv`/`CRC` 无递归 |
| §5 OOM | 0 | 无"按报文长度预分配"；`PathPattern.patterns` 只按路径段数增长（有界于 URL 长度），已并入 #10 的锁粒度描述；`Fnv`/`CRC` 的临时数组是常量大小 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `bench` 数据，`CrcEngine` 注释里的 51–58 MB/s 是历史测量但非本轮可得基线；全部转「待验证假设」1–5 |
| §6.2 大粒度锁 | 0 | `PathPattern` 的锁只在编译/首次建节点时持有，临界区含正则替换属"冷路径"；竞争频率与持有时长无数据，见 #10 与待验证 #3 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get()`；`Crc64Hw` 的硬件路径是单线程计算（第 1 部分文件，未展开） |
| §6.4 低效算法 | 0 | 未发现"`remove(at:0)` 当队列 / 热点 `contains` / 循环拼串"；`getRegexNode` 的线性扫描规模是"同层路由数"，量级小，未定为缺陷 |
| §7 降堆内存方案 | 1（O3） | 另有 O1 的切片分配；均无基线，只列方案 |
| §8 降 CPU 方案 | 2（O1、O2） | 无基线，只列方案；热点结论全部在「待验证假设」 |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内销毁"的大对象图：`FnvCore` 会逃逸到 `FnvHasher`，`PathPattern` 节点长期存活，`CrcEngine` 的临时量是标量；且 `String.split`/`Regex.replaceAll` 无 mode 重载，改造被 checklist §9 约束 3 卡住。收益只能用峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 12 | #1–#5（崩溃/错误结果/死循环）、#6–#10、#13、#19 中的功能项；每个读到的函数都过了边界/空值/错误处理/契约四项 |
| §12 并发安全与锁粒度 | 1（#10） | 逐项核对：`IdMaker` 用 `AtomicInt64`（但语义错，见 #3）、`CrcEngine` 构造后不可变、`Fnv.hash` 全局部量、`FnvHasher` 可变但属"每线程一个"用法、`Mediator`/`Strategies`/`PathPattern.patterns` 均为启动期写 + 运行期读（`PathPattern` 例外，已列 #10）；`Mutex` 为可重入锁（`sync_package_overview.md:137`），`doCompile → getPathNode → populateNode` 的嵌套 `synchronized` 不会自锁 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 README/`doc/**`（由其它部分覆盖）；就代码侧：`{*name}` 的归一化只在 `compileIfAbsent` 生效（已列 #6），`DiffieHellman` 的 `semi`/`finish`/`key` 三入口都已接线、但语义不可用（#4）；`randomByteLen`（`DiffieHellmanKeyExchanger.cj:106-113`）仓内零引用，属对外 API 不作死代码判定 |
| 文件覆盖（§13 等） | 19/19 | 无缺文件；本部分 0 个 `.md`，`§13` 文档一致性留给含 README 的部分 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7（#1、#2、#3、#4、#5、#8、#9） | 正确性：#1–#5、#8、#9；设计：#6（缓存策略）、#13（平台无关逻辑与机器码混在一个文件）；语言特性：核对了 `Option` 解构（`if (let Some(x) <- …)`）、`match` 类型模式、`BigInt(sign, magnitude)`、`Array` 切片语义、`?String` 的 `isEmpty` 用法；安全：#1/#2 的 `replaceAll`/`regex()` 误用会接受运行期格式串（`Regex` 由外部模板构造，存在正则回溯面，但未发现可构造的灾难性回溯，`待确认`，未单列） |
| §1 死代码 | 1（#12） | 已逐个符号搜：`private` 的 `mutex`、`ValueGetter.init(indexText:)`、`CodeBuffer.ptr`（`sealed` 有真实使用，不判）、`Crc64Hw` 的静态入口（均被 `CrcEngine` 或测试使用）、`Crc32Hw.available()`（零命中）；`internal` 的 `CodeBuffer` 全部方法（`alloc/write/seal/rawPointer/pageSize`）都有调用；`public` 顶层 API 一律不判（`UInt128`、`Crc16/32/64`、`TreeNode`、两个异常类、`computeBytes` 仓内零引用只作信息）；`Value2String` 是 `sealed` 类，其 `protected format` 被 `:193` 调用、4 个子类的 `doFormat` 被 `:270-273` 调用，无死代码 |
| §2 重复逻辑 | 1（#13） | 同文件内两两比对了 `TextTemplate` 的 40+ 个函数体（`Value2*String.doFormat` 三份结构相似但格式化逻辑不同，非重复）、`crc16/32/64` 的 15 个方法（同构，#13）、CRC 四份 native 实现（#13）；跨文件比对了 `envEnabled`、`cpuFlags`、`mode/parseMode/isOff`、`resetForTest` 四组（逐行相同）；`Number`/`Time` 两个分支的格式解析结构相似但格式化目标不同，已在 #15 记录「近似重复导致一处少了边界判断」 |
| §3 空实现 | 0 | 逐文件核对：`Crc32Hw`/`Crc64Hw` 的 stub 是**条件编译**下的平台空实现（有明确注释与 `@When`，非「忘记覆盖」）；`CodeBuffer`、`TextTemplate` 无空函数体；本部分无 `TODO`/`FIXME`；无 `catch (_: Exception) {}` 吞异常（`cpuFlags`/`hasPclmul` 的 `catch` 返回 `""`/`false` 是探测降级，有语义）。#5 的「兜底写了但被丢弃」按 §3 的反向形态记在「发现」而不是本节 |
| §4 栈溢出 | 0 | 本部分无递归：`TextTemplate.doCompile` 是 `while` + 闭包（闭包不递归），`Value2String.format` 是单层类型分派，CRC 全为循环，`TreeNode` 无递归遍历（只做一层父子装配）。`computeBytes` 的两个重载是委托不是递归 |
| §5 OOM | 2（#6、#7） | #6 缓存无容量/无淘汰（键含模板原文）；#7 空分隔符导致 `compiled` 无限增长。其余：`CodeBuffer.alloc` 按页向上取整、`size <= 0` 返回 `None`；CRC 的临时对象是常量大小；`UInt128.toBytes` 固定 16 字节。`TextTemplate` 的 `ArrayList` 无「按不可信长度预分配」 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`f_util/doc/perf/crc32-codegen.md` 与 README 的 ns/MB·s 数字是变更当时的测量，无法归因到本部分代码行，全部转「待验证假设」1–5 |
| §6.2 大粒度锁 | 0 | 唯一的锁是 CRC 四份 native 实现的 `ensureReady` 静态 `Mutex`（临界区只做 CPU 探测 + `mmap` + 改静态字段，无 I/O 阻塞、无日志、无回调），竞争频率无数据，见待验证 #2；`TextTemplate` 的 `Mutex` 字段已无使用（#12） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 队列（`crc32_codegen_test` 的 4 线程用例是测试自身）；未发现「提交后立即 get」 |
| §6.4 低效算法 | 0 | 未发现 `remove(at:0)` 当队列、热点 `contains`、循环拼串。`TextTemplate.doCompile` 每轮 `indexOf` 从当前位置续扫，整体 O(n)；`ValueGetter.get` 的 `TypeInfo.of(data).qualifiedName` 每次取值算一次（`TextTemplate.cj:245-248`），属常数开销，无数据不列为低效 |
| §7 降堆内存方案 | 0 | 本部分可降的对象是 O1 的整段切片（记为 CPU 方案，机制同时减少一次分配）；`TextTemplate` 缓存条目属 #6 的有界化建议，不是「还能更省」；其余临时对象都是标量/常量大小 |
| §8 降 CPU 方案 | 1（O1） | 无基线，只列方案 |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内销毁的大对象图」：`TextTemplate.format` 的 `StringGenerator` 与结果 `String` 都逃逸；`Value2NumberString` 的 `Decimal`/`BigInt` 是 std 类型且无 mode 重载（checklist §9 约束 3）；CRC 的 `acquireArrayRawData` 拿的是调用方数组的裸指针，改成 local region 反而破坏「输入不复制」的前提。收益只能用峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 9（#1–#5、#8、#9、#10、#11） | 逐函数过了边界/空值/错误处理/资源/并发/契约六项：#1–#5（TextTemplate）、#8（Utils）、#9（TreeTransformer）、#10/#11（CRC 开关）。CRC 计算路径（`crc16/32/64` + 四份 native + `crc_check_test`）边界（0/1/15/16/17/4095/4096/65536）已由测试覆盖且我逐条核对了分派与尾部处理，未发现缺陷；`UInt128` 的 `hashCode` 用 `(left ^ right).toInt()` 只保留低位，属容器性能与碰撞率问题（无数据，不单列） |
| §12 并发安全与锁粒度 | 1（#11） | 逐项核对：`TextTemplate` 的 `templates` 是 `ConcurrentHashMap` + `computeIfAbsent`（同一 key 只构造一次，`compiled` 在发布前写完，实例发布后只读）；`CodeBuffer` 实例构造后 `sealed` 只按 false→true 单向变化，且只在初始化线程上写；`Crc32Hw`/`Crc64Hw` 的 `ready`/函数指针/`codes` 都在 `Mutex` 内写，读在 `ensureReady()` 之后（有 mutex 的释放-获取建立可见性）；**例外**是 #11 列的 `mode()/lastNative/forcedOff/nativeEnabled`，已单列 |
| §14 功能完备性与 README 覆盖 | 2（#2、#10） | #2：README/类注释承诺的 `regex:` 占位符没有入口；#10：`F_UTIL_CRC_HW=on` 这个「已接线」的配置项实际无效果（`On` 只在 `modeNameForTest()` 出现）。`Crc16/32/64` 的 `name`/`checkValue` 未进 README 属次要参数（第 1 部分已记录）；本部分其余 `public` 符号（`UInt128` 全套、`computeBytes`、`TreeNode`、`CrcHwKind` 枚举）在 README 中是否逐项覆盖由第 1 部分负责核对 |
| §13 文档一致性 | 0（本部分无 `.md`） | 本部分 0 个 `.md`；引用到的三份文档只作证据：`fix-text-template-cache-key/design.md:51`（称 `Mutex` 用于其它路径，实际未用 → 并入 #12）、`design.md:61`（缓存无上限属已知问题 → #6）、`CrcGf.cj:24`（`on` 强制尝试 → #10）。文档与实现的系统性对照见第 1 部分 |
| 文件覆盖 | 20/20 | 与 `files/f_util.part3.txt` 逐行对应，无缺失（见上表） |

### 范围外提示（不计入本部分统计，供对应部分复核）

1. `f_util/src/crc32_native_stub.cj:23` 的 `@When` 缺 `Linux && arch ∉ {x86_64, aarch64}`，与 `crc64_native_stub.cj:24` 不一致——已由第 1 部分 #1 报告，本部分不重复。
2. `f_util/src/TextTemplate.cj:35-36` 的类注释仍宣称依赖 `ThreadLocalStringBuilder`（该依赖已不存在）——已由第 1 部分 #7 报告（README 侧）；类注释这一处是同源残留，建议与文档一并删。
3. `f_util/src/MurmurHash3X128.cj:23` 的 `HashException` 是未使用 import——已由第 2 部分 #17 报告；修本部分 #3（`UInt128.fromBytes` 补 `throw`）不会影响它。

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性：#1/#1b/#2/#3/#4/#5/#6/#9；设计：#7/#12（builder 的可变状态与两段式协议）、#8（扩展点把阻塞搬进主路径）；可读性：#10/#11/#13。语言特性核对过：无返回类型的函数是**类型推导**（`define_functions.md:95-113`），不算缺陷；枚举构造器可不带类型名使用（`enum.md:80-98`），所以 `uuid.cj:508` 的 `Read` 不是编译错误，未报；`BigInt(true, values)` 的 `sign=true` 是「非负数」（`math_numeric_package_structs.md:157-176`），`toString(radix:)` 无符号问题；`Array<T> ==` 是逐元素结构相等（`core_package_structs.md:2011-2021`）。安全：`UUID.random` 的随机源是 `f_random.ThreadLocalRandom` → `stdx.crypto.SecureRandom`（`f_random/src/ThreadLocalRandom.cj:24-31`），v4 不可预测，无弱随机问题 |
| §1 死代码 | 2 | #10（未使用 import + 孤立表达式）。逐个符号搜过：所有 `private` 常量/字段/辅助函数（`geohash.cj` 4 个坐标常量、`uuid.cj` 的 `h`/`hex`/`toString(withDash:)`/`generate`/`timeLowFirst`/`genTimestampAndSequence`/`emptyCloser`/`timeStart`/`mutex`/`seqGen`/`closer`、`wyhash.cj` 的 `SECRET0-3`/`mix`/`r4`/`r8`）与 `internal` 入口（`UUID(values:)`、`TimeBasedUUIDBuilder.init`、`TimestampSequenceBuilder.init`/`timestampAndSequence`、`SequenceResource(...)`）都有真实调用；`protected` 本部分为 0；`public` 顶层（异常类、`UUID`、`GeoHash`、`TimeBasedUUIDBuilder`、`TimestampSequenceBuilder`、`SequenceResource`、三个 `prime` 函数、4 个 `wyhash` 重载）对外可达，一律不判；`uuid_test.cj` 的 `@Test` 类不算死代码 |
| §2 重复逻辑 | 1 | #11（`doParse` 与 `ether.parse` 同语义不同大小写行为；5 处 version/variant 打戳字面量复制）。另比对了 `md5`/`random`/`sha1`/`unixTimeBased`/`custom` 五个构造函数体、`timeLowFirst` 与 `timeHighFirst`、`node(Int64)` / `node(UInt64)` / `node(Array)`（位序不同，不合并）。三个异常类为 4 个构造器的语言样板（子类不能继承构造器），不判重复 |
| §3 空实现 | 0 | 本部分无空函数体、无 `TODO`/`FIXME`、无 `catch {}` 吞异常。`SequenceResource.empty`（`:725`）是 Null Object，缺一句「为什么可以空」的注释，属可读性细节不单列；`#4` 的「校验写了一半」按 §11 记在「发现」而非本节 |
| §4 栈溢出 | 0 | 唯一递归是 `UUID.tryFromData` 的 `case x: DataAny => tryFromData(x.data, flag)`（`:47`），每层解一层且 `DataAny.new`（`f_data/src/base/DataAny.cj:23-27`）已把嵌套扁平化，深度由调用方手工嵌套决定，不构成无界递归；geohash/prime/wyhash 全为定长或 `while` 循环 |
| §5 OOM | 0 | 无全量物化、无按不可信长度预分配、无全局容器。`randomMd5/randomSha1` 的 `bytes` 是调用方给定长度（已在 #9 建议加上限）；`custom` 固定输出 16 字节；`registerFileSequenceGenerator` 的缓冲固定 10 字节 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 `cjprof` / `cjpm bench` 原始输出；所有性能判断转「待验证假设」1–4，未进「发现」 |
| §6.2 大粒度锁 | 1 | #8（`synchronized(mutex)` 内做 seek/read/write/flush）。同一把锁在默认/原子生成器下只包 `DateTime.now()` 与一次闭包调用，临界区很短，不构成 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 队列；`uuid_test.cj` 无线程 |
| §6.4 低效算法 | 0 | 未发现嵌套循环、`remove(at: 0)`、循环拼串、重复编译正则。`tryParse` 单遍 O(36)、`toString` 单遍 O(16)、`compare` O(16)、geohash 定长 32 轮，均线性且常数小；`prime` 的 `isPrime` 每轮分配一个 5 元素数组（`:63`）属常数级，并入 #3 建议 |
| §7 降堆内存方案 | 1（O3） | O3：`UUID` 的 16 字节数组改为内联 `UInt128`。无基线，只列方案 |
| §8 降 CPU 方案 | 2（O1、O2） | O1（`toString` 的 `StringGenerator`）、O2（`wyhash` 边界检查）；均无基线 |
| §9 local mode 可行性 | 0 | 本部分可纳入 local region 的只有 `toString` 的 `StringGenerator` 与 `encode` 的标量计算，前者分配量极小且结果 String 逃逸；`f_util` 未启用 local mode，收益只能用峰值内存证明，当前无数据，不列方案 |
| §11 现有代码的 BUG（存量） | 8 | #1/#1b/#2/#3/#4/#5/#6/#9。逐个函数过了边界/空值/错误处理/资源/契约：geohash 四象限与 0/31/33 字符输入、prime 的 `p<2`/`p==a[i]`/偶数、uuid 的 8 个构造函数与 3 个序列生成器、wyhash 的 0/1/3/4/7/8/16/17/48/49 长度分支均按源码复算或对比 std 实现；`wyhash` 未发现偏差 |
| §12 并发安全与锁粒度 | 1 | #7（builder 可变字段无同步、`registerSequenceGenerator` 锁外替换）。`GeoHash`/`prime`/`wyhash` 纯函数；`UUID.Nil`/`Max` 是 `static let` 结构体，`values` 私有且构造后不再改写（`:325`/`:336` 都是先改数组再构造），共享安全；`SequenceResource` 的闭包只持有 `File`，`close()` 有 `isClosedFn` 守卫但不保证幂等并发调用，属 #8 同一族的扩展点，未单列 |
| §14 功能完备性与 README 覆盖 | 1 | #13（测试只覆盖 v4）。README 对本部分 `public` 符号的覆盖（`timestampNanos`/`timestamp`/`timeBased`/`unixTimeBased`/builder 各方法/`SequenceResource`）已逐项核对，除 part1 已报的 `TimestampSequenceBuilder` 返回值与 `encode` 参数顺序外无新增遗漏；#2/#5 的「文档承诺与实现不符」按缺陷记在 §11，不重复计数 |
| §13 文档一致性 | 0（本部分无 `.md`） | 本部分 0 个 `.md`；引用到的 README 行号（`:315`/`:534`/`:538`/`:577`）只作契约证据，文档本身的核对归第 1 部分 |
| 文件覆盖 | 8/8 | 与 `files/f_util.part4.txt` 逐行对应，无缺失（见上表） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 12 |
| 一般 | 28 |
| 轻微 | 22 |
| 其中存量 | 62 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：`CaseFormat.cj` 本身质量良好：单遍扫描、无递归、无共享可变状态，边界（空串、首尾分隔符、六向互转）都能走通，死代码与空实现均为 0；唯一实质问题是六个子类高度同构，属维护性债务而非缺陷。

真正的风险集中在文档层，而且不是措辞问题而是契约问题：README 是 `f_util` 唯一的对外说明，FNV 段落整段对应一个从未落地的 API（照抄必编译失败），CRC 段落的返回类型、`jamcrc` 加速结论、GeoHash 的经纬度参数顺序会直接把使用者带到错误实现上，`TimestampSequenceBuilder` 的链式调用承诺也不成立。另有 2 条规格文档内部漂移（#9 proposal 与 design/spec 冲突、#10 design 与 tasks/perf 冲突），会让后来者按错版本改代码。

阻塞项只有一个：CRC-32 的 `@When` 覆盖缺口使 `f_util` 在 Linux 非 x86/arm 目标上编译失败，且 design 已声称修好——属于「文档记录已修复、代码没改」的典型漏项，建议优先对齐 `crc64_native_stub.cj`。其余 5 条一般问题都是文档修正，可一次提交批量处理；7 条轻微问题（重复文档、过期注释、可见性表达）排期即可。

性能部分本轮不给结论：README 里的 MB/s 与 ns 是历史实测，缺少可复核的原始输出与输入口径，切片拷贝、`ensureReady` 锁、`CaseFormat` 分配量都已降级为待验证假设，需下一轮用 `cjprof` / `cjpm bench -O2` 补数据后再评估。

**第 2 部分**：本部分代码质量分化非常明显，不能一概而论：

- **CRC 子系统（`CrcEngine` / `CrcGf` + 测试）是全仓标杆**：表驱动与 slicing-by-2/4/8 的分派条件清晰、裸指针路径每个出口都配对 `releaseArrayRawData`、测试用独立逐位实现对拍而不是"自己跟自己比"，还带 `F_UTIL_PERF` 门控的吞吐下限。唯一的问题是吞吐用例的全局状态回滚（#18，轻微）。
- **`Fnv` 与 `PathPattern`**：`Fnv` 的实现与黄金值测试扎实（#20 的缺失用例不含它）；`PathPattern` 功能覆盖很广、测试也密，但有三类结构性问题——入口不一致（#6）、注册冲突静默覆盖（#7）、候选顺序不确定（#8），再加上正则锚点（#9）和匹配期写共享容器（#10）。建议把 #6–#9 作为一组一起修（都落在"编译/定序"阶段），#10 单独作为并发改造。
- **四个"对外可用但实际不可用"的 API 是本轮最该先处理的风险**：`cityHash`（#1，短串必崩、长串死循环）、`murmurHash`（#2，≥32 字节丢字节，已被 f_codec 当类型键用）、`IdMaker`（#3，同毫秒重复主键，已被 fdbm 每语句构造）、`DiffieHellmanKeyExchanger`（#4/#5，密钥算不对 + 对端可控死循环）。这四条都是"能编译、能调用、结果错/挂死"的类型，且全部没有用例兜底（#20），优先级应高于任何性能优化。
- **设计模式骨架（`Factory` / `Mediator` / `Strategies` / `ResponsibilityChain` / `State`）**：作为库的扩展点基本可用，但错误口径不统一（#13）、同名注册静默覆盖（#7）、校验接口有空默认实现（#12）、状态机递归无上限（#11）。这些不是当前阻塞项，但会在下游接入时放大成"配错不报错"。

**存量缺陷共 20 条（严重 5 / 一般 8 / 轻微 7），按规则只报不修，是否纳入修复由用户决定**；其中 #1–#5 建议作为第一批。#1–#3 与 #4/#5 的修复都必须同时补上 #20 的黄金值用例，否则同样的缺陷会在下一次重构里复现。性能类结论全部停留在「待验证假设」，本部分没有任何可复核的 benchmark 数据，因此没有一条 CPU/内存收益被写成结论。

**第 3 部分**：本部分的风险分布很不均匀，可以分成三块看：

- **`TextTemplate`（495 行）是本轮 f_util 最需要优先处理的文件**：三条主干能力里，`time:` 输出错值（#1）、`regex:` 根本没实现（#2），`number:` 的非十进制分支符号/宽度/大小写三处都错（#4），空值兜底是死语句（#5），再加上缓存无界（#6）与空分隔符死循环（#7）。`TextTemplateCacheKey_test` 的 5 个用例全部围绕「缓存键是否串味」，一条都没有覆盖占位符语义——这正是上述缺陷能长期存活的原因。建议按「补语义用例 → 修 #1/#2/#4/#5 → 加有界缓存」的顺序做，#6/#7 可以并行。
- **CRC 子系统的算法实现是可靠的，问题在开关与平台胶水**：`crc16/32/64` 的变体参数、硬件分派、尾部补齐都正确，`crc_check_test` 用 RevEng 检查值把 41 个变体钉死了，`crc32_codegen_test` 连「非对齐长度」都按平台契约分开断言，质量高于本模块平均水平。真正的债是把「模式解析 / 开关状态」抄了四份（#13），抄的过程中出现了语义分叉（#10）与口径分叉（#14），并且热路径上的 `mode()` 是无同步惰性初始化（#11）。这些都不会算错 CRC，但会让「关掉硬件 / 确认是否走了硬件」这类运维动作失效。
- **`UInt128` / `Utils` / `TreeTransformer` 三个小工具各有一处「契约写好了、实现没接上」**：`fromBytes` 的校验没有 `throw`（#3，最严重，会让 128 位键静默错值）、`computeBytes` 对三种合法输入抛异常且从不返回 `None`（#8）、`transform` 把数据不完整表现成 `NoneValueException`（#9）。三者都是 `public` 且都被下游当基础件使用，修复成本很低，建议随 #1 一起做。

阻塞项只有 #1–#3：`time:` 全坏、`regex:` 缺失、`UInt128` 静默错值，都属于「按文档用就出错 / 出了错看不出来」。其余一般项（#6–#11）是稳定性与可运维性问题，可排期；#12–#15 是清理与对齐。性能方面本部分没有任何可复核的测量，唯一的具体机制收益是 O1（ISO 路径整段拷贝），已按「待验证假设」处理，未写成结论。

**第 4 部分**：本部分是 `f_util` 里缺陷密度最高的一段，而且集中在三个「数学/位运算」工具上——`geohash.cj`、`uuid.cj`、`prime.cj`。三条严重问题（#1、#2、#3）都不是风格问题，而是「按 API 名去用就得到错误结果或异常」：

- `GeoHash.encode` 的置位与区间收缩方向相反（#1），使整个半球坍缩成两个哈希值，`decode`/`parse` 完全不可逆；配套的 `tryParse`/`encode` 又对串长与坐标范围不做校验（#1b），连「输入是不是 32 位四进制」都区分不出来。这是三行代码的符号错误，但后果是「空间索引静默失效」，应当作为第一优先级修，并同时补四象限与负例。
- `UUID` 的时间戳（#2）在读侧与写侧同时越界：v1/v6 的 `n * 100` 自 1874 年起必然溢出 Int64，v7 的 48 位字段被整体左移 16 位、读回时又只乘了 100 且混入 12 位随机数——这些是「照 8 字节布局抄到 6 字节字段」的复制型错误。`fdbm` 的单测注释已经承认并绕过了 `timestampNanos`（`fdbm/src/idmaker/IdMakers_test.cj:194`），说明问题真实存在于使用路径上。
- `prime.isPrime`（#3）的模幂用 UInt64 直接做 64×64 乘法，`p > 2^32` 时溢出抛 `OverflowException`，「UInt64 素数判定」这个卖点只在 2^32 以下成立；5 个基的确定性上限（3.47e12）也没有写进任何文档。

一般项里，#6/#7/#8 是同一个模式：序列号与 builder 的扩展点没有落实契约（同刻度不递增、可变字段无同步、文件版把 fsync 搬进锁内），仓内主用方 `fdbm` 靠「随机 node + 外部锁」两个巧合规避了重复，这两个巧合都不在文档里。#4/#5/#9 是解析与边界校验的欠账，修法都很小（收尾校验、`& 0xc0` 判变体、大小写合并、长度前置检查）。

轻微项是死代码（一个未使用 import、一处孤立表达式）、两份手写 hex 解析（正是大小写不一致的成因）、带副作用的 prop 与测试覆盖缺口。

`wyhash.cj` 与三个异常类是这部分质量最好的文件：`wyhash` 与 std 实现逐段一致，异常类就是标准样板。性能方面本轮不给结论——`toString`、`wyhash` 边界检查、`UUID` 的 16 字节数组都只有机制、没有数据，全部降级为待验证假设与「无基线」方案，需下一轮 `cjprof` / `cjpm bench -O2` 补测后再谈是否排期。
