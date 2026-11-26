# 编写 fprobe 扩展

扩展以动态库形式放到 fprobe 的 `custom/` 目录，由宿主在启动时加载。扩展只依赖
`fountain::f_probe`，不要依赖 `fprobe` 可执行模块或宿主内部包。

## 1. 建立扩展工程

```toml
# cjpm.toml
[package]
name = "probe_ext_k8s"
version = "0.1.0"
output-type = "dynamic"
src-dir = "src"
organization = "example"

[dependencies]
  "fountain::f_probe" = {path = "../../fountain/f_probe"}
```

中心仓场景把 path 依赖换成：

```toml
[dependencies]
  "fountain::f_probe" = "1.3.17"
```

## 2. 实现监控项

```cangjie
package example::probe_ext_k8s

import fountain::f_data.JsonObject
import fountain::f_probe.{ProbeAgent, ProbeRegistry}

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

`kind` 必须唯一且稳定；`data` 必须是 JSON object。采集失败时抛
`ProbeException(ProbeErrorCode.COLLECT, "...")`，宿主会把消息写入该监控项的 `error`。

## 3. 实现告警渠道（可选）

```cangjie
import fountain::f_probe.{AlarmMessageChannel, AlarmChannelRegistry}

class WebhookAlarmChannel <: AlarmMessageChannel {
    public func send(message: String, receiver: Array<String>): Unit {
        // 调用 webhook；失败时抛 ProbeException
    }

    public func receive(): String {
        ""
    }

    public func replyConf(): String {
        "probe_channel_webhook_replyAccount"
    }
}
```

只实现三个基础方法即可；`sendRich` 默认退化为纯文本发送，报告附件会被忽略。

## 4. 加载时自注册

```cangjie
public class ProbeExtK8s {
    static init() {
        ProbeRegistry.registerAgent("k8s", {=> K8sProbeAgent()})
        AlarmChannelRegistry.registerChannel("webhook", {=> WebhookAlarmChannel()})
    }
}
```

`static init` 在动态库被 `PackageInfo.load` 加载时执行，注册完成后宿主即可枚举到
`k8s` / `webhook`。重名注册抛 `ProbeException(DUPLICATE)`；内置实现先注册，扩展不能
覆盖内置 `kind`。

## 5. 构建与部署

```bash
cd probe_ext_k8s
cjpm build
# 产物在 target/release/ 下，文件名形如 libprobe_ext_k8s@example.so
mkdir -p /opt/fprobe/custom
cp target/release/libprobe_ext_k8s@example.so /opt/fprobe/custom/
```

重启 fprobe 后生效。目录不存在等价于没有扩展；非 `.so` / `.dll` / `.dylib` 文件被忽略。
`probe_customFailFast=true`（默认）时任一扩展加载失败会终止启动，设为 `false` 则记录
ERROR 后继续，内置实现保持优先。

## 6. 测试建议

- 契约本身可在扩展工程内直接构造实例并断言 `kind`、`host`、`data`，不需要真实宿主。
- 不要在单元测试里加载真实 `.so`：测试注册表的重名、枚举与查找即可；动态库加载由
  fprobe 的集成测试覆盖。
- 本仓库的 `f_probe/src/ExtensionExample_test.cj` 就是文档示例的可编译校验，可对照修改。
