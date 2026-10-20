# f-jit-m2 校验报告（verify）

- 变更：`f-jit-m2`
- 校验对象：`openspec/changes/f-jit-m2/specs/` 下 6 个 capability（**51 requirement / 156 scenario**）、`tasks.md`（54 个 Q 步骤）、`design.md`
- 语义权威：`f_jit/doc/jit-bytecode-m2.md` **v0.8.32**；设计裁定：`f_jit/doc/design-m2.md`；实施记录：`apply-logs/Q0–Q6.progress`
- 校验时间：2026-10-19
- 校验方式：逐 requirement / scenario 手工对照实现与用例；不修改实现代码、不修改规格、不执行 `openspec archive` / `sync`
- 基线证据：`cjpm build` 成功；`cjpm test` **826/826/0**（M1 纯基线 560 全保留）；`check_tmap.sh` 40 条 M1 映射 0 悬空；`check_scenarios.sh` 156 条 M1 映射（full 139 / partial 5 / 缺口 7 / N/A 5），未映射 0、缺失 0
- 仓状态：分支 `feature/f_jit`，HEAD `5ef620d7`，工作区干净；Cangjie `1.3.0-alpha.20261016001051`（cjnative，`aarch64-unknown-linux-gnu`）

## 结论

**`tasks.md` 的 54/54 勾选不等于规格全绿。** M2 的行为主体已经落地（CALL_HOST/H63、宿主对象通道、成员访问、字节码侧构造、反射注册、逃逸闭包、版本规则集均有实现与用例），M1 零回归成立；但存在 **9 项阻塞 archive 的缺口**，集中在用户面再导出、M2 验收证据链、验签的元数/14 具体类、反射子类访问、报告文本与文档回写。

### 结案进度（2026-10-20）

**9/9 全部解决**，可进入 archive：

| 批次 | 缺口 | 方式 |
|---|---|---|
| 语义改造 | GAP-03 / 04 / 05 | 用户裁定方向 → 改实现（`FunctionTypeInfo` 验签 + `apply` 调用、类名穿透、子类判定） |
| 性能 | GAP-08 | 实测 4.6–5.8× → 用户裁定**接受现状** → 规格按实测修订 |
| 机械补齐 | GAP-01 / 02 / 06 / 07 / 09 | 根包再导出、验收矩阵与脚本、尖括号、差分补齐、偏差回写 |

**新增 GAP-13（INFO，不阻塞）**：`registerType<T>()` 的方法绑定在 **String 参数/返回**上必现
SIGSEGV（`std.reflect` 的 `ApplyCJMethod`/MCC 路径；探针 300 次循环三轮全崩）。
已规避（改用值型方法 + 手工绑定覆盖 String 面）并如实登记；根治 = M2.1 类型化包装闭包。

**当前基线**：`cjpm test --parallel 1` = **849/849/0，零崩溃**；`check_tmap` 54 条 0 悬空；
`check_scenarios m2` 156 条（full 138 / partial 11 / 缺口 5 / N/A 2）、未映射 0、缺失 0。

**总结论：需先补 9 项，暂不可进入 archive。**

| ID | 级别 | 阻塞 archive | 摘要 |
|---|---|---|---|
| GAP-01 | CRITICAL | **已解决** | ~~根包未再导出 M2 六类型~~ → 已导出 7 项（+`LocalType`），独立包探针 `FacadeSurface_test` 只导根包即可完成注册 |
| GAP-02 | CRITICAL | **已解决** | ~~M2 无验收矩阵~~ → `TCoverage` 14 条（`check_tmap` 54 条 0 悬空）、`scenario-map.tsv` 156 条（0 未映射）、脚本参数化 |
| GAP-03 | WARNING | **已解决** | ~~反射自动访问器只按精确类匹配~~ → 类型判定改沿 `superClass` 链（接受子类实例）；反射执行层 `getValue` 拒绝子类实例经实测固化为已知限制（见段内处置） |
| GAP-04 | WARNING | **已解决** | ~~签名中的 14 不携带具体类~~ → `HostClosureT`/`SignatureDescriptor` 携带类名，验签按类型名逐字比对 |
| GAP-05 | WARNING | **已解决** | ~~验签/H63 分派仅支持 0–2 元~~ → 改用 `FunctionTypeInfo` 验签 + `apply` 调用，元数不限、1887 行分派表已删 |
| GAP-06 | WARNING | **已解决** | ~~无尖括号~~ → `slotText` 对 `>=HOST_CLOSURE` 加尖括号（4–12 保持原样），三例通过 |
| GAP-07 | WARNING | **已解决** | ~~14/糖/身份未入差分~~ → `Q6DiffCoverage_test` 三条（14 实参、成员访问糖、句柄型实参）全部两引擎一致 |
| GAP-08 | WARNING | **已解决** | ~~性能对照未实测~~ → 实测 4.6–5.8×，留档 `doc/perf-m2.md`，用户裁定接受现状并按实测修订规格 §8 |
| GAP-09 | WARNING | **已解决** | ~~无偏差回写~~ → `design-m2` §11（10 条）、`plan-m2` §4、规格 v0.8.33、`tasks.md` 镜像 54/54、三表抽样 7 项 |
| GAP-10 | INFO | 否 | 4 条 scenario 无任何用例断言（见「无用例断言」） |
| GAP-11 | INFO | 否 | 13 条 scenario 仅部分覆盖（见各 capability 明细） |
| GAP-12 | INFO | 否 | x86_64 非本机原生，M2 的 x86 执行证据待 CI（规格允许跳过，记工程债） |
| GAP-13 | INFO | 否 | `registerType<T>()` 生成的方法绑定在 **String 参数/返回**上稳定 SIGSEGV（std.reflect 的 `ApplyCJMethod`/MCC 路径）；已规避并登记 |

## 概览

