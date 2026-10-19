# Proposal

## Why

M1 已交付「一份跨平台字节码 + 解释器 + 两架构 JIT 后端 + 封闭宿主桥」，但字节码世界与宿主仓颉之间仍只有单向、封闭的调用关系：宿主不能把闭包交给字节码调用，字节码不能读取宿主类实例的成员，也不能在字节码侧构造宿主类实例，更不能把闭包带回宿主。M1 的 `.fbc` 只接受 verMajor 1，`CALL_HOST`（0x79）仍是一个汇编期 `ERR_NOT_IMPL` 的预留槽，LocalType 合法集止于 12。

M2 规格（`f_jit/doc/jit-bytecode-m2.md` v0.8.32）、详细设计（`design-m2.md`）与 TDD 计划（`plan-m2.md`，Q0–Q6）已经冻结。本次变更把 M2 增量落成可实施的 OpenSpec 计划：以 **verMajor 2** 产物为边界，开放宿主闭包实参、不透明宿主对象通道、成员访问、逃逸闭包回桥、字节码侧构造与宿主对象实参六篇增量，同时保证 **M1 产物与语义零变化**。

## What Changes

- **兼容基建（Q0）**：`Version` 增加多版本常量与 `supportedMajors()`；`FbcReader` 按 `verMajor` 分派校验规则集（v1 / v2 / v3 登记），建立 M1 全量回归基线。
- **`base` 增量（Q1）**：`LocalType.HOST_CLOSURE=13` / `HOST_OBJECT=14`（`isHandle` 扩展）、`TypeToken.HOST_CLOSURE=10` / `HOST_OBJECT=11`、`ErrCode.HOST_EXCEPTION=21`（`isHostSide` 落地）、M2 版本常量；新增 `ClassDescriptor` / `PublicField` / `PublicMethod` / `PublicCtor` 注册协议值类型，以及**不占 ErrCode** 的宿主侧 `RegistrationException <: f_base.BaseException` 与六值 `RegistrationRejectKind`。
- **`bytecode` 增量（Q2）**：`OPCODE_TABLE[0x79]` 改为 `CALL_HOST`（`u8 argc`、`len=2`、`CAT_CALL`）；加载器按 `verMajor` 分派合法集（v1: 0–12；v2: 0–14；v3: 0–19 登记）；M1 加载器遇 v2 拒绝（18）；汇编期校验 `CALL_HOST` 的 argc 展开与 `[h_fn, a1..an]` 栈布局。
- **`compiler` 增量（Q3）**：新增 `TypeRef`（Builtin / HostClosureT / HostObjectT）与 `ClassRegistryView`；`NameResolver` 解析顺序扩展并拒绝 HostClosure 形参与 user helper 同名；`Lowerer` 增加 CALL_HOST、成员访问糖（`u.f` / `u.f=v` / `u.m(...)`）、构造 `C(args...)` 与 14 槽降低；`AstExpr` 增四构造器；`DefiniteAssignment` 支持 13/14 槽；逃逸闭包捕获描述符按「白名单版（第 0 步）→ 放开句柄型捕获（第 1 步）」两步交付。
- **`runtime` 增量（Q4）**：新增 `HostCallback`、`SignatureDescriptor`、`SignatureVerifier`、`PromotionGroup` 与 H63/H64/H65；`HandleTable` 支持 tag 10/11 与 `moveOutGroup`；`Interp` 增加 `CALL_HOST` 语义；`DbgDump` 对 13/14 按 `<HostClosure>#idx` / `<HostObject>#idx` 大类名呈现。
- **根包增量（Q5）**：新增 `ClassRegistry`、`ReflectRegistrar`、`JitClosureId`；`Compiler` 增加 `registerClass` / `registerType<T>`；`CallMarshal` 增加宿主闭包、注册类实参与 `retType` 12/13/14 行；`JitFunction` 增加闭包包装（`call<T>` / `close` / `isClosed`）与 `callFor<Fn>`；覆盖源入口实参、槽 14 链内传参与 HostClosure 签名含 14。
- **差分验收（Q6）**：T30–T36、T49、T54、T55、T57–T60 接入差分 harness；M1 全量回归作为每步硬门槛；错误码 21 与 99 严格区分；容量/窗口账目与无泄漏断言留档。
- **无破坏性改动**：M1（verMajor 1）产物语义、加载路径、ctx/帧布局、全部 M1 指令语义与冻结决策不变；M2 只增加 verMajor 2 规则集与既有通道的受控扩展，不新增公开错误码以外的执行机制。

