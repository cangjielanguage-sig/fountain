# Design

## Context

- `Supervisor.cj:154-190`：`dispatch` 的二次校验只 `return`，不摘除；`routable()`、`service.status()` 在 try 外。
- `LoomWiring.cj:86`：`LoomBootstrap.startup(registry)` 返回值被丢弃；`LoomBootstrap.ReloadResult` 有 `restoreFailed` 但 `toString()` 不含。
- `LoomWiring.cj:97`：无条件 `installHost(DefaultLoomHost(chat))`。

## Decisions

### D1. 漂移即摘除，不做「自动改状态」

```cangjie
if (service.status(chosen) != LoomStatus.COMPILED) {
    let _ = unregister(chosen)
    return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
}
```

**替代**：把路由状态改成流程库里的实际状态（`register(..., status: service.status(chosen))`），让它自然跌出 `routable()`。否决——摘除更直接，状态再变回 compiled 时 `LoomService.tap` 会重新登记，不会丢。

### D2. 选路段整体纳入异常保护

`routable()` 与 `status()` 都是「候选枚举」，异常等于「没有候选」。用一层 `try { ... } catch { return NO_USABLE }` 包住候选收集与二次校验。

### D3. `lastReload` 作为装配结果的可观测出口

```cangjie
private static var reload: ?ReloadResult = None
public static func lastReload(): ?ReloadResult   // wire 时写入
```

`restoreFailed` 为真时 `LoggerFactory.getLogger<LoomWiring>().warn(...)`。

**替代**：把 `ReloadResult` 塞进 `LoomService`。否决——服务实例是运行期对象，装配结果是启动期事实，混在一起会让测试更难隔离。

### D4. host 优先级显式化

```cangjie
public static func wire(..., host!: ?LoomHost = None)
let chosenHost = match(host){ case Some(h) => h
    case None => match(LoomServices.currentHost()){ case Some(h) => h; case None => DefaultLoomHost(chat) } }
LoomServices.installHost(chosenHost)
```

**替代**：改成「已存在则不覆盖」但不给参数。否决——调用方偶尔需要显式指定宿主（例如多租户），留参数成本很低。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 摘除后若流程状态恢复 compiled，需要重新 tap 才回到路由 | `LoomService.confirmFlow` 会 tap，正常路径已覆盖 |
| `lastReload` 是静态变量，多实例装配互相覆盖 | 与 `LoomServices`/`LoomSchedules` 一致，属进程级单例语义；文档写明 |
| 沿用已装 host 时，`chat` 参数对执行不生效 | 传入的 host 自带 LLM 能力；README 说明二者择一 |

## Migration Plan

无需迁移。
