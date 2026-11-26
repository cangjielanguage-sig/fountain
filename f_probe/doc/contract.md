# `f_probe` 扩展契约

`f_probe` 只依赖 `f_base` 与 `f_data`，为 fprobe 的第三方扩展定义稳定契约。扩展作者
不需要（也不应该）依赖 `fprobe` 可执行模块、RPC、邮件或 TUI 库。

## 1. `ProbeAgent`

```cangjie
public interface ProbeAgent {
    prop kind: String
    prop host: String {
        get() {
            ""
        }
    }
    prop data: JsonObject
}
```

| 成员 | 语义 |
| --- | --- |
| `kind` | 监控项类型，例如 `cpu`、`memory`、`k8s`。**全局唯一且稳定**，同时作为快照数据键、配置键和图表/告警规则中的引用键。发布后不要改名。 |
| `host` | 受监控主机。默认返回空字符串；为空时宿主用 `probe_host` 或本机主机名补齐。 |
| `data` | 监控数据，**必须是 JSON object**。建议用 `@DataAssist` DTO 的 `JsonValue.from(dto).asObject()` 生成，不要手写 JSON 字符串。 |

采集约定：

- `data` 返回非 object 时，收集器把该监控项标记为采集失败，不把非法数据放进快照，且不影响其它监控项。
- `data` 抛出 `ProbeException` 时，异常消息写入该监控项的 `error` 字段，其余监控项照常采集。
- 差分型指标（CPU、磁盘 I/O、网络）由探针自己保存上一次原始计数，宿主只按周期调用 `data`。

最小实现（只覆写 `kind` / `data`，`host` 使用默认值）：

```cangjie
class K8sProbeAgent <: ProbeAgent {
    public prop kind: String {
        get() {
            "k8s"
        }
    }

    public prop data: JsonObject {
        get() {
            let data = JsonObject()
            data.add("nodes", 3)
            data.add("pods", 42)
            data
        }
    }
}
```

## 2. `AlarmMessageChannel`

```cangjie
public interface AlarmMessageChannel {
    func send(message: String, receiver: Array<String>): Unit
    func receive(): String
    func replyConf(): String
    func sendRich(message: String, html: String, attachments: Array<String>,
        receiver: Array<String>): Unit {
        send(message, receiver)
    }
}
```

| 方法 | 语义 |
| --- | --- |
| `send(message, receiver)` | 发送纯文本告警给若干收件人。 |
| `receive()` | 返回**一条**待处理消息的 JSON 文本；没有消息返回空字符串。 |
| `replyConf()` | 返回保存「可指挥智能体账号列表」的**配置项名称**，不是配置值。 |
| `sendRich(message, html, attachments, receiver)` | 发送 HTML 正文与附件。默认实现忽略 HTML 与附件，退化为 `send(message, receiver)`。 |

`receive()` 返回的 JSON object 格式固定：

```json
{"id":"msg-001","from":"ops@example.com","subject":"disk","body":"同意重启服务"}
```

不符合该格式时，智能体忽略消息并记录 WARN。`attachments` 是文件路径数组；只支持纯文本
的渠道可以忽略它，报告任务不会因此失败。

## 3. 注册表

### 3.1 `ProbeRegistry`

```cangjie
ProbeRegistry.registerAgent(kind: String, factory: () -> ProbeAgent): Unit
ProbeRegistry.agents(): Array<String>
ProbeRegistry.agent(kind: String): ?(() -> ProbeAgent)
ProbeRegistry.clear(): Unit   // 仅供测试
```

- 保存**工厂**而不是实例：注册通常发生在动态库加载期，运行期配置可能尚未校验。
- 线程安全（一把 `Mutex` 保护 `HashMap`），`agents()` 返回快照数组。
- 重名注册抛 `ProbeException(DUPLICATE)`，注册表保留第一次登记的工厂。
- 内置探针先注册、扩展后加载，因此扩展不能覆盖 `cpu` 等内置 `kind`。

### 3.2 `AlarmChannelRegistry`

```cangjie
AlarmChannelRegistry.registerChannel(name: String, factory: () -> AlarmMessageChannel): Unit
AlarmChannelRegistry.channels(): Array<String>
AlarmChannelRegistry.channel(name: String): ?(() -> AlarmMessageChannel)
AlarmChannelRegistry.clear(): Unit   // 仅供测试
```

与 `ProbeRegistry` 同构，键为渠道名（例如 `email`、`webhook`）；重名抛
`ProbeException(DUPLICATE)`，不覆盖已登记工厂。

## 4. 异常与错误码

```cangjie
public enum ProbeErrorCode <: Equatable<ProbeErrorCode> {
    | DUPLICATE
    | CONFIG
    | LOAD
    | COLLECT
}

public class ProbeException <: BaseException {
    public let code: ProbeErrorCode
    public init(code: ProbeErrorCode, message: String)
    public init(code: ProbeErrorCode, message: String, caused: Exception)
}
```

| 错误码 | 场景 | 消息必须包含 |
| --- | --- | --- |
| `DUPLICATE` | 注册重名 | `kind` 或渠道名 |
| `CONFIG` | 配置缺失或非法 | 配置键名 |
| `LOAD` | 动态库加载/初始化失败 | 库路径或扩展名 |
| `COLLECT` | 采集失败 | 监控项 `kind` |

调用方按 `code` 判别失败类别，不要解析异常文本。

## 5. 扩展自注册

扩展在动态库加载时自行调用注册表，宿主无需手工登记：

```cangjie
public class K8sProbeExtension {
    static init() {
        ProbeRegistry.registerAgent("k8s", {=> K8sProbeAgent()})
    }
}
```

`fprobe` 的 `CustomLoader` 用 `PackageInfo.load` 加载 `custom/` 下的动态库，包的
`static init` 随之执行，注册即完成。扩展失败时由宿主按 `probe_customFailFast` 决定
终止启动或降级继续。

契约模块的依赖必须保持收敛：`f_probe` 只依赖 `f_base` 与 `f_data`，不得引入
`f_rpc`、`f_email`、`f_llm` 或 TUI 依赖。实现示例见 `src/ExtensionExample_test.cj`。