| capability | requirement | scenario | 已实现且有断言 | 部分覆盖 | 已实现但无断言 | 未实现 | 实现与规格不一致 | 结论 |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `f-jit-base-contracts` | 8 | 16 | 16 | 0 | 0 | 0 | 0 | **绿** |
| `f-jit-bytecode-format` | 6 | 21 | 18 | 1 | 2 | 0 | 0 | **绿（有覆盖缺口）** |
| `f-jit-compiler-frontend` | 9 | 36 | 34 | 1 | 0 | 0 | 1 | **黄** |
| `f-jit-runtime` | 11 | 31 | 28 | 2 | 0 | 0 | 1 | **黄** |
| `f-jit-facade-bridge` | 10 | 32 | 26 | 2 | 2 | 1 | 1 | **红** |
| `f-jit-differential-acceptance` | 7 | 20 | 8 | 7 | 0 | 5 | 0 | **红** |
| **合计** | **51** | **156** | **130** | **13** | **4** | **6** | **3** | — |

> 计数口径：一条 scenario 只归一类。「实现与规格不一致」优先于「部分覆盖」；「未实现」指规格要求的产物/机制不存在；「已实现但无断言」指代码路径成立但无直接用例。

## 逐 capability 结论

### 1. `f-jit-base-contracts`（8 / 16）— 绿

- **LocalType / TypeToken / ErrCode / Version**：码值、`name`、`isHandle`、版本分派合法集、21 与 99 的分野、legacy 1/14 与 M2 2/0 均有直接断言。
  - `LocalType_test.legalSetIsDispatchedByVerMajor` 覆盖 v1 拒 13+/v2 放 13–14 拒 15+/v3 放 15–19 拒 20；`ErrCode_test.hostExceptionAndPanicAreDistinguished` / `isHostSideIsFalseForAllM1Codes`；`Version_test.legacyM1ConstantsUnchanged` / `m2HeaderBuildsWithM2Constants`。
- **注册协议值类型**：`ClassRegistration_test` 的 `fieldsRoundTrip`、`hostObjectFieldCarriesTypeRef`、`typeLegalSetIsZeroToFourteen`、`methodBindKeepsReceiverFirst`、`ctorParamsAndAdapterAreCallable`、`multipleCtorOverloadsArePreserved` 覆盖五字段、14 型 `typeRef`、方法 bind 首参与构造器重载。
- **注册期拒绝**：`RegistrationException_test` 六值、`occupiedBy=None`、三段消息 + 固定 hint、可被 `BaseException` 捕获、**不是 `JitException`、不占 ErrCode**；注册表原状由 `ClassRegistry_test` / `CompilerRegistration_test` 的拒绝用例覆盖。
- 无部分/缺口/不一致。

### 2. `f-jit-bytecode-format`（6 / 21）— 绿（有覆盖缺口）

- **opcode 表**：`OpInfo_test.callHostRowAndM1RowsUnchanged` / `tableIs256AndSelfIndexed` / `representativeEntriesMatchSpec`；`Assembler_test.forbiddenOpcodeIsNotImpl` / `reservedOpcodeIsNotImpl` 覆盖 `0x7A/0x7B` 的 `ERR_NOT_IMPL`。
- **函数目录 / 局部类型表**：26 字节往返、目录越界、入口未命中、13/14 句柄槽、按 verMajor 的 0–12/0–14/0–19 边界均有用例。
- **常量表**：kind 1–10、正则去重归一、冻结后只读、DAG 共享、成环/坏载荷拒绝均有直接断言。
- **版本矩阵**：`FbcReader_test.v1ProductDispatchesToV1RuleSet` / `v2ProductDispatchesToV2RuleSet` / `m1RuleSetRejectsV2Product` / `registryRegistersV1V2AndV3` / v3 以 18 拒绝 / `noRegistryDispatchRejectsHostObjectAndUserHelpers` 全绿；`FbcRuleSet` 把合法集、指令集、14 注册依赖、verMinor 区间集中为单一来源。
- **CALL_HOST 语义**：`InterpHostCall_test.interpreterMatchesDirectTrampoline` 与 `v2CallHostExecutes` 覆盖解释器 ≡ H63。

非绿：

| scenario | 类 | 证据 / 缺口 |
|---|---|---|
| 常量段零增量 | 部分覆盖 | `ConstPayload_test.constSectionRoundTrips` 只做编解码往返，未断言「M1 源经 M2 加载器常量段逐位一致」 |
| 宿主值不可常量化 | 无断言 | `ConstRegistry` 没有 kind 10/11 的注册入口，结构性不可达；无用例显式断言拒绝 |
| 机器码零新模式 | 无断言 | `A64Lower.cj:374` / `X86Lower.cj:941` 均把 `0x79` 路由到 `helperCall(63, argc+1)`，但无字节级用例断言只出现模板 A + `CHECK_ERR` |

### 3. `f-jit-compiler-frontend`（9 / 36）— 黄

- **TypeRef / ClassRegistryView / NameResolver**：三类记法、禁高阶与 9/12/13、未注册类名、命中/未命中、快照隔离、继承成员仅按表、名字解析顺序与同名冲突均有直接用例。
- **明确赋值**：`Semantics_test` 覆盖读未赋值、循环回边、分支汇合、捕获未赋值；`AstM2_test` 覆盖 13/14 槽读未赋值与 `PUSH_NULL` 直存 14 拒绝。
- **降低 / 汇编**：CALL_HOST 序列、成员读写/调用、构造重载与嵌套、JSON 谱系拒绝、捕获白名单第 0 步与第 1 步、`LOAD_CAP` 零变化、`callHostV2AcceptedWithLayout` / `callHostV1IsNotImpl` / `callHost*Rejected` / `missingCheckErrIsRejected` / `callHostFunctionRejectsDeoptSource` / `hostSetFieldRejectsDeoptSource` 均全绿。

非绿：

