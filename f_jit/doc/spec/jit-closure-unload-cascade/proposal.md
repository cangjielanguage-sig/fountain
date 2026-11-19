# Proposal

## Why

逃逸闭包（JIT 返回、由 `callForFn<Fn>` 承接的 `JitFunction` 包装实例）的释放有两处缺口：

1. **单元卸载不级联释放闭包**。单元进入终态后包装实例的调用恒以 19 失败，其提升组（闭包自身槽 + 句柄型捕获所指的槽）却仍被 `HandleTable` pin 住；`unload()` 的 `release` 回调只释放代码内存与常量（`CompilePipeline.cj:241-244`），提升组的唯一释放路径是包装实例上的 `unloadFn()`。宿主漏调一次即永久驻留，`README.md` 目前把这条写成「契约，非 bug」——单元已死、资源还挂着，是自相矛盾的状态。
2. **释放入口分裂且互相误导**。`unload()` 在入口实例上是单元卸载，在包装实例上却**转交**单元卸载（`JitFunction.cj:187-191`），并不释放提升组；真正释放闭包的 `unloadFn()` 是另一个名字。`isUnloaded()` 在包装实例上报的又是单元状态（与 `isClosed` 两套谓词），使「这个包装到底释放了没有」没有单一答案。

## What Changes

- **登记逃逸闭包**：`JitFunction`（单元）新增逃逸闭包登记表；`wrapClosure` 产出包装实例时登记到 owner，包装实例释放时摘除。
- **单元卸载级联释放**：`unload()` 进入终态（已排空）时**先**释放全部登记在册的逃逸闭包（提升组 `releaseAll()` + 包装实例置为已释放），**再**逐出编译缓存、释放代码内存/常量；超时回退路径不释放（单元仍可用）。
- **BREAKING**：`unloadFn()` 改 `private`（保留为实现细节）；`unload()` 在包装实例上改为「释放本函数值」的语义（释放本实例提升组、幂等、返回 `true`），不再转交单元卸载。
- **BREAKING**：仓内全部 `unloadFn()` 调用改为 `unload()`；随 API 收窄删除「入口实例调用 `unloadFn` → 19」的用例。
- `isUnloaded()` 在包装实例上改为 `isClosed || owner.isUnloaded()`，与 `unload()` 的粒度一致；`isClosed` 保留原名（描述包装实例自身是否已释放）。
- 文档与规格同步：`f_jit/README.md` / `README_en.md`、`doc/design-m2.md` §6.1.4、`doc/jit-bytecode-m2.md` §14.2/§14.4。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `f-jit-facade-bridge`: 「统一调用包装」的释放入口由 `unloadFn` 收窄为 `unload`（包装实例 = 释放本闭包）；「卸载状态机与资产清点」新增「单元终态级联释放登记在册的逃逸闭包」。
  （该能力此前只存在于模块内规格副本 `f_jit/doc/spec/*`，`openspec/specs/` 尚无条目 ⇒ delta 以 **ADDED** 形式落库，`archive` 后成为首个主规范条目。）

## Impact

- **API（破坏性）**：`JitFunction.unloadFn` 由 `public` 改 `private`；`unload` 在包装实例上的语义与返回值变化（原为单元卸载的委托，现为释放本闭包并返回 `true`）。仓外调用方会得到编译错误，而非静默失效。
- **生命周期**：单元卸载后提升组不再常驻；单元对登记在册的包装实例持强引用，直到该闭包被释放或单元卸载。
- **性能**：`wrapClosure` 增加一次表操作、`unload` 增加一次遍历；不在调用热路径上。
- **一并修复的三条缺陷**（用户 2026-10-27 判定纳入本次范围）：
  - **B1 未承接的逃逸组丢组**：`call<JitClosureId>` 未经 `callForFn` 承接时，`lastClosureGroup` 被下一次闭包返回覆盖，该组失去引用且永不释放 ⇒ 提升槽永久 pin。修法：登记点上移到**提升组产生处**（`callLocked` 解包 `retType=12`），与是否承接无关。
  - **B2 包装释放不与在飞调用互斥**：`unloadFn` 不排空，另一线程正在通过同一包装调用时释放提升组，在飞调用随后以陈旧句柄错误失败。修法：条目带 `active` 计数，释放走「卸载中 → 排空 → 已释放」，超时回退可用并返回 `false`。
  - **B3 单元强引用包装实例**：登记包装实例会使单元钉住全部包装对象。修法：登记**条目**（组 + 状态 + 计数），不引用包装实例，宿主丢弃包装后对象可回收。
- **不在本次范围**：宿主既不释放、单元也不卸载期间的组驻留（既有契约）；闭包内部重入释放自己（重入时 `active≥1` → 立即 `false`，记为边界 B5）；编译缓存键/逐出语义不变。
