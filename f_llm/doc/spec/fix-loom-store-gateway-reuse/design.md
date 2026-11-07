# Design

## Context

- `LoomWiring.cj:72-74`：`installStore({ => LoomStoreGateway().call(...) })`，每次调用新建。
- `LoomStoreGateway.cj:58-63`：无参构造 `Stores.content()` / `Stores.meta()` / `EvolutionStores.current()`，三者各自 `StoreSettings.load()`。
- `StoreFunctions.cj:74-79`、`:130-135`：工具未注入网关时也 `LoomStoreGateway()`。
- `LoomStoreGateway(content, meta, evolution!)` 已有可注入构造，装配期完全可以建一次。

## Goals / Non-Goals

**Goals**：把「每步固定开销」压成「每次装配一次」；让工具与网关同源。

**Non-Goals**：缓存 `Stores.content()` 本身（属 store 包，另议）；并发下的懒加载优化；网关内部再加缓存。

## Decisions

### D1. 首次使用时建一次（懒建），闭包捕获持有者

```cangjie
class LoomGatewayHolder {
    private var value: ?LoomStoreGateway = None
    func get(injected: ?LoomStoreGateway): LoomStoreGateway { /* 注入优先，其次缓存，最后新建并缓存 */ }
}
```

`wire` 新增 `gateway!: ?LoomStoreGateway = None`：测试可传自定义网关，业务可传自己的实现。

**为什么不在装配期直接建**：`LoomStoreGateway()` 会立刻 `Stores.content()`，在「只装配、还没连库」的场景（含所有单测）会让 `wire` 直接抛错。
懒建一次既避免了每次调用开库，也保住了「启动阶段不连存储」的既有约束。

**替代**：在 `LoomHostApi` 里做 lazy 单例。否决——`LoomHostApi` 是静态装配点，装配语义应留在 `LoomWiring`，否则测试无法隔离。

### D2. 工具走 `LoomHostApi.callStore`，不再自建

```cangjie
let result = match(injected) {
    case Some(g) => g.call(kind, op, payload)
    case None => try {
        LoomHostApi.callStore(kind, op, payload)
    } catch (e: LoomException) {
        // 未装配（单测/裸用）：保持原有自建行为
        LoomStoreGateway().call(kind, op, payload)
    }
}
```

**替代**：工具直接要求必须先装配。否决——会破坏既有「工具可单独 new 出来测」的用例。

### D3. 构造计数用**包内静态变量**，不加 public API

`LoomStoreGateway` 增加：

```cangjie
static var buildCount: Int64 = 0
static func resetBuildCount(): Unit { buildCount = 0 }
```

默认可见性即包内，测试同包可读；不对外暴露，避免被误当业务指标。

**替代**：加 public 计数器。否决——公开 API 一旦发布就得一直维护。

### D4. `SkillEvolutionJob.load` 的装配路径同样复用

`LoomWiring` 里 `SkillEvolutionJob.load(LoomStoreGateway(), …)` 改为传同一个 `gateway`。手动注册示例（`doc/loom.md`）仍保留 `LoomStoreGateway()` 写法，因为那是宿主自己的代码，不在装配路径上。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 装配期建网关若失败（库不可用），整个 wire 抛错 | 与现状一致（现在第一次 store 调用才会抛）；`store` 相关的容错由 `LoomBootstrap.startup` 的 `restoreFailed` 标记负责 |
| 计数是静态变量，并发测试互相干扰 | 只在断言前重置；计数只增不减，不参与业务逻辑 |
| 工具走 `callStore` 后，异常信息来自装配函数而非网关 | 文案统一为 `memoryCall failed: …`，与原行为一致 |

## Migration Plan

无需迁移；`wire` 新增的是可选参数。