| scenario | 类 | 证据 / 缺口 |
|---|---|---|
| CALL_HOST 降低 | 实现与规格不一致（**偏差 A，可接受**） | `Lowerer.cj:1710-1717` 与 `LowererM2_test.callHostInstructionSequence` 均为 `LOADL fn → 实参左→右`；spec 文案「实参→`LOADL fn`」与 `[h_fn, a1..an]` 自相矛盾，按 doc §2/§5 判定为规格文字问题 |
| 糖 ≡ 手写 | 部分覆盖 | `Q6Acceptance_test.t35SugarEqualsManualWrapper` 只做单引擎结果比对，未接入三引擎四元组对拍 |

### 4. `f-jit-runtime`（11 / 31）— 黄

- **句柄表 / 窗口 / 提升组**：tag 10/11 往返、同对象同 ID、`moveOutGroup` 原地提升（ID/gen 不变、窗口重置后可用、不重用）、槽级免级联、`PromotionGroup` 幂等计数/归零释放/gen+1/常量不入组/try-finally 豁免均有用例。
- **H63/H64/H65**：tag 不符 8、`mutable=false` 19、值型零登记、句柄型 1 槽、H65 零登记、宿主异常 21 + cause + site、重入 depth 3 隔离、引擎侧 99、fail-fast、并发隔离均有直接断言；`InterpHostCall_test` 证明解释器与 H63 逐位一致。
- **签名**：`SignatureDescriptor_test` 的合法集与 `SignatureVerifier_test` 的 0–2 元用例覆盖非函数值、元数、逆变、协变、禁高阶与缓存。
- **报告**：`DbgDump_test` 的三行模板、`site=-1`/`dbgBase=0`、`-1`/`-2` 不转储、最深帧获胜逐条保持。

非绿：

| scenario | 类 | 证据 / 缺口 |
|---|---|---|
| 释放后不可达 | 部分覆盖 | `HandleTable_test.releasedIdIsUnreachableAndGenBlocksReuse` 是通用槽；tag 10/11 的释放后读取没有专项目例 |
| 单次判定覆盖全部不符 | 部分覆盖 | 0–2 元全绿；>2 元由 `SignatureVerifier.arityMatches` 直接 false（见已知限制 ①） |
| 13/14 大类名呈现 | 实现与规格不一致（**偏差 D**） | `DbgDump.cj:222-223` 输出 `HostClosure#7` / `HostObject#9`（`LocalType.cj:88-89` 无尖括号）；spec 与 doc §9.16 要求 `<HostClosure>#idx` / `<HostObject>#idx` |

### 5. `f-jit-facade-bridge`（10 / 32）— 红

- **注册表 / 反射 / 构造 / Marshal / 包装**：`ClassRegistry` 注册查询与拒绝、`ReflectRegistrar` 全成员枚举/跳过诊断/JSON 拒绝/关闭反射拒绝、`autoMatchesManualDescriptor`、`t54` 每次新实例/全通道/重载、`t57` 实参身份/子类 opaque、`t58` 链内深度 3、`CallMarshal` 12/13/14 解包、`JitFunction` 包装调用/close/卸载 19 均有直接用例。
- **管线与入口**：`RunUnit_test` 覆盖装载/同字节复用/坏魔数；`FuncDir_test.entryFnMissIsRejected` 覆盖入口校验。

非绿：

| scenario | 类 | 证据 / 缺口 |
|---|---|---|
| 全类型行可断言 | 部分覆盖 | M1 行在 `CallMarshal_test.scalarMarshalling`，M2 行在 `CallMarshalM2_test.mixedArguments`；没有一条覆盖全部 0–14 行的统一矩阵 |
| 注册表依赖面拒绝 | 部分覆盖 | `FbcReader_test.noRegistryDispatchRejectsHostObjectAndUserHelpers` 只断言加载期拒绝；「同一单元经源入口可正常执行」用另一单元间接证明 |
| 含宿主句柄的容器被拒 | 无断言 | 加载器没有 kind 10/11 入口，间接由「未知常量 kind」拒绝；无显式容器用例（M1 verify 已登记的同名缺口延续） |
| 反射仅在注册期 | 无断言 | 代码结构上 `std.reflect` 只在 `ReflectRegistrar` 出现，但无执行路径断言 |
| **一次导入可用** | **未实现** | `Root.cj:23-33` 只再导出 M1 类型 + `PredefinedFunction`；`ClassDescriptor` / `PublicField` / `PublicMethod` / `PublicCtor` / `RegistrationException` / `RegistrationRejectKind` 仍在 `fountain::f_jit.base`，`import fountain::f_jit.*` 不可见；`UserApi_test.minimalHostExample` 仍是 M1 冒烟 |
| HostClosure 签名含 14 | 实现与规格不一致（**已知限制 ②**） | `Slot14_test.hostClosureParam14` 必须写 `(Object) -> String` 并在体内 `is ManualUser`；spec 的 WHEN 是 `(User) -> Order`，实际 `(User)->…` 会因 `invoke1<Object,…>` 失败 |

### 6. `f-jit-differential-acceptance`（7 / 20）— 红

- **已成立**：T33 的 `Interp × Native` 对拍覆盖 CALL_HOST 值型/引用型/异常/重入；T49 的 M1 产物差分零变化；T60 的 21/99/完整栈/并发隔离；`DiffHarness` 自证；M1 的 156 条映射脚本可运行（0 未映射/0 缺失；7 缺口/5 部分已在 M1 verify 登记）。
- **未成立**：M2 的验收映射、三引擎矩阵、性能留档、文档回写。

非绿：

