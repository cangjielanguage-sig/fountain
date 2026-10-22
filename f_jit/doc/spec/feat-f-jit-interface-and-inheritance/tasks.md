# Tasks

## G1 宏与登记

- [x] G1.1 `JitBindings` 增加 `parents: Array<String>`。**（`withOverrides` 同步透传——漏了会让父接口列表变空）**
- [x] G1.2 `@JitBind` 接受 `InterfaceDecl`：生成方法与属性 getter（首参 14、`args[0] as I`），把 `superTypes` 名写入 `parents`；非 class/interface 仍报「@JitBind 只能修饰类或接口」。**（`f_macros` 补 `extend InterfaceDecl <: CompositeDecl`）**
- [x] G1.3 `JitBindSupport.enrollInterfaceOf<T>`：登记 bindings + parents + `{ o => o is T }` 谓词；新增 `acceptsInterface` / `parentsOf` / `isInterface`

## G2 注册

- [x] G2.1 `mapType`：`InterfaceTypeInfo → 14`
- [x] G2.2 `registerInterface<I>()`：无 Object 约束；要求 `@JitBind`；父接口方法并入；`ClassDescriptor(isInterface: true)`
- [x] G2.3 `registerType`：并入父类公共方法/属性/字段（子覆盖优先，字段重编号）。**（字段必须「先占号」：实测不先占号时 `d` 读成父类 `f`，32≠33）**

## G3 桥与前端

- [x] G3.1 `isInstanceOfHost`：类祖先 ∪ 接口谓词；`CallMarshal` 改用它
- [x] G3.2 `localTypeOf`：`InterfaceTypeInfo → 14`

## G4 测试与归档

- [x] G4.1 `Interface_test`：接口形参 + 成员调用、父接口成员、接口返回、`call<I>`、A64 `isJitBacked`。**（4/4）**
- [x] G4.2 `Inheritance_test`：子类对象访问父类方法/字段/属性。**（2/2）**
- [x] G4.3 全量零失败；`verify.md`；归档。**（1133/1133/0，归档 +2/~0）**
