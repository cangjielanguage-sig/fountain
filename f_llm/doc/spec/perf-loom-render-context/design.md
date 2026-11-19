# Design

## Decisions

### D1. 快照在锁内、替换在锁外

```cangjie
let box = ValuesBox()
synchronized(mutex){ 拷贝 values 到 box.value }
let snapshot = box.value
// 锁外单遍扫描
```

**替代**：细粒度读写锁。否决——`std.sync` 只有 `Mutex`；拷贝一张小表的成本远低于在锁内做字符串替换。

### D2. 单遍扫描的「非占位符」处理

遇到 `{` 后找到配对 `}`，若 token 不匹配 `start.output` / `<name>.output`（或名字里含 `{`/`}`/`"`），
只输出这个 `{` 并继续扫描，**不跳过整段**——否则 `{"k":"{a.output}"}` 这种「外层 JSON + 内层模板」会被外层
花括号吞掉。这是重构中最容易错的地方，已单独写用例钉住。

### D3. 命中但值为空 → 替换成空串

与原 `String.replace` 行为一致（`replace` 不管值是否为空都会换）。只有「没命中」才保留占位符。

### D4. 快照上限用「保留最近」而不是「丢弃新的」

长流程的结尾几步通常信息量最大（最终结果、失败原因）；丢最旧的比丢最新的更符合提炼需要。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 单遍扫描改动引入边界 bug | 4 条用例覆盖：多步、未知、空数据、JSON 嵌套；另跑既有 `testPayloadReachesStartTemplate` 等回归 |
| 200 轮上限让超长流程的极早步骤丢失 | 提炼本来只取代表性上下文；`maxTurns` 策略仍可控制更早截断 |

## 迁移

无（快照只用于提炼，不落库）。