| scenario | 类 | 证据 / 缺口 |
|---|---|---|
| 映射可脚本校验 | 未实现 | `TCoverage.cj:95-110` 仅把 T30–T36/T49 标为 out-of-scope，`caseName` 是描述串而非用例名；`check_tmap.sh` 只解析 `'M1', true` 条目 |
| M2 编号全覆盖 | 未实现 | 表中没有 T54/T55/T57–T60；M2 行为用例（`Q6Acceptance_test` / `Q6Compiler_test`）未被映射 |
| 范围外编号有说明 | 部分覆盖 | T30–T36 的说明与 M2 规格名称不一致（如 T32 写「宿主对象访问」，规格是「机制交互」）；T49 仍写「预留验收项」 |
| 双字段断言 | 部分覆盖 | Q6 失败点用例普遍同时断言 code/site；单元级 H63/H64/H65 用例多数只断言 code（如 `HostFieldGet_test.accessorExceptionMapsTo21`） |
| 容量边界可复现 | 部分覆盖 | M2 窗口账目用固定 `openWindow(128)`；没有「调小容量 → 扩容/16 触顶」的 M2 分配用例 |
| 三引擎逐位一致 | 部分覆盖 | `Q6Compiler_test.t33HostCallValue/Reference` 只覆盖值型与 String；无 14、无 List/Map、无 Decimal/DateTime/Duration/Range |
| 糖与手写对拍 | 部分覆盖 | `t35SugarEqualsManualWrapper` 是单引擎，未进 `DiffSession` |
| 对象身份 | 部分覆盖 | `t34HostObjectRoundtripKeepsIdentity` / `t57ArgumentFlowsAllChannels` 是单引擎 |
| M1 产物不变 | 部分覆盖 | `t49M1DiffRegressionIsZeroChange` 只以 M1 编译选项编译；未做「同一 M1 源分别经 M1/M2 编译」的产物/行为对比 |
| 性能对照同构 | 未实现 | `PerfCompare_test` 只有 M1 的 JIT/Interp/cjnative；无 HostClosure vs user helper 的比值，无 `perf-m2.md` |
| 偏差回写 | 未实现 | `design-m2.md` / `plan-m2.md` / `jit-bytecode-m2.md` 最后修订均为 2026-10-13，无实施偏差段 |
| 同源抽查 | 未实现 | 无三表抽样记录 |

## 缺口清单（按严重度）

### CRITICAL

**GAP-01 根包 M2 再导出缺失**

- 规格：`f-jit-facade-bridge / 用户面再导出与冒烟` —「M2 SHALL 再导出 `ClassDescriptor` / `PublicField` / `PublicMethod` / `PublicCtor` / `RegistrationException` / `RegistrationRejectKind` / `JitClosureId`……」
- 证据：`Root.cj:23-33` 只有 M1 九个类型 + `PredefinedFunction`；六个类型定义在 `base`（`base/ClassRegistration.cj:39/75/95/122`、`base/RegistrationException.cj:26/81`），根包无 `public import`。
- 影响：用户按规格写 `import fountain::f_jit.*` 后无法命名 `ClassDescriptor`，`registerClass` 不可调用；scenario `一次导入可用`（WHEN 注册类 → 编译 → 传宿主闭包/对象 → close）无法通过。现有 `UserApi_test` 只是 M1 冒烟，未暴露该问题。
- 修复：在 `Root.cj` 增加六条 `public import fountain::f_jit.base.<T>`；补一条只 `import fountain::f_jit.*` 的 M2 端到端用例。

**GAP-02 M2 验收映射与场景矩阵缺失**

- 规格：`f-jit-differential-acceptance / 验收项映射与覆盖` —「M2 SHALL 覆盖 T30–T36、T49、T54、T55、T57–T60」；三个 scenario 分别要求「每项可定位到步骤号+用例名、无悬空」「每个编号至少一个落点且名称一致」「范围外编号有说明」。
- 证据：`TCoverage.cj:95-110` 的 M2 条目 `steps=[]`、`caseName` 是中文描述；无 T54/T55/T57–T60；`check_tmap.sh` 正则只匹配 `'M1', true`，`check_scenarios.sh:19` 硬编码 `doc/spec/f-jit-m1/specs`；`doc/spec/f-jit-m2/` 下无 `scenario-map.tsv`。
- 影响：M2 的 51/156 条规格没有可脚本校验的验收矩阵；`映射可脚本校验` / `M2 编号全覆盖` 直接失败。行为用例虽然存在（`Q6Acceptance_test` 33 例、`Q6Compiler_test` 5 例），但未登记即不可审计。
- 修复：把 M2 的 14 个 T 编号登记进 `TCoverage`（`owner='M2'`、真实 `caseName`、`steps` 指向 Q 步骤），扩展 `check_tmap.sh` 接受 M2；新增 `doc/spec/f-jit-m2/scenario-map.tsv` 与 M2 版 `check_scenarios.sh`（或参数化 spec 目录）。

### WARNING（阻塞）

**GAP-03 反射自动访问器只按精确类**

- 判定：**真实缺口（阻塞）**。
- 依据：`f-jit-facade-bridge / 反射自动注册的覆盖面 / 全覆盖与逐项等价`（自动注册结果 SHALL 与手工注册逐项等价）；`宿主对象实参通道 / 源入口实参身份`（子类实例可作为父类声明实参）；`design-m2` M2-7（宿主侧访问器/反射**可**按继承逐级向上）。
- 证据：`ReflectRegistrar.cj:443-450` 的 `isInstanceOf` 只比较 `ClassTypeInfo.of(o).name`，注释明确「`getValue/setValue` 会拒绝子类实例」；手工访问器 `o is C` 支持继承。`t57SubclassPassesByBaseClass` 用**手工**访问器验证，未覆盖自动路径。
- 影响：`registerType<Base>()` + `Sub` 实例 + `e.field` 会以访问器异常（21）失败；自动 ≠ 手工。
- 修复：为祖先链逐级生成访问器（用 `ClassTypeInfo.superClass` 选声明类），或明确在规格/设计中把「自动注册仅精确类、子类须手工注册」写成限制。

- **处置（2026-10-20，已解决）**：按用户裁定「声明 `A` 做形参时可传 `B` 实例；源码出现**未注册**的类名由前端编译期报错」——`ReflectRegistrar.isInstanceOf` 改为沿 `superClass` 链判定「`o` 是声明类的实例（含子类）」。**实测补充一条前提之外的事实**：`ClassTypeInfo.instanceVariables` 与 `getInstanceVariable(name)` 均不含继承成员，且 `InstanceVariableInfo.getValue(子类实例)` 抛 `IllegalTypeException`（`checkDeclaringClassType` 强制精确声明类）——故「用父类注册、子类实例经反射读父类字段」在执行层不可实现。两条事实固化为例句：`T36/subclass-accepts`（判定接受子类）、`T36/reflect-getvalue-exact-class-only`（执行层限制）。有继承的类需或手工访问器（`o is C`，天然支持）或宏生成。

