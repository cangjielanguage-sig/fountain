# RPC 接口

`fprobe agent` 通过 `f_rpc` 暴露一个服务：`fountain::fprobe.rpc.ProbeRPC`。一个 tick 内
supervisor 对该服务调用一次 `collect()`，拿回该节点的全部监控项，避免为每个指标建立
一次连接。

## 方法与类型

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `collect` | 无 | `ProbeSnapshot` |
| `kinds` | 无 | `ProbeKinds` |

```cj
@RPCStub
public interface ProbeRPC {
    func collect(): ProbeSnapshot
    func kinds(): ProbeKinds
}
```

`typeName` 是 `fountain::fprobe.rpc.ProbeRPC`。服务端实现 `ProbeRPCImpl` 由
`@RPCSkeleton` 自动注册到 `ServiceHub` 与 IOC 容器；`collect()` 只读
`SnapshotStore`，不会触发一次新的采集。

## 线协议

请求是一帧 `RPCMessage`，`f_rpc` 用 `ServiceMeta` 定位方法：

```
ServiceMeta(
  version: "*",
  name: "",
  typeName: "fountain::fprobe.rpc.ProbeRPC",
  methodName: "collect",
  argTypeNames: [],
  weight: 1.0,
  exactlyVersion: true)
```

`Message.consume<RPCMessage>(once: true, qos: QoS.AtMostOnce, data: RPCMessage(meta, []))`
发出；响应命令为 `RESP`，负载同样是 `RPCMessage`，其 `data` 可 `convert<ProbeSnapshot>()`。
`ERROR` 命令表示服务端异常，`None` 表示超时。

## 最小客户端

```cj
import fountain::f_net.*
import fountain::f_protocol.*
import fountain::f_rpc.base.*
import fountain::f_rpc.client.*

let client = Client<RPCMessage>.builder(
    address: "10.0.0.11:12323",
    checkDuration: Duration.second * 30).build()
let meta = ServiceMeta("*", "", "fountain::fprobe.rpc.ProbeRPC", "collect", [], 0.0,
    exactlyVersion: true)
let request = Message.consume<RPCMessage>(once: true, qos: QoS.AtMostOnce,
    data: RPCMessage(meta, []))
match (client.transfer(request, Duration.second * 3)) {
    case Some(response) =>
        match (convert<ProbeSnapshot>(response.data)) {
            case Some(snapshot) => println(snapshot.node)
            case None => eprintln("响应不是 ProbeSnapshot")
        }
    case None => eprintln("调用超时")
}
```

`fprobe` 内部的 `NodeRpcTransport` 就是这段逻辑的封装，额外做了失败重连、超时映射
与错误信息补全。

## 编解码约束

`ProbeSnapshot`、`ProbeAgentData`、`ProbeKinds` 都必须是 `DataFields`；`dataJson`
是字符串，因此监控项内部结构变化不需要改 RPC 契约，也不影响其它监控项。
