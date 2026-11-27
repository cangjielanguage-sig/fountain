# 编译路径：名字解析索引与类快照去重

## Why

JIT 的首次编译延迟由三处 O(n) 线性扫/拷贝主导（`optimize-compile-path` 只处理了 mmap 与
`Compiler.snapshot` 缓存，这三处未动）：

| 点 | 现状 | 调用频次 |
| --- | --- | --- |
| `PredefinedSnapshot.slotOf` | `ArrayList<String>` 线性扫 + 逐字符比较 | 每个调用点 1 次（`NameResolver.resolve`） |
| `ClassRegistryView.classOf` | `Array<ClassDescriptor>` 线性扫 | 每个类型注解 1 次 |
| `ClassRegistry.snapshot` | `classes.toArray()` + `ClassRegistrySnapshot` 构造里 `clone()` = **双拷贝** | 每编译 **2 次**（`CompilePipeline.cj:74/78`） |

注册 200 个预定义函数、源码含 50 个调用点时，单次编译要做约 1 万次字符串比较；
若注册类多，类型注解再叠加同类成本。这部分与「并发编译」无关，是纯单线程编译延迟。

## What Changes

1. `PredefinedSnapshot` 构造时建 `HashMap<String, Int64>`（name → slot），`slotOf` 改 O(1)；
   `has` / `paramTypesOf` / `retTypeOf` 复用 `slotOf`；
2. `ClassRegistryView` 构造时建 `HashMap<String, ClassDescriptor>`，`classOf` 改 O(1)；
3. `ClassRegistrySnapshot` 构造不再 `clone()`（调用方 `toArray()` 已是副本）；
4. `Compiler.classSnapshot()` 加缓存，注册类/接口时失效（与 `snapCache` 同生命周期）。

**语义不变**：slot 编号、重名拒绝、快照隔离、`ClassDescriptor` 内容全部不变；
索引只是同一份数据的另一种视图。

## Impact

- 收益目标：注册 200 函数 × 50 调用点的单次编译时间下降 ≥10%；
- 影响文件：`src/compiler/PredefinedSnapshot.cj`、`src/compiler/ClassRegistryView.cj`、
  `src/ClassRegistry.cj`、`src/Compiler.cj`；
- 风险：`ClassRegistrySnapshot` 去 `clone` 后，调用方若复用传入数组会被外部修改 ——
  当前唯一调用方 `ClassRegistry.snapshot()` 每次 `toArray()` 新建，安全；
  以「注册后编译可见 / 旧快照不受影响」用例锁住。