**GAP-04 签名 14 未覆盖具体类**

- 判定：**真实缺口（阻塞）**。
- 依据：`f-jit-runtime / 签名验签与条目缓存 / 单次判定覆盖全部不符`（逐参类型不符须返回 None）；`f-jit-facade-bridge / 宿主对象实参通道 / HostClosure 签名含 14`（WHEN `(User) -> Order`）；doc **§16.4**「验签覆盖 14 槽之具体类」。
- 证据：`Signature.cj:121-123` 对 `code == HOST_OBJECT` 直接返回 true；`returnMatches` 对 14 用 `()->Object` / `(…)->Object`；`SignatureDescriptor` 只有 `params: Array<UInt16>`，无类名；`CallMarshal.marshalArg` 只收 `sig`。
- 影响：声明 `(User)->Order` 却传入 `(Other)->…` 仍可验签通过；`retType=14` 可把任意 `Object` 当 `User` 返回，后续成员访问按错误类解析。`Slot14_test.hostClosureParam14` 用 `(Object)->…` 规避，反证该面未实现。
- 修复：让 `SignatureDescriptor` 携带 `typeRef`/类名（或验签 API 增加 `className`），按 `is C` 判定；或修订规格明确 14 只做大类、不做具体类校验。

- **处置（2026-10-20，已解决）**：取原「修复」的第一条路径——`Ast.TypeRef.HostClosureT` 由 `(Array<UInt16>, UInt16)` 扩为 `(Array<UInt16>, Array<String>, UInt16, String)`（类名在解析期曾被压平，是根因），`SignatureDescriptor` 随之携带 `paramNames` / `retName`；`SignatureVerifier.verifyReflective` 按 `FunctionTypeInfo` 的 `parameters[i].name` / `returnType.name` 逐位比对，14 位置要求类名逐字相等。用例 `ReflectiveVerify_test.checksConcreteClassName` 断言 `(ReflectUser)->Int64` 的声明拒绝 `(ReflectAdmin)->Int64`。原「已知限制 ②」撤销。

**GAP-05 验签 / H63 分派只覆盖 0–2 元**

- 判定：**真实缺口（阻塞）**。
- 依据：`f-jit-runtime / 签名验签与条目缓存 / 单次判定覆盖全部不符`（参数个数维度）；`f-jit-facade-bridge / 参数封送与返回解包表 / HostClosure 实参`；doc **§4**「一次类型判定 `value is (T1..Tn) -> R`……**不另设分步核对**」。
- 证据：`Signature.cj:81-82`「支持面：元数 0–2」、`arityMatches` 仅 0/1/2；`HostCallDispatch.cj:44-52` 仅 `dispatchHostCall0/1/2`。`Q6Acceptance_test.t30ArityAboveTwoIsKnownLimit` 显式断言该限制。
- 影响：3 个及以上形参的 HostClosure 无法使用：入口验签 19，直接 H63 分派 99。实现采用 doc 明文否定的「元数 + 逐位 + 返回」分步核对（虽然 ≤2 元行为等价）。
- 修复：扩展 `dispatchHostCallN`（代价 12^(n+1) 分支）与 `arityMatches`，或修订规格把 M2 签名元数上限写成 0–2 并说明理由。

- **处置（2026-10-20，已解决；用户裁定方案乙的终态）**：两条原修复路径都被否——分支表是 11^(n+1)，3 元实测编译 +5 分钟且 4 元不可行；而规格 §4 的「单次 `is`」语言上根本不成立（`T`/`R` 是运行期数据，`is` 右侧须静态类型），故「分步核对」不是实现偷懒而是唯一可写的形式。改用 `std.reflect.FunctionTypeInfo`：验签取真实签名逐位比对（`verifyReflective`）、调用走 `apply(fn, args)`（`runtime/ReflectiveCall.cj`）。**元数不限**（3 元用例 `t30ArityAboveTwoWorks` 断言端到端 `6`），`HostCallDispatch.cj` 的 1887 行分派表**整文件删除**。规格 §4/§5/§8/§9.1/T30 已同步（m2 v0.8.33）。

**GAP-06 DbgDump 13/14 文本与规格不符**

- 判定：**真实缺口（阻塞，1 行可修）**。
- 依据：`f-jit-runtime / 单次诊断转储与报告组装` —「13 记为 `<HostClosure>#idx`、14 记为 `<HostObject>#idx`」；scenario `13/14 大类名呈现`；doc 行 162–163 同文。
- 证据：`DbgDump.cj:222-223` 的槽文本统一为 `'${tname}#${idx}'`，而 `LocalType.name(13/14)` 返回 `HostClosure` / `HostObject`（`base/LocalType.cj:88-89`），故实际输出 `HostClosure#idx` / `HostObject#idx`；`DbgDump.cj:41` 注释与 `DbgDumpM2_test`（44/46/49/82 行）也按无尖括号断言。
- 影响：scenario 的 THEN 逐字不符；报告文本对用户/工具不稳定。
- 修复：在 `DbgDump.slotText` 对 13/14 特判为 `'<${tname}>#${idx}'`（不要改 `LocalType.name`，以免影响 0–12 与诊断），同步 `DbgDumpM2_test` 四处期望。

**GAP-07 M2 三引擎差分矩阵不完整**

