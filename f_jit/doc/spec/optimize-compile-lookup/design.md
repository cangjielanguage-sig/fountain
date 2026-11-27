# 设计：名字解析索引与类快照缓存

## D1 为什么这次 HashMap 值得（与 §15.3 反例的区别）

`optimize-signature-tables` §15.3 的教训是「小表（个位数）每次现拼字符串键做索引」负优化。
本变更不同：

| 维度 | §15.3 反例 | 本变更 |
| --- | --- | --- |
| 表规模 | 个位数条目 | 预定义函数 200+、注册类 几十 |
| 键来源 | 每次**拼接** `StringBuilder` | 现成的 `name`（`ArrayList<String>` 里已有） |
| 查询次数 | 每次构造 1–2 次 | 每个调用点 / 类型注解 1 次，单次编译几十次 |
| 构建次数 | 每次构造都建 | 快照构造时建一次，随快照复用 |

因此 `HashMap<String, Int64>` 的构建成本被「每个调用点一次查询」摊薄。

## D2 `PredefinedSnapshot` 索引

```cangjie
private let index: HashMap<String, Int64>

// init：遍历 names，首次出现的下标即为 slot（与线性扫「第一个命中」一致）
```

- `slotOf(name)` → `index.get(name) ?? -1`；
- `has` / `paramTypesOf` / `retTypeOf` 复用 `slotOf`（不再各扫一遍）；
- 重名：`Compiler.registerFunction` 已拒绝重名，索引保留首次出现与线性扫语义一致。

## D3 `ClassRegistryView` 索引

`ClassRegistryView` 构造时把 `snapshot.classes` 建成 `HashMap<String, ClassDescriptor>`；
`classOf` → `map.get(name)`。同样保留「首次出现」语义（注册表拒绝重名）。

## D4 类快照缓存

`Compiler.classSnapshot()` 目前每次 `classes.snapshot()`：`toArray()` + 构造里 `clone()`，
`CompilePipeline.runSource` 每编译调 **2 次**。改为：

- `Compiler` 增 `private var classSnapCache: ?ClassRegistrySnapshot = None`；`registerClass` /
  `registerType` / `registerInterface` 置空（与 `snapCache` 同生命周期）；
- `CompilePipeline.runSource` 只取一次，传给 `SourceCompiler` 与 `makeFunctionWith`。

**不动** `ClassRegistrySnapshot` 的 `clone()`：`ClassRegistryView.cj:212` 等地直接把外部数组
传进构造，去掉拷贝会让视图持有可变数组，风险大于收益。

## D5 护栏与变异

新增 `CompileLookupIndex_test`：

1. **索引与线性扫等价**：注册 200 个函数（含边界名），对每个名字断言
   `snapshot.slotOf(name)` 等于手工统计的下标；不存在的名字 → −1；
2. **类索引等价**：构造 50 个类描述符，`ClassRegistryView.classOf` 逐个命中；未注册 → None；
3. **注册后可见**：`registerFunction` 后编译一个调用它的源码成功；`CompileCache.reset()` 后
   再编译仍成功（缓存失效正确）。

变异：

- 索引构建时漏掉最后一个元素 ⇒ 第 1 条对最后一个名字的断言变红；
- `classSnapCache` 在注册时不失效 ⇒ 第 3 条变红（编译看不到新注册）。
