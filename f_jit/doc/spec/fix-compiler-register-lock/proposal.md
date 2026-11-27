# 注册表写入的一致性（H5）

## Why

`src/Compiler.cj` 的注册入口把「类注册表写入」放在 `this.mtx` **之外**：

```cangjie
public func registerClass(desc: ClassDescriptor): Unit {
    this.classes.register(desc)          // ← 锁外（内部只有 ClassRegistry 自己的 mtx）
    synchronized(this.mtx) {
        for (m in desc.methods) { … }    // ← 方法并入 fns + 清快照缓存
        this.snapCache = None
    }
}
```

`registerType` / `registerInterface` 同样是「锁外做反射注册、锁内清缓存」。

后果：并发注册时存在一个可观察的**中间态**——类已在 `ClassRegistry` 里，但它的方法还没
进入 `Compiler.fns`，且 `snapCache` 尚未失效。此时另一个线程 `compile()` 会拿到
「一半的注册表」：类能解析，方法名却不在函数快照里，得到 `UnregisteredFunction`。

注册通常是启动期单线程完成的，文档也没承诺线程安全；但这是**未定义语义**，
而修法成本极低。

## What Changes

把注册写入整体移入 `synchronized(this.mtx)`：

- `registerClass`：`classes.register` 与方法并入、`snapCache = None` 同处一个临界区；
- `registerType` / `registerInterface`：`ReflectRegistrar` 调用与 `snapCache = None` 同处一个临界区。

**锁序**：`this.mtx → ClassRegistry.mtx / ReflectRegistrar.retainedMtx`。与 `snapshot()`
（已在 `this.mtx` 内调 `classes.autoFunctions()`）一致；`ClassRegistry` 与 `ReflectRegistrar`
都不会回调 `Compiler`，因此不存在反向路径。

代价：注册期间持锁做反射（`registerType`）。注册是冷路径，且它本来就要在锁内更新
`snapCache`；把反射也包进来只是把临界区从「微秒级」拉长到「毫秒级」，不影响调用路径。

## Impact

- 影响文件：`src/Compiler.cj`（3 个方法）；
- 护栏：新增 `CompilerRegistrationConcurrency_test`——4 线程并发注册 100 个不同类
  （每个类带 2 个方法），另一线程同时反复 `compile` 引用这些方法的源码；
  断言注册全部成功、`registeredNames()` 不丢项、编译不因「半套注册表」失败。
- 风险：低。单线程行为完全不变。