- 判定：**真实缺口（阻塞）**。
- 依据：`f-jit-differential-acceptance / M2 差分矩阵与确定性宿主闭包`（SHALL 把 M2 新增面纳入同一用例单次对拍；`糖与手写对拍`、`对象身份` 均要求「三引擎四元组逐位一致」）。
- 证据：`Q6Compiler_test` 的 `DiffSession([InterpRunner(), NativeRunner()])` 只覆盖 HostCall 值型/String/异常/重入；`t35SugarEqualsManualWrapper`、`t34HostObjectRoundtripKeepsIdentity`、`t57ArgumentFlowsAllChannels` 均用 `Compiler.call` 单引擎；无 14 参数的差分；无 List/Map/Decimal/DateTime/Duration/Range 的 HostCall 差分。
- 影响：`糖与手写对拍`、`对象身份` 只到「单引擎正确」，未证明跨引擎逐位一致；`三引擎逐位一致` 只覆盖值型/引用型子集。
- 修复：把糖/对象身份/14/句柄型参数纳入 `DiffSession`；x86 按既有条件跳过策略标记。

**GAP-08 M2 性能对照缺失**

- 判定：**真实缺口（阻塞）**。
- 依据：`f-jit-differential-acceptance / 容量与性能基线实测留档` —「M2 SHALL 增加……宿主闭包调用相对 user helper 的开销比值（规格估算 1.5–3×，以实测为准）」；scenario `性能对照同构`。
- 证据：`PerfCompare_test` 只有 M1 的 JIT/Interp/cjnative；无 HostClosure/CALL_HOST 对照；`doc/` 下无 `perf-m2.md`。
- 修复：新增同构的 user helper vs HostClosure+CALL_HOST 稳态吞吐用例，记录实测数字与比值，落 `doc/perf-m2.md`。

- **处置（2026-10-20，已解决；用户裁定接受现状）**：新增 `PerfM2_test`（同构一元 `(Int64)->Int64`，预热 64 次 × 2000 次）：user helper ≈ **153 ns/次**、宿主闭包 ≈ **707 ns/次** = **4.63×**；第二轮（缓存 `FunctionTypeInfo` 后）5.75×，波动 ±20%。**超出原估 1.5–3×**，成本主体在 `apply` 的参数打包与间接分派，缓存类型查找无收益。落档 `doc/perf-m2.md`，以 10× 为回归门禁（`T32/host-call-overhead-ratio`）。**用户裁定接受现状**：宿主闭包调用是跨 JIT 边界的控制反转、不在内循环热点，用分派表与元数上限换 3× 不划算；规格 §8 的估算已按实测修订（m2 v0.8.33）。

**GAP-09 文档回写与镜像同步缺失**

- 判定：**真实缺口（阻塞）**。
- 依据：`f-jit-differential-acceptance / 文档与实现同步` —「M2 SHALL 回写 `design-m2.md` / `plan-m2.md` / `jit-bytecode-m2.md` 的实现偏差，并同步 `f_jit/doc/spec/f-jit-m2/` 镜像」；scenario `偏差回写` / `同源抽查`。
- 证据：三份权威文档最后修订 2026-10-13（实施前），无偏差段；`doc/spec/f-jit-m2/tasks.md` 仍是全 `[ ]`，与 `openspec/changes/f-jit-m2/tasks.md` 的 54 个 `[x]` 不一致；`design.md` / `proposal.md` / `specs/` 镜像一致。
- 修复：把 A–D 与已知限制 ①–⑥ 回写三份文档（至少 design-m2 的「实施偏差」节与 plan-m2 的 Q6 备注），同步 `tasks.md` 镜像；补一次三表抽样记录。

- **处置（2026-10-20，已解决）**：
  - `design-m2.md` 新增 **§11 实施偏差回写**（10 条，逐条给原因与影响面）；
  - `plan-m2.md` 新增 **§4 实施回写**（54/54、849 用例、9 项缺口处置表、测试口径、Q6 反推的 5 处缺陷）；
  - `jit-bytecode-m2.md` 升 **v0.8.33**（§4 验签、§5 H63、§8 性能、§9.1 前提、§12.5 反射范围限定、T30）；
  - `doc/spec/f-jit-m2/tasks.md` 镜像同步为 **54/54**（此前全 `[ ]`）；
  - **三表抽样（7 项，逐项核对实现）**：

    | 表 | 项 | 文档 | 实现 | 结论 |
    |---|---|---|---|---|
    | 附 A | `u.f` → `CALL_HELPER H64`（2 参） | §12.4 降级表 | `Lowerer.cj:1359` `callHelper(HOST_GET_FIELD, 2)` | ✓ |
    | 附 A | `u.f = v` → `CALL_HELPER H65`（3 参） | §12.4 | `Lowerer.cj:1382` `callHelper(HOST_SET_FIELD, 3)` | ✓ |
    | 附 A | `C(args…)` → `CALL_HELPER <ctor-hid>` | §15 | `Lowerer.cj:1607-1632`（`requireCtors` → `callHelper`） | ✓ |
    | 附 B | `0x79` = `OP_CALL_HOST` / `u8` / len 2 / `CAT_CALL` | §10.1 | `OpInfo.cj:255` | ✓ |
    | 附 B | H63/H64/H65 = 63/64/65 | §6 helper 表 | `HelperId.cj:93-96` | ✓ |
    | 附 B | `LocalType` 13/14；token 10/11 → 13/14 | §2 | `LocalType.cj:57/60/130/131` | ✓ |
    | 附 C | `CALL_HOST` → `helper(63, argc+1)` | §12.4 模板 | `A64Lower.cj:374`、`X86Lower.cj:941` | ✓ |

### INFO（不阻塞）

- **GAP-10 无用例断言的 4 条**：`字节码格式 / 宿主值不可常量化`、`字节码格式 / 机器码零新模式`、`门面 / 含宿主句柄的容器被拒`、`门面 / 反射仅在注册期`。前两条是结构性/字节级断言缺失，第三条是 M1 遗留，第四条是执行路径约束。
- **GAP-11 部分覆盖的 13 条**：见各 capability 明细。集中在「三引擎」与「全类型矩阵」两类。
- **GAP-12 x86 执行证据**：`X86Lower.cj:941` 已把 `0x79` 路由到 `helperCall(63, argc+1)`，但 `X86Exec_test` 无 CALL_HOST/成员/构造用例；本机只有 `Interp × AArch64`。规格允许非原生跳过，故不算违规，记 CI 工程债。

