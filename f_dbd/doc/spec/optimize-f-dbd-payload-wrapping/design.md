# 设计：sqlPayload 单层包装

## Context

`sqlPayload()` 在 `parameters: HashMap<Int64, Data>` 之上补齐空洞，然后逐项写入 `SqlPayload.params: ArrayList<DataAny>`。当前写法：

```cangjie
case Some(data) => payload.add<DataAny>(DataAny(data))
```

`DataAny` 是 struct，`add<T>` 是泛型方法。传入结构体会在泛型实例化处装箱，`add` 内部再 `param.toData()` 拆回 `Data`、重新 `DataAny(...)`。最终 `params` 中仍是 `DataAny(data)`，装拆完全冗余。

实测（8 参数，2000 次，5 次采样）：2,321 B/次 → 1,744 B/次（`add<Data>`），省 577 B（25%）。

## Goals / Non-Goals

**Goals：**
- 去掉逐参数的冗余装箱，载荷字节不变。
- 用测试锁住两种写法的编码结果一致。

**Non-Goals：**
- 不改 `SqlPayload.add<T>` 的签名，不新增公开方法。
- 不启用 local mode（`DataAny` 是值类型，不涉及本地区域）。
- 不改 `parameters` 的 `HashMap<Int64, Data>` 结构。

## Decisions

### D1 调用处改为 `add<Data>`

```cangjie
case Some(data) => payload.add<Data>(data)
```

`Data` 是接口（引用类型），泛型实例化不装箱；其默认 `toData()` 返回 `this`，`add` 只做一次 `DataAny(data)`。与旧写法的最终值完全相同。

**替代方案（否决）**：
- *新增 `SqlPayload.addData(data: Data)` 公开方法*：能省一次接口派发，但扩大公开 API，收益只有几纳秒。
- *`@ local!`*：`DataAny` 是 struct，不在堆上，没有可本地化的对象；探针也证实差异来自泛型装箱而非分配区域。

### D2 等价测试

`f_dbd/src/common/PayloadWrapping_test.cj`：

- 同一组 8 个参数（含 `addNull` 空洞）分别用旧写法与新写法构造；
- 用 `DefaultCodec.encode<SqlPayload>` 编码，比较字节数组逐字节相等；
- 解码回 `SqlPayload` 后再编码一次，结果仍相等（往返稳定）。

### D3 分配基准

`F_DBD_BENCH=1` 时对 8 参数 payload 重复 2000 次，比较旧写法（测试内同结构复刻）与新写法，**只打印不设硬断言**。

原因：整段 UPDATE/payload 的分配窗口会触发 GC，`getAllocatedHeapSize + getGCFreedSize` 的净额在同一实现上可差数倍（实测 1,696 / 595 / 1,697 B/次）。稳定对照来自隔离探针（只建 payload、值预先构造）：2,321 → 1,744 B/次。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| `add<Data>` 与 `add<DataAny>` 的 `toData()` 语义不同 | `Data.toData()` 默认返回自身；等价测试比较编码字节 |
| 空洞参数行为变化 | `addNull()` 路径未改，测试包含空洞 |
| 基准噪声 | 只记录不断言；稳定差值由隔离探针给出 |

## Migration Plan

- 单行改动，无迁移。回退：`git revert`。

## Open Questions

无。
