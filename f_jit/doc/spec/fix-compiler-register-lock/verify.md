# 验证：fix-compiler-register-lock

## 1. 改动

`src/Compiler.cj` 三个注册入口：

```diff
 public func registerClass(desc: ClassDescriptor): Unit {
-    this.classes.register(desc)
     synchronized(this.mtx) {
+        this.classes.register(desc)
         for (m in desc.methods) { … }
         this.snapCache = None
     }
 }

 public func registerType<T>(…): Unit where T <: Object {
-    ReflectRegistrar.registerType<T>(into: this.classes, …)
     synchronized(this.mtx) {
+        ReflectRegistrar.registerType<T>(into: this.classes, …)
         this.snapCache = None
     }
 }
```

`registerInterface` 同 `registerType`。

**锁序**：`this.mtx → ClassRegistry.mtx / ReflectRegistrar.retainedMtx`。与 `snapshot()`
（已在 `this.mtx` 内调 `classes.autoFunctions()`）一致；`ClassRegistry` 与 `ReflectRegistrar`
都不回调 `Compiler`，无反向路径。

## 2. 新增护栏

`src/CompilerRegistrationConcurrency_test.cj`：

- 4 线程各注册 20 个类（每类 1 个方法），每次注册后**成对断言**
  `hasClass(name)` 与 `hasFunction(name + '.m')` 同时为真——这是「半套注册表」的直接探针；
- 注册完成后逐个编译 80 份引用这些方法的源码（`{ u: Cls => u.m(1) }`），全部成功且 JIT 化。

## 3. 改前对照（诚实说明）

把 `src/Compiler.cj` 的改动 `git stash` 后在**旧实现**上跑同一用例：

```
[ PASSED ] CASE: concurrentRegistrationKeepsRegistryComplete
```

**旧实现也通过**。原因是窗口极窄：`classes.register(desc)` 返回后只有几条指令就进入
`synchronized(this.mtx)`，测试线程几乎不可能精确落在这一窗口内。

因此本条**没有**「改前红、改后绿」的变异证据。它的价值是把「并发注册的未定义语义」
收敛为「有明确锁序的正确语义」，而不是修复一个已观测到的故障。

## 4. 回归

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `CompilerRegistrationConcurrency_test` | 1 | 全绿（新增） |
| `CompilerRegistration_test` / `ClassRegistry_test` | — | 全量覆盖，全绿 |

## 5. 全量

`cjpm test --parallel 1`：**1257 / 1257，0 失败 0 错误**（较改前 1256 多出本次 1 条）。