**GAP-13 反射方法绑定在 String 参数/返回上 SIGSEGV（工具链层面）**

- 判定：**真实缺陷，但不在本实现**——`std.reflect` 的 MCC 调用路径；已规避并如实登记（不阻塞 archive）。
- 现象：`registerType<ReflectUser>()` 后调用 `u.greet("z")`（`greet(s: String): String`）→ SIGSEGV：
  ```
  #0 StringBuilder.append
  #1 ReflectUser.greet (ReflectFixtures.cj:72)
  #2 ApplyCangjieMethodStub
  #3 MapleRuntime::MethodInfo::ApplyCJMethodImpl
  #4 MapleRuntime::MethodInfo::ApplyCJMethod(MObject*, void*, void*, TypeInfo*)
  #6 InstanceFunctionInfo.apply (std/reflect/function_info_cjnative.cj:317)
  ```
- **稳定性**：不是并发才触发。探针「300 次循环：`bump(Int64)` + `greet(String)` + 字符串分配」
  **三轮全崩**（此前全量里看似偶发，是因为单次调用恰好没有 GC 介入）。手工绑定的同一方法
  （`ManualUser.greet`，`PredefinedFunction` 自定义 impl）不触发 ⇒ 失效点在 `apply` 的
  `ArgValue`/MCC 转换，不在方法本身。
- 归因：`InstanceFunctionInfo.apply` 用 `CJ_MCC_ApplyCJInstanceMethod` 构造 `ArgValue` 数组；
  值型参数（Int64）不经 GC，故只有**引用型参数/返回**（此处 String）暴露。应用层无法修。
- 规避（M2 内）：`CompilerRegistration_test.reflectionRegistrationIsEndToEnd` 改用值型方法
  （`u.bump(2)`）证明「反射注册的方法绑定可用」；String 方法的绑定能力由手工路径
  （`manualRegistrationIsEndToEnd`）覆盖。测试口径另加 `--parallel 1`（降低并发 GC 干扰）。
- 根治：M2.1 的类型化包装闭包（`{ a => (a[0] as User).greet(a[1] as String) }`）——
  实测比反射 `apply` **快 36×**（9.8 μs → 270 ns），且完全绕开 MCC 路径（见 `doc/perf-m2.md`）。

## 偏差与已知限制逐条判定

### 偏差 A：CALL_HOST 栈布局 — **可接受偏离**

- **事实**：实现为 `LOADL fn`（先压、栈底）→ 实参左→右 → `CALL_HOST argc`，栈 `[h_fn, a1..an]`；`Lowerer.cj:1710-1717`、`LowererM2_test.callHostInstructionSequence`。
- **判定依据**：`f-jit-bytecode-format / CALL_HOST 指令语义` 明写 `[h_fn, a1..an]`（句柄在栈底）；doc 行 71 同文、行 130「fetch **栈底**句柄」；CALL_HELPER ABI 的 `args[0]` = 最先压入。冲突文字在 `f-jit-compiler-frontend / 降低产物符合规范模式`（「实参左→右 → `LOADL fn`（句柄压栈底）」）与 doc 行 93——「先实参后 LOADL」与「压栈底」本身矛盾。
- **裁定**：**可接受偏离**。实现符合权威布局与 ABI；建议 archive 前把 frontend delta 的语序改为「`LOADL fn` → 实参左→右」，纯文档修订。

### 偏差 B：头布局判据 — **合规**

- **事实**：`FbcHeader.isLegacyLayout()` 为 `verMajor == M1_MAJOR && verMinor <= 13`（`FbcHeader.cj:112`）。
- **判定依据**：M2 格式固定 `verMajor 2 / verMinor 0`（doc 行 5）；M1 旧布局只属于 verMajor 1 的历史产物（M1 §11.6）。若沿用「verMinor ≤ 13」会把 M2 误判为旧布局。
- **裁定**：**合规**。不改变 M1 读取路径，且 M2 产物按新布局读写。

### 偏差 C：retType 合法集 — **合规**

- **事实**：`FuncDir.validate(codeLen, entryFn, verMajor)` 与 `LocalTypes.validate(..., verMajor)` 都委托 `LocalType.isLegal(code, verMajor)`（`FuncDir.cj:187-200`、`LocalTypes.cj:104-114`）。
- **判定依据**：`f-jit-base-contracts / LocalType 编码与查询 / 版本分派合法集`、`f-jit-bytecode-format / 函数目录与局部类型表校验 / 类型表按版本拒绝`；与 `FbcRuleSet.isLocalTypeInLegalSet` 同源。
- **裁定**：**合规**。

### 偏差 D：DbgDump 输出 — **真实缺口（阻塞）**

- **事实**：实际 `HostClosure#N` / `HostObject#N`（无尖括号）。
- **判定依据**：`f-jit-runtime / 单次诊断转储与报告组装` 与 scenario `13/14 大类名呈现`；doc 行 162–163 均为 `<HostClosure>#idx` / `<HostObject>#idx`。
- **阻塞**：`f-jit-runtime / 单次诊断转储与报告组装 / 13/14 大类名呈现`。
- **裁定**：**真实缺口（阻塞）**。改实现 2 处字符串 + 同步测试期望即可；不建议改规格（doc 与 delta 一致）。

### 已知限制 ①：验签/H63 仅 0–2 元 — **真实缺口（阻塞）**

- **判定依据**：doc **§4**「一次类型判定……不另设分步核对」；`f-jit-runtime / 签名验签与条目缓存 / 单次判定覆盖全部不符`；`f-jit-facade-bridge / 参数封送与返回解包表 / HostClosure 实参`。规格未给元数上限。
- **阻塞**：上述两个 scenario 的「参数个数」维度；>2 元的合法 M2 程序被 19/99 拒绝。
- **裁定**：**真实缺口（阻塞）**。要么扩展分派表，要么由用户裁定把 M2 元数上限写进规格（修订后才能改判为「可接受偏离」）。

