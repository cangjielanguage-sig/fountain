# Verify

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线 | 1127 用例 / 1127 通过 / 0 失败 |
| 终态 | **1133 用例 / 1133 通过 / 0 失败 / 0 error / 0 skipped** |
| 新增用例 | 6 条（`Interface_test` 4 + `Inheritance_test` 2） |
| 回归 | 0 |

## 落点

| 项 | 实现 | 用例 |
| --- | --- | --- |
| `@JitBind` 支持接口 | 接受 `InterfaceDecl`（`f_macros` 补 `extend InterfaceDecl <: CompositeDecl`），生成「首参 14 → `args[0] as I` → 直调」的绑定；`superTypes` 名进 `parents` | `Interface_test.*` |
| `registerInterface<I>()` | 无 `T <: Object` 约束；父接口方法并入；`ClassDescriptor(isInterface = true)`；方法 bind 注册为预定义函数 | `interfaceParamCallsOwnMethod` |
| 父接口成员 | 宏 `parents` + 注册期按名复制父描述符方法（父须先注册） | `parentInterfaceMemberIsVisible` |
| 接口返回类型 | `localTypeOf` / `mapType` 把 `InterfaceTypeInfo` 映射为 14 | `interfaceAsReturnType` |
| 未绑定接口 | 注册期 `RegistrationException`（「接口必须用 @JitBind」） | `unboundInterfaceIsRejected` |
| 父类成员继承 | `mergeAncestorFields`（自有字段之前，先占号）+ `mergeAncestorMethods`（自有方法之后，子覆盖优先） | `derivedSeesInheritedMembers` / `overrideWins` |
| 14 的实例判定 | `isInstanceOfHost` = 类祖先 ∪ 接口谓词；`CallMarshal` 改用 | 接口形参用例 |

## 实施中发现的两个真问题（已修）

1. **`withOverrides` 丢 `parents`**：它新建 `JitBindings` 时没带 `parents`，导致接口的父接口列表在合并 overrides 后为空 → `parentInterfaceMemberIsVisible` 报「类 ProbeGreeter 未注册方法 name」。修：透传 `this.parents`。
2. **字段 index 全局撞车**：字段表是全局 index 空间（同 index 多访问器靠 `accepts` 区分）。子类自有字段若也从 0 编号，bucket 0 里父类访问器先命中 → 读成父类同号字段。实测 `m()+f+d+own()` 得 32（`d` 读成 `f`=1），期望 33。修：**父类字段先占号**（`mergeAncestorFields` 在自有字段之前跑），自有字段从 k 开始编号。

## 语义边界

- 接口必须 `@JitBind`：反射的接口方法是抽象声明，`apply` 必抛 `Cannot invoke abstract function`，因此不提供反射回退。
- 父接口必须先注册，否则其方法不会并入（当前静默跳过；`verify` 记录为已知边界）。
- 类继承要求父类 `open`、被覆盖方法 `open`（仓颉语言规则，测试里已按此声明）。
- 接口无字段/构造器；`ClassDescriptor.isInterface` 供前端诊断。

## 归档

| 项 | 结果 |
| --- | --- |
| 命令 | `openspec archive feat-f-jit-interface-and-inheritance --yes` |
| 增量应用 | **+2 added / ~0 modified**（facade-bridge「接口注册与父成员继承」、compiler-frontend「父类型成员的解析」） |
| 归档路径 | `openspec/changes/archive/2026-10-23-feat-f-jit-interface-and-inheritance/` |
