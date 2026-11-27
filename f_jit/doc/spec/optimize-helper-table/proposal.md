# 调用路径：helper 表从 O(F)/call 降到 O(1)/call

## Why

`JitFunction.callLocked` 每次调用都执行：

```cangjie
if (helpers.size > 0) {
    UserHelperTable.push(0u16, helpers)      // 每次调用！
}
```

而 `push` 会 **新建 `HashMap` 并把全部 F 个 user helper 逐项插入**：

```cangjie
let table = HashMap<Int64, UserHelperEntry>()
while (i < entries.size) { table.add(...); i = i + 1 }
stack().add(table)
```

`entries` = 该单元的预定义函数 + 构造器 helper，F 等于注册函数数量。于是**每次调用付 O(F)**。

同机实测（同一份源码 `{ => fn0(1) }`，只改注册函数数量，各跑两轮）：

| 注册函数数 | 每次调用 |
| --- | --- |
| 4 | 11.7 / 11.9 µs |
| 204 | **103 / 197 µs** |

差值 ÷ 200 = **456–925 ns / 每个注册函数 / 每次调用**。也就是说，一个注册了 200 个函数的项目，
每次 JIT 调用白付 90–190 µs，而基准短调用本身只有 3.0 µs —— 这是目前 f_jit 里最大的一处浪费，
比编译路径所有已优化项加起来都大。

## What Changes

1. **`UserHelperTable.buildTable(base, entries)`**：把「建表」抽成独立函数。
2. **`UserHelperTable.pushTable(table)`**：调用期只把**已建好的表引用**压栈，零构建。
   `push(base, entries)` 保留为 `pushTable(buildTable(...))`（测试与一次性场景用）。
3. **`JitFunction` 缓存一张表**：`bindUserHelpers` 时构建一次并缓存；`callLocked` 用
   `helperTableRef()`（包装闭包实例取 `owner` 的表）。

**语义不变**：hid 计算（`USER_BASE + base + i`）、栈顶优先查找、push/pop 配对、
嵌套调用（JIT → 宿主闭包 → JIT）的可见性全部不变；只是把「每次重建」改成「建一次、压引用」。

## Impact

- 收益目标：helper 调用 **O(F) → O(1)**；F=200 时每次调用 **−90~190 µs**；
- 影响文件：`src/runtime/UserHelper.cj`、`src/JitFunction.cj`（+ 护栏 `src/HelperTableScope_test.cj`）；
- 风险：表被多个线程共享读取（HashMap 只读并发安全）；缓存在 `bindUserHelpers` 内构建，
  发布前完成；包装闭包实例沿用 `owner` 的表，不另建。