### 已知限制 ②：14 槽无具体类载体 — **真实缺口（阻塞）**

- **判定依据**：doc **§16.4**「验签（§4）：函数类型整体判定（P1）覆盖 14 槽之具体类」；`f-jit-facade-bridge / 宿主对象实参通道 / HostClosure 签名含 14`（WHEN `(User) -> Order`）；`f-jit-runtime / 签名验签与条目缓存 / 单次判定覆盖全部不符`（逐参不符）。
- **阻塞**：`HostClosure 签名含 14` 的声明形态；`单次判定覆盖全部不符` 的 14 维度。
- **裁定**：**真实缺口（阻塞）**。现行 `(Object)->…` + 体内 `is` 是可用工作区，但与规格文字不一致；需补类名载体或修订规格。

### 已知限制 ③：反射自动访问器只按精确类 — **真实缺口（阻塞）**

- **判定依据**：`f-jit-facade-bridge / 反射自动注册的覆盖面 / 全覆盖与逐项等价`（自动 ≡ 手工）；`宿主对象实参通道 / 源入口实参身份`（子类实例作为父类声明实参）；`design-m2` M2-7（宿主侧访问器可按继承逐级向上）。
- **阻塞**：`全覆盖与逐项等价` 的子类维度；`源入口实参身份` 的子类成员访问路径。
- **裁定**：**真实缺口（阻塞）**。`std.reflect` 的限制真实存在，但规格承诺了继承语义；需逐祖先生成访问器，或在规格/设计中显式收窄并给出「子类须手工注册」的用户契约。

### 已知限制 ④：`null` 不能作 `Any` — **合规**

- **判定依据**：`f-jit-facade-bridge / 参数封送与返回解包表 / 注册类实参`（null → 19）；Cangjie 中 `null` 只属于 `Option`，`Option.None` 是语言级空值。
- **证据**：`CallMarshalM2_test.wrongClassAndNullAreRejected` 以 `?ManualUser = None` 走 19（site=-1）。
- **裁定**：**合规**（语言语义等价，不是实现缺口）。

### 已知限制 ⑤：运行期容器为 `ArrayList<Any>` — **合规（需文档说明）**

- **判定依据**：`f-jit-base-contracts / LocalType 编码与查询` 与 M1 类型表把 LIST/MAP 定义为 `ArrayList<Any>` / `HashMap<ConstMapKey, Any>`；`call<T>` 的 `T` 必须与声明表示一致。
- **裁定**：**合规**。`List<Int64>`/`ArrayList<Int64>` 是不同类型，不能承接是类型系统结果；建议在用户文档中写明「容器返回类型为 `ArrayList<Any>` / `HashMap<ConstMapKey,Any>`」。

### 已知限制 ⑥：x86_64 非本机原生 — **合规（规格允许跳过）**

- **判定依据**：`f-jit-differential-acceptance / M2 差分矩阵与确定性宿主闭包 / 三引擎逐位一致` 明写「非原生架构按既有条件跳过策略标记」。
- **证据**：本机 `Interp × AArch64` 逐位一致；`X86Lower.cj:941` 的 `0x79` 路由存在但无 `X86Exec` 用例。
- **裁定**：**合规**（M2 语义不因缺 x86 证据而违规）；但作为工程债记入 GAP-12，建议 CI 补 `X86Exec` 的 CALL_HOST/成员/构造三例。

## 本轮执行的校验

| 命令 | 结果 |
|---|---|
| `cd f_jit && cjpm build` | **成功**，墙钟 2m33.9s；6 条警告（5 条 unused / 1 条 unreachable pattern），无错误 |
| `cd f_jit && cjpm test` | **826 / 826 通过，0 失败 / 0 跳过 / 0 错误**；墙钟 3m44.4s，测试执行 16.8s |
| `bash f_jit/scripts/check_tmap.sh` | 40 条 **M1** 范围内映射，悬空/未断言 **0**（不含 M2） |
| `bash f_jit/scripts/check_scenarios.sh` | 156 条 **M1** 映射（full 139 / partial 5 / 缺口 7 / N/A 5），未映射 0、缺失 0（不含 M2） |
| `git status --porcelain` | 空（校验前工作区干净） |
| `openspec archive` / `sync` | **未执行**（按要求） |

> 测试总数 826 = M1 560 + M2 266。M1 纯基线数字与 `doc/spec/f-jit-m2/baseline.md` 的 560/560 一致，零回归成立。

## archive 建议

**可以进入 archive。** 原建议清单保留作处置记录（GAP-01–09 均已划线完成）：

1. **GAP-01**：`Root.cj` 补六条 `public import`，补一条「只 import 根包」的 M2 端到端用例。
2. **GAP-06**：`DbgDump` 加尖括号并同步测试期望（最小改动）。
3. ~~**GAP-05 / GAP-04**~~ **（已完成 2026-10-20）**：用户裁定改实现——`FunctionTypeInfo` 验签 + `apply` 调用；类名经 `HostClosureT` 与 `SignatureDescriptor` 穿透；规格 §4/§5/§8/§9.1/T30 同步（m2 v0.8.33）。
4. ~~**GAP-03**~~ **（已完成 2026-10-20）**：类型判定改沿 `superClass` 链；反射执行层的精确类限制经实测固化为已知限制与对应用例。
5. **GAP-02**：补 M2 `TCoverage`、`scenario-map.tsv` 与脚本，跑 `--strict`。
6. **GAP-07**：把糖、对象身份、14 与句柄型参数纳入 `DiffSession`。
7. ~~**GAP-08**~~ **（已完成 2026-10-20）**：`PerfM2_test` + `doc/perf-m2.md`；实测 4.6–5.8×，用户裁定接受现状、规格 §8 按实测修订。
8. **GAP-09**：回写三份权威文档 + 同步 `tasks.md` 镜像 + 三表抽样记录。

完成 1–8（GAP-01–09）后重跑 `cjpm build`、`cjpm test`、M2 场景矩阵与差分，再进入 archive。