## Capabilities

### New Capabilities

（无。M2 是对 M1 已交付能力的增量扩展，不新增 capability。）

### Modified Capabilities

- `f-jit-base-contracts`: `LocalType` / `TypeToken` / `ErrCode` / `Version` 扩展；新增类注册协议值类型与 `RegistrationException` / `RegistrationRejectKind`。
- `f-jit-bytecode-format`: `CALL_HOST` opcode 行、`verMajor` 规则集分派、局部类型合法集与加载/汇编校验增量。
- `f-jit-compiler-frontend`: 类型记法解析、编译期类注册表视图、名字解析扩展、CALL_HOST/成员访问/构造降低、13/14 槽明确赋值与逃逸闭包捕获白名单。
- `f-jit-runtime`: 句柄 tag 10/11、签名验签、H63/H64/H65、提升组、`CALL_HOST` 解释语义、13/14 报告呈现。
- `f-jit-facade-bridge`: 类注册表与反射自动注册、构造器物化、参数/返回 Marshal 新行、`JitFunction` 闭包包装与 `callFor<Fn>`、宿主对象实参三方向。
- `f-jit-differential-acceptance`: M2 T 系列映射、M1 零回归门槛、21/99 分类、引用身份与无泄漏差分断言、文档回写。

## Impact

- **代码**：`f_jit/src/base`（常量、注册协议、注册异常）、`f_jit/src/bytecode`（opcode 行、规则集、类型表校验）、`f_jit/src/compiler`（TypeRef、ClassRegistryView、NameResolver、Lowerer、AstExpr、DefiniteAssignment）、`f_jit/src/runtime`（HostCallback、SignatureVerifier、H63–H65、PromotionGroup、HandleTable、Interp、DbgDump）、根包（ClassRegistry、ReflectRegistrar、JitClosureId、Compiler、CallMarshal、JitFunction）与 `f_jit/src/test/diff`。不修改 M1 的既有公开语义；不改根 `cjpm.toml`（沿用 M1 用户裁定，模块独立构建）。
- **API**：新增用户面 `ClassDescriptor` / `PublicField` / `PublicMethod` / `PublicCtor` / `RegistrationException` / `RegistrationRejectKind` / `JitClosureId`，以及 `Compiler.registerClass` / `Compiler.registerType<T>` / `JitFunction.callFor<Fn>` / `JitFunction.close` / `JitFunction.isClosed`；`ClassRegistry` / `ReflectRegistrar` 保持 `protected`。`LocalType` / `TypeToken` / `ErrCode` / `Version` 为纯增量常量。
- **格式与兼容**：`.fbc` **verMajor 2**（verMinor 0）；v1 产物由 M2 加载器按 v1 规则集继续全语义支持；M1 加载器遇 v2 以 18 拒绝；LocalType 20–255 恒拒绝；HostClosure / HostObject 不可常量化，常量 kind 1–10 不变；捕获描述符与注册项均**不入** `.fbc`。
- **依赖**：不新增外部依赖；`std.reflect` 仅用于宿主侧注册期（默认构建），字节码/JIT 执行路径零反射；M3 的 Any/JSON（15–19、token 12、错误码 22）不在本次范围，只登记合法集边界。
- **平台**：解释器与 AArch64 后端为原生证据；x86_64 机器码断言按 M1 既有条件跳过策略执行；差分最小集仍为 `Interp × AArch64`。
- **测试**：T30–T36、T49、T54、T55、T57–T60 为 M2 新增验收面；每一步提交前跑 M1 全量回归，任何 M1 产物或行为差异按阻塞缺陷处理。
- **文档**：`design-m2.md` / `plan-m2.md` / `jit-bytecode-m2.md` 为权威依据；实现偏差按 Q6 回写；OpenSpec 产物为本次 planning 交付，不修改项目代码。
