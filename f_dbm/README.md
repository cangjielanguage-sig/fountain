# f_dbm

数据库中间件的**扩展接口库**。fdbm 是可执行模块，外部无法 import 它的声明，因此把可扩展
契约下沉到这里；第三方扩展只依赖本模块（以及 `f_app` 的 `Initializer`），编译成动态库放进
fdbm 的 `custom/` 目录即可被发现。

## 接口

```cangjie
package fountain::f_dbm

public interface PartitionAlgorithm {
    prop name: String                 // 对应 fdbm_partition__<table> 的算法名
    func partition<K>(key: K): String // 返回物理库名
}

public interface IdGenerator {
    prop name: String                 // 对应 fdbm_idmaker 的取值
    func nextStringId(): String       // 默认抛 IdGeneratorException
    func nextIntId(): Int64           // 默认抛 IdGeneratorException
}
```

- 分区算法由 fdbm 在启动时按表配置实例化（`PartitionAlgorithmFactory`）；内置算法
  `step` / `hash` / `std` / `crc16` / `crc32` / `crc64` / `murmur` / `substr` 在 `fdbm` 内实现。
- ID 生成器只在 INSERT **缺分库列值**时介入；`uuid` / `snowflake` 与表无关，
  `sequence` 按 `(逻辑库, 表)` 在唯一分配库取号。未配置生成器又缺分库列值时返回 `ROUTE_FAILED`。
- `IdGeneratorException` 是 `f_dbm` 自己的异常类型，生成器实现应抛它而不是裸 `Exception`。
- **只实现一种能力是合法用法**：例如只实现 `nextStringId()`，调用方在需要整型 ID 时按能力回退；
  两个默认方法都未实现时调用方映射为 `ID_GENERATOR`。
- **与内置名重名不允许覆盖**：自定义 `name` 等于 `step`/`hash`/... 或 `uuid`/`snowflake`/`sequence`
  时，fdbm 启动自检直接失败。

## 写一个自定义扩展

```cangjie
package my.ext

import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_dbm.PartitionAlgorithm

class MyPartition <: PartitionAlgorithm & Initializer {
    static init() {
        InitializerCollection.register(MyPartition())   // 必须在 static init 里注册
    }
    private init() {}

    public prop name: String { get() { "myhash" } }

    public func partition<K>(key: K): String { /* ... */ }

    public func initialize(): Unit {
        // 只能读 Config、准备自身状态；此时 fdbm 的资源/驱动/服务都还没创建
    }
}
```

编译为动态库后放入 fdbm 部署目录的 `custom/`。加载顺序与约束（见 fdbm 详细设计 §10.5）：

1. fdbm 先把 `custom/` 下**全部**动态库 `PackageInfo.load`，再调用一次
   `InitializerCollection.initialize()`，因此各库 `static init` 的注册都能被看到；
2. 用两轮模式匹配收集 `PartitionAlgorithm` 与 `IdGenerator`（同一实例可同时命中两者）；
3. 自定义之间重名 → `CONFIG` / `PARTITION_CONFIG` 启动失败；与内置同名时**自定义优先**
   （算法/生成器工厂先查自定义，再查内置），因此可以用自定义实现覆盖内置实现；
4. 任一库加载失败或任一 `initialize()` 抛异常 → `CONFIG` 启动失败；
5. `custom/` 目录不存在表示没有扩展；目录里只应放扩展库（所有 `Initializer` 都会被执行）。

扩展库需与 `f_dbm` / `f_app` 在同一库搜索路径（通常就是 fdbm 部署目录）。
