# Proposal

## Why

f_jit 目前**完全不支持 interface**，四道门槛都实测过：

1. `registerType<T>() where T <: Object` 编译期拒绝接口（`Interface-Greeter is not a subtype of Class-Object`）；
2. 注册体 `match (info) { case c: ClassTypeInfo }` 对接口以 `ReflectionUnavailable` 拒绝；
3. 真正卡住「用实参调接口成员」的是反射：`InterfaceTypeInfo.instanceFunctions` 能列出方法，但它们是**抽象声明**，`InstanceFunctionInfo.apply` 直接抛 `Cannot invoke abstract function 'greet'`；
4. `call<Greeter>` 报「T 不是可解包类型」——`localTypeOf` 只认 `ClassTypeInfo`。

同时，注册类时只登记**本类声明**的成员：父类的公共方法/字段在子类描述符里不存在，`{ x: Child => x.parentMethod() }` 会报「类 Child 没有方法」。接口同理（父接口成员缺失）。

类成员的调用本来就走 `@JitBind` 生成的**强类型闭包**（首参 14 → 强转到类 → 直调），不经反射。接口完全可以复用这条路：把接收者强转到**接口**即可，抽象性不再是问题。

## What Changes

- **`@JitBind` 支持接口**：接受 `InterfaceDecl`，为公开方法与属性生成同样的强类型绑定（`args[0] as I` 后直调），并把 `superTypes` 的接口名一并登记。
- **新增 `registerInterface<I>()`**：无 `T <: Object` 约束；接口必须有 `@JitBind`（抽象方法无法反射调用），否则注册期以明确诊断拒绝；父接口成员在注册期并入子接口描述符。
- **类注册并入父类成员**：沿 `superClass` 链收集公共方法/属性/字段（子类覆盖优先），字段**重新编号**后登记（字段表支持同 index 多访问器 + `accepts` 过滤）。
- **14 的实例判定扩为「类祖先 ∪ 接口谓词」**：宏登记 `o is I` 谓词，`CallMarshal` 的形参校验与 `E as I` 共用。
- **返回类型支持接口**：`localTypeOf` 对 `InterfaceTypeInfo` 返回 14，`call<I>` 可用（`v as T` 对接口是合法转换）。

## Capabilities

### Modified Capabilities

- `f-jit-facade-bridge`：新增「接口注册与父成员继承」。
- `f-jit-compiler-frontend`：成员解析覆盖父类/父接口成员。

## Impact

- **代码**：`macros/JitBind.cj`、`base/JitBindings.cj`、`JitBindSupport.cj`、`ReflectRegistrar.cj`、`ClassRegistration.cj`（描述符加 `isInterface`）、`CallMarshal.cj`、`JitFunction.cj`。
- **API**：新增 `registerInterface<I>()`、`JitBindings.parents`；无破坏性删除。
- **语义**：父类/父接口成员在子类型上可访问；接口实参按 `is I` 校验；接口返回值按 14 交付。
- **不在本次范围**：多重继承歧义消解（仓颉接口无菱形继承）、接口默认方法的反射回退（仍要求 `@JitBind`）。
