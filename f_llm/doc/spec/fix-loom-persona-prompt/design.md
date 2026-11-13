# Design

## Context

- `LoomRunner.cj:157-158`：`let userId = LoomMemoryPolicy.effective().userId` → `characterOf(userId)`；policy 默认 `userId=0`，`characterOf` 对 `<=0` 直接 `None`。
- `LoomRunner.cj:198-203`：`if (selected.isEmpty() && policy.autoSkills)` —— 只看入参，不看解析结果。
- `LoomStoreGateway.cj:275-306`：`get` 直接透传 `version`；`remove` 同理。
- `LoomHostApi.cj:138`：`LoomContextLog.record(LlmTurn(model, fullSystem, input, output))`。

## Decisions

### D1. 新增 `LoomCharacterScope`，而不是给 policy 加字段

```cangjie
public class LoomCharacterScope {
    public static func install(userId: Int64): Unit
    public static func current(): ?Int64
    public static func reset(): Unit
}
```

`LoomRunner`：`let userId = match(LoomCharacterScope.current()){ case Some(v) => v; case None => policy.userId }`。

**替代**：给 `LoomMemoryPolicy` 加 `characterUserId`。否决——人格是提示词诉求，塞进记忆策略正是这轮要拆掉的耦合。

### D2. 技能回落判据改成「解析结果为空」

先按显式标题 `resolveSkills`，空了再走 `SkillCatalog` 补一轮，再 `resolveSkills`。

**替代**：改写 `resolveSkills` 内部逻辑。否决——它同时被两处调用，改签名会扩散。

### D3. `prompt.remove` 缺版本时抛错

`version<=0` → `throw LoomException('prompt.remove requires version')`。`get` 则走 `latest`，与 `persona` 的读取路径一致。

### D4. `LlmTurn` 记步骤 system

`callLlm(model, system, input)` 里的 `system` 是步骤自己的；`fullSystem` 只是执行期拼出来的注入串。记录前者，`digestOf` 自然不再把人格/技能写进记忆。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 已有流程依赖「记忆里带人格」 | 不是设计意图；如确需，可在步骤 system 里显式写 |
| `LoomCharacterScope` 是静态态，与 `LoomServices` 同类 | 文档写明进程级；测试用 `reset()` 隔离 |

## Migration Plan

无需迁移。
