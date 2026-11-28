# f_util 模块审查报告（模块第 1/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_util`（本部分 1 个 `.cj` + 19 个 `.md`；整模块 48 个 `.cj` + 19 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 基线；本轮全部问题来源记「存量」）
- **审查重点**：工具类正确性与边界、死代码、重复逻辑、空实现、栈溢出、OOM、并发安全、存量 BUG；另按 `review-checklist.md` §13/§14 核对文档一致性
- **报告版本**：v1（模块第 1/4 部分的分报告，由主 Agent 合并；本文件不产出 `docs/review/` 模块报告）
- **说明**：本部分以文档与 `CaseFormat.cj` 为主，`cr*` / `Fnv` / `UUID` 等实现文件在 part2–part4；涉及实现取证时只读不改，并在「范围外提示」标注归属。

## 发现

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

## 优化可行性方案

本部分只有 `CaseFormat.cj` 一个实现文件，其余为文档；其自身的性能/内存改进（每次 `convert` 新建 `StringGenerator` 与目标实例）没有改前基线，按硬规则不进本节，见「待验证假设」。故本部分优化方案计数为 0 / 0。

## 待验证假设

> 无性能测试数据，均不作为结论，不进 `todo.md` / `tasks.md`。相关实现文件属 part2–part4，此处只记录本轮读文档时形成的线索。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ISO-HDLC 硬件路径每次 `update` 都切 `data[0..aligned]`，4 KiB 帧会多一次整段拷贝，可能抵掉部分硬件收益；README 的 4 KiB 475 ns 未说明是否已包含该拷贝 | `f_util/src/crc32.cj:97-104`（范围外，part3）；文档 `f_util/README.md:92` | 4 KiB 输入下切片拷贝的耗时占比 | `cjprof record` + 分段计时（拷贝前后各打点），同机 `-O2`，4096 B × 10^5 次，取中位数与 P99 |
| 2 | `Crc32Hw.ensureReady` 每次 `update` 都进一次 `Mutex`，多线程小包场景下锁竞争可能成为串行点（perf 文档只给了「几十 ns」的单线程估计） | `f_util/src/crc32_native_x86.cj:158-176`（范围外，part3） | 8/16 线程下的锁等待时间与吞吐曲线 | 多线程 4 KiB bench，对比 `nativeEnabled` 开关两态；辅以线程状态采样（BLOCKED 占比） |
| 3 | `CaseFormat.convert` 每次调用分配一个 `StringGenerator` 与一个目标实例；宏展开期按字段数批量调用，分配量可能可观 | `f_util/src/CaseFormat.cj:48-63` | 单次分配字节数、在宏展开总耗时中的占比 | `cjprof heap` 或 `getAllocatedHeapSize()` 前后差，输入 10^5 次转换；同时测 `-O2` 下总耗时 |
| 4 | `TextTemplate` 的进程级静态缓存键含模板/前缀/后缀且无容量上限，模板串若由运行期数据拼接会无界增长 | `f_util/src/TextTemplate.cj:54,68-70`（范围外，part3）；设计已承认为已知问题 `doc/spec/fix-text-template-cache-key/design.md:25,61` | 真实调用方的模板串基数与增长率 | 在各模块 `compile` 调用点加计数埋点，跑 24h 稳态负载，观察条目数与 RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_util/README.md` | .md | ✅ | 发现 #2/#3/#4/#5/#6/#7/#12/#13；其余与实现逐项核对一致 |
| 2 | `f_util/README_en.md` | .md | ✅ | 与中文版同源同错，已合并成一条；无独有章节缺失 |
| 3 | `f_util/doc/perf/crc32-codegen.md` | .md | ✅ | 与实现一致（`/proc/cpuinfo`、`ensureReady` 锁、4 KiB 数据）；见 #10 |
| 4 | `f_util/doc/spec/accelerate-f-util-crc/design.md` | .md | ✅ | 见 #1（D7 声称已修正 CRC-32 stub）、#9（与 proposal 冲突） |
| 5 | `f_util/doc/spec/accelerate-f-util-crc/proposal.md` | .md | ✅ | 见 #9（4 通道 / 64B / 4 组常量 / 3 参数 ABI 未回写） |
| 6 | `f_util/doc/spec/accelerate-f-util-crc/specs/f-util-crc/spec.md` | .md | ✅ | 与 design 终稿一致；`len & ~15`、3 组常量、256 阈值均已核对 |
| 7 | `f_util/doc/spec/accelerate-f-util-crc/tasks.md` | .md | ✅ | 与 design 一致；0.3/0.5/10.4/12.6 未勾选属遗留，随 #9 同批整理 |
| 8 | `f_util/doc/spec/crc32-hw-cfunc/design.md` | .md | ✅ | 见 #10（交付物文件名、cpuid 描述） |
| 9 | `f_util/doc/spec/crc32-hw-cfunc/proposal.md` | .md | ✅ | 与 design 一致（单块/门槛/回退） |
| 10 | `f_util/doc/spec/crc32-hw-cfunc/tasks.md` | .md | ✅ | 任务与 design 的 Phase 划分一致；未涉及文件名，无额外漂移 |
| 11 | `f_util/doc/spec/crc64-x86-hw-fix/design.md` | .md | ✅ | 逐项核对：`REF_CODE=495` / `NORM_CODE=221`、偏移 `0x1EF`、性能表均与源码一致 |
| 12 | `f_util/doc/spec/crc64-x86-hw-fix/proposal.md` | .md | ✅ | 与 design 一致（4 参数 ABI、495/221） |
| 13 | `f_util/doc/spec/crc64-x86-hw-fix/tasks.md` | .md | ✅ | 与 design 一致 |
| 14 | `f_util/doc/spec/f-jit-m1/specs/f-util-fnv/spec.md` | .md | ✅ | 与实现一致：`Fnv.hash` 五宽度、`FnvHasher`、`Fnv1024` 16 字基值与 `Fnv.cj:264-267` 逐字相同 |
| 15 | `f_util/doc/spec/fix-text-template-cache-key/design.md` | .md | ✅ | 与实现一致（`cacheKey` 长度前缀、`computeIfAbsent`、无上限为已知问题） |
| 16 | `f_util/doc/spec/fix-text-template-cache-key/proposal.md` | .md | ✅ | 与 design/实现一致 |
| 17 | `f_util/doc/spec/fix-text-template-cache-key/spec.md` | .md | ✅ | 三个 Scenario 与 design/proposal 一致；对应用例在 `TextTemplateCacheKey_test.cj`（part3，未展开） |
| 18 | `f_util/doc/spec/fix-text-template-cache-key/tasks.md` | .md | ✅ | 全部勾选，与实现一致 |
| 19 | `f_util/doc/设计模式.md` | .md | ✅ | 见 #8（与 README 逐字重复） |
| 20 | `f_util/src/CaseFormat.cj` | .cj | ✅ | 见 #11/#12/#13；无死代码、无递归、无共享可变状态 |

合计：`.cj` 1 个 / `.md` 19 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 13 条（含 1 条严重），是否纳入修复待用户决定；本部分未改动任何源码。

## 总评

`CaseFormat.cj` 本身质量良好：单遍扫描、无递归、无共享可变状态，边界（空串、首尾分隔符、六向互转）都能走通，死代码与空实现均为 0；唯一实质问题是六个子类高度同构，属维护性债务而非缺陷。

真正的风险集中在文档层，而且不是措辞问题而是契约问题：README 是 `f_util` 唯一的对外说明，FNV 段落整段对应一个从未落地的 API（照抄必编译失败），CRC 段落的返回类型、`jamcrc` 加速结论、GeoHash 的经纬度参数顺序会直接把使用者带到错误实现上，`TimestampSequenceBuilder` 的链式调用承诺也不成立。另有 2 条规格文档内部漂移（#9 proposal 与 design/spec 冲突、#10 design 与 tasks/perf 冲突），会让后来者按错版本改代码。

阻塞项只有一个：CRC-32 的 `@When` 覆盖缺口使 `f_util` 在 Linux 非 x86/arm 目标上编译失败，且 design 已声称修好——属于「文档记录已修复、代码没改」的典型漏项，建议优先对齐 `crc64_native_stub.cj`。其余 5 条一般问题都是文档修正，可一次提交批量处理；7 条轻微问题（重复文档、过期注释、可见性表达）排期即可。

性能部分本轮不给结论：README 里的 MB/s 与 ns 是历史实测，缺少可复核的原始输出与输入口径，切片拷贝、`ensureReady` 锁、`CaseFormat` 分配量都已降级为待验证假设，需下一轮用 `cjprof` / `cjpm bench -O2` 补数据后再评估。
