# Design

## Context

动机见 `proposal.md`「Why」。实现前需要对齐的既有事实（均已核对源码）：

- `LoomService`（`src/loom/LoomService.cj`）持有 `Planner` + `LoomRegistry` + `LoomCompiler`，`execute` / `confirmFlow` 里都会 `registry.put(flow)`，`delete` 调 `registry.remove`，`executeNow(name, host, input, parallel)` 要求 `status=COMPILED` 并抛 `LoomException`。
- `LoomRegistry`（`LoomRegistry.cj`）内存 `HashMap` + `Mutex`，`put/remove` 双写 store，`restore()` 分页 100 条拉回，`compiledFlows()` 返回可执行集合。
- `LoomWiring.wire`（`LoomWiring.cj`）顺序为：选 store → `LoomRegistry(store:)` → `LoomBootstrap.startup(registry)` → `LoomService` → `LoomServices.install(service)` → 装 store 网关 → `LoomServices.installHost(DefaultLoomHost(chat))` → 记忆策略 / 技能目录 / 演进族 bootstrap / 演进定时任务。
- `Planner.stripFence(raw)` 是 `internal`，与 Supervisor 同包，可直接复用去围栏；`Planner.parse` 面向流程计划，语义不同，不复用。
- 配置读取统一 `Config.getValue<Bool>(KEY) ?? false`，键常量集中在 `config/LLMConfig.cj`（`LLM = 'llm'` 前缀拼接）。
- 事件模型：步骤以 `StartEvent(category:, tag:, name:, data:)` 进入执行，`{start.output}` 即 `data`；`LoomRunner` 内部 tag 用 `loom/{name}#{seq}`。

## Goals / Non-Goals

**Goals:**

- 一段描述 → 一次模型调用 → 落到某条已编译流程并执行，全过程可观测（返回流程名 / 事件名 / 产出）。
- 关闭时零开销、零行为变化；开启时流程自动登记与摘除，重启后从 Store 自动重建路由。
- 无可用流程的两种处置由配置决定，且默认选择「立即返回」。

**Non-Goals:**

- 不做多流程串联编排（一次派发只落一条流程）。
- 不做路由表持久化（从流程存储重建，避免双份真相）。
- 不把 Supervisor 暴露成模型可调用的工具（本期无需求，见 Open Questions）。
- 不改 `loom-flow` 既有需求与 `LoomRequest` / `LoomResult` 公开签名。

## Decisions

### D1. 独立类 `Supervisor`，进程内单例

新增 `src/loom/Supervisor.cj`，提供 `install / current / reset`，与 `LoomServices`、`LoomSchedules` 同一套安装-取用模式。

**替代方案**：把路由表塞进 `LoomService`。否决——`LoomService` 已承担「规划 → 生成 → 编译 → 执行」，再加「选路」会让它同时依赖模型判定与事件命名，且既有两个入口的测试都要跟着改。

### D2. 每个流程一个 Supervisor 事件：`sv/<flowName>`

`Supervisor.eventName(name)` 生成 `'sv/' + name`，派发时构造：

```cangjie
StartEvent(category: 'supervisor', tag: flowName, name: eventName, data: prompt)
```

**替代方案**：复用 `loom/{name}` 作为事件名。否决——`LoomRunner` 已用 `loom/{name}#{seq}` 作流程 tag，事件名再撞同一形态会让日志无法区分「外部派发」与「内部步骤」。

事件名不落库：由流程名派生，天然唯一且与重命名同步。

### D3. 路由表登记全部流程，选路只看 `compiled`

`register` 接受任意状态流程，路由条目带 `status`；拼选路提示词时只把 `status=compiled` 的流程列给模型，`dispatch` 命中后再校验一次状态。

理由：需求是「每个流程都注册」；但让模型选到一条不能执行的流程只会把失败后移到执行阶段。

### D4. 选路：单轮提示词 + 严格 JSON，容错即「无可用」

提示词结构（system 为空，user 携带）：

```
你是流程调度员。判断下面的需求应由哪个流程完成。
可用流程：
- 名称：daily
  描述：每天汇总昨日提交与 issue
  事件：sv/daily
需求：<用户描述>
只输出 JSON：{"flow":"<名称>"}；没有合适的流程输出 {"flow":""}
```

解析：`Planner.stripFence` → `JsonValue.fromStr(...).asObject()` → 取 `flow` 字段；非 JSON / 缺字段 / 空串 / 不在表内 / 非 compiled 一律按无可用流程处理（`warn` 日志，不抛错）。

**替代方案**：让模型在同一个响应里既选流程又给新流程描述。否决——两种策略（直接返回 / 自动新建）会耦合在一次回答里，模型答错时无法判断该走哪条分支；且新建流程要不要发生是配置项决定的确定性行为，不该由模型代决。

### D5. 无可用流程：配置决定，自动新建的名字由框架生成

- `llm_loomOnNoUsable=false` → 返回 `noUsableFlow`，消息固定为 `没有可完成此工作的流程`。
- `true` → 名字 `auto-<yyyyMMddHHmmss>`，若已存在则追加 `-2`、`-3`…；`service.execute(LoomRequest(name, description: prompt), confirm: false)` → `pending` 则 `confirmFlow(name)` → `register` → 派发；`clarifying` 则原样返回澄清状态与问题，不登记、不执行。

**替代方案**：把描述直接当流程名。否决——中文描述作主键会带空格、超长、与既有命名风格不一致，且日志与 URL 里都难用。

### D6. 生命周期联动用静态钩子，而不是改构造签名

`LoomService.execute` / `confirmFlow` 在 `registry.put(flow)` 之后调 `Supervisor.tap(flow)`，`delete` 调 `Supervisor.untap(name)`；`tap/untap` 首行判断「是否已安装且开启」，否则立即返回。

理由：保持 `LoomService(planner, registry)` 构造签名不变（既有测试与 `LoomWiring` 都不用改），关闭态零成本。

**替代方案**：构造注入 `?Supervisor`。否决——公开构造签名变化会波及所有既有用例，收益只是少两个静态调用。

### D7. 装配点放在 `LoomWiring.wire`，host 复用同一份 chat

在 `LoomServices.installHost(DefaultLoomHost(chat))` 之后：

```cangjie
if(LLMConfig.supervisorEnabled()){
    let host = LoomServices.currentHost() ?? DefaultLoomHost(chat)
    Supervisor.install(service, host, registry)   // 内部按 registry 里全部流程播种
}
```

`registry` 已完成 `LoomBootstrap.startup`，因此「启动时从 Store 载入全部流程」由既有恢复流程顺带满足，不再单独扫库。

### D8. 配置项集中在 `LLMConfig`

```cangjie
public static const LLM_SUPERVISOR = 'llm_supervisor'
public static const LLM_LOOM_ON_NO_USABLE = 'llm_loomOnNoUsable'
public static func supervisorEnabled(): Bool      // Config.getValue<Bool> ?? false
public static func loomOnNoUsable(): Bool         // supervisorEnabled() && (...) ?? false
```

`loomOnNoUsable()` 内联开关判定，保证「只有 `llm_supervisor=true` 才生效」只在一处实现。

### D9. 并发与失败语义

- 路由表用 `Mutex` 保护（与 `LoomRegistry` 一致），登记/摘除/读取都在锁内；
- 选路阶段模型调用异常 → 记 `warn`、按无可用流程处理（选路失败不该让调用方拿到异常）；
- 派发阶段流程执行异常 → 原样抛出（执行失败是真实失败，吞掉会让调用方误判成功）。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 模型选错流程（描述近似） | 提示词要求「不明确就返回空」；单测覆盖非 JSON / 空名 / 不在表内三种容错；选错时调用方仍可从返回的流程名发现 |
| 路由表与流程状态漂移（登记了 pending） | 选路候选过滤 `compiled`，派发前二次校验 `status` |
| 自动新建造成流程膨胀 | `llm_loomOnNoUsable` 默认 false；新建名带时间戳便于审计；文档写明何时该开 |
| 关闭态仍有调用开销 | `tap/untap` 首行判开关；`dispatch` 在未安装时直接返回 `disabled`，不调模型 |
| 事件名与内部 tag 混淆 | 事件统一 `sv/` 前缀，与 `loom/` 前缀分开 |

## Migration Plan

默认 `llm_supervisor=false`，升级后行为与现在完全一致；开启需改环境变量并重启（配置只读是既有设计约束）。回退只需把开关设回 false 并重启，无数据迁移、无表结构变化。

## Open Questions

- 是否把派发能力暴露成模型可调用的工具（如 `supervisorDispatch`）：本期不做，等出现「流程内需要转派给另一条流程」的实际需求再补。
- 选路是否需要多候选（模型返回 top-2 供人工确认）：当前单值足够，若实际出现频繁误判再说。
