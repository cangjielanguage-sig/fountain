# frpcdemo：`fountain::f_rpc` 使用示例

用三个包演示 RPC 的完整链路：**服务接口与数据模型**（`rpcdef`）、**服务端**（`rpcserver`）、**调用方**（`rpcclient`）。
服务端每处理一次 `echo` 都会把收到的 JSON 打印出来，客户端连续调用 100 次 —— 因此各服务节点分别被服务了多少次，
可以直接数服务端输出里以 `{` 开头的行（每个请求一行），多节点负载均衡（轮询 + 权重）就是这么验的。

## 目录

| 路径 | 说明 |
| --- | --- |
| `rpcdef/src/EchoRPC.cj` | `@RPCStub` 接口：`func echo(po: EchoPO): EchoPO`（宏展开生成 `EchoRPC_Stub__`） |
| `rpcdef/src/model/EchoPO.cj` | `@DataAssist` 数据模型；含嵌套类型 `InnerPO`，用于验证嵌套对象的编解码 |
| `rpcserver/src/rpc/impl/EchoPOImpl.cj` | `@RPCSkeleton` 服务实现（打印收到的 JSON 后原样返回） |
| `rpcclient/src/client.cj` | `Initializer.start()` 里调用 100 次 `echo`，最后打印成功次数与最后一次响应的 JSON |
| `boot.sh` | 起进程/构建的入口（下面所有命令都用它） |
| `log/` | 运行时的文件日志（`frpcdemoserver-<主机:端口>.log`、`frpcdemoclient.log`） |

## 0. 构建

```bash
cd frpcdemo
./boot.sh build          # 编译本工程及其依赖（首次或改了 fountain 库代码后必须执行，耗时较长）
```

`./boot.sh build` 会把依赖（`f_app`、`f_rpc`、`f_data`…）一起编译到 `target/` 下，并把各模块的动态库目录写进
`LD_LIBRARY_PATH`；`./boot.sh runServer|runClient` 再用 `--dylibPattern` 挑出要加载的那个包的动态库。

## 1. 启动服务端

```bash
./boot.sh runServer <主机:端口> [种子节点|-] [权重]
```

- 权重缺省 `1.0`；种子节点写 `-`（或省略）表示没有种子。
- 例：

```bash
# 种子节点（同时对外提供服务）：监听 127.0.0.1:1203，权重 2.0
./boot.sh runServer 127.0.0.1:1203 - 2.0

# 纯服务节点：监听 127.0.0.1:1204，向 127.0.0.1:1203 注册自己，权重 1.0
./boot.sh runServer 127.0.0.1:1204 127.0.0.1:1203 1.0

# 两个彼此独立、权重都为 1.0 的服务节点（客户端同时连两个）
./boot.sh runServer 127.0.0.1:1203
./boot.sh runServer 127.0.0.1:1204
```

进程启动后会打印自己实际生效的配置，便于核对：

```
rpcServer_port=1204 rpcServer_baseAddresses=127.0.0.1:1203,127.0.0.1:1204 rpcServer_weight=1.0
```

两点必须知道：

1. **`rpcServer_port` 只接受端口号（`UInt16`）**。`boot.sh` 会自动从「主机:端口」里拆出端口；
   如果直接把 `127.0.0.1:1204` 交给它，解析失败会**静默回落到默认端口 1203**，两个服务节点就会撞端口。
2. **注册目标里包含自己**（`baseAddresses` = 显式种子 + 自身）。权重是通过注册表传播的：客户端从
   `SUBSCRIBE(data:true)` 返回的 `host,weight` 里读权重，注册表里查不到的节点只能退回客户端配置的权重（1.0）
   —— 所以服务节点要能把自己报进注册表，它自己的权重才会生效。

每次收到 `echo` 请求，服务端会打印：

```
===========================
{"a":100,"b":"hello world","c":false,"d":2.71828,"inner":{"tag":"inner-default","count":7}}
===========================
```

退出：`Ctrl-C`。

## 2. 启动客户端

```bash
./boot.sh runClient <主机:端口>[,<主机:端口>...]
```

- 多个服务节点用**逗号**分隔；`boot.sh` 会转成 `rpcClient_serverAddress` 要求的
  `权重,地址|权重,地址` 形式（每个地址权重 1.0），并固定 `rpcClient_loadbalance=roundrobin`（轮询）。
- 例：

```bash
./boot.sh runClient 127.0.0.1:1203                        # 只连一个节点
./boot.sh runClient 127.0.0.1:1203,127.0.0.1:1204         # 同时连两个节点
```

启动后会打印配置，然后连续调用 `echo` **100 次**（单次失败只记日志、继续下一次），最后打印：

```
rpcClient_serverAddress=1.0,127.0.0.1:1203|1.0,127.0.0.1:1204 rpcClient_loadbalance=roundrobin
***************************
echo 调用完成：成功 100/100
{"a":100,"b":"hello world","c":false,"d":2.71828,"inner":{"tag":"inner-default","count":7}}
***************************
```

注意：先起服务端再起客户端。服务发现是异步的，客户端的首个调用可能要等一轮（上限见
`rpcClient_discoveryTimeout`，默认 5s），期间没有可用服务节点就报 `no available client ...` 并结束。

退出：`Ctrl-C`。

## 3. 完整验证过程（负载均衡）

三个终端，依次执行（下表为 2026-10-04 实测结果，每场景 100 次调用）：

| 场景 | 终端 1 | 终端 2 | 终端 3（客户端） | 实测 1203 : 1204 |
| --- | --- | --- | --- | --- |
| 1. 等权轮询 | `./boot.sh runServer 127.0.0.1:1203` | `./boot.sh runServer 127.0.0.1:1204` | `./boot.sh runClient 127.0.0.1:1203,127.0.0.1:1204` | **50 : 50** |
| 2. 权重 2:1 | `./boot.sh runServer 127.0.0.1:1203 - 2.0` | `./boot.sh runServer 127.0.0.1:1204 - 1.0` | 同上 | **67 : 33** |
| 3. 种子 + 纯服务节点 | `./boot.sh runServer 127.0.0.1:1203 - 2.0` | `./boot.sh runServer 127.0.0.1:1204 127.0.0.1:1203 1.0` | `./boot.sh runClient 127.0.0.1:1203` | **67 : 33** |

- 场景 2：改权重后要**重启服务端**（权重是启动时读取的），客户端可以重跑。
- 场景 3 的链路：客户端只认识种子节点 ⇒ 从种子 `SUBSCRIBE(data:true)` 拿到全部服务节点 ⇒ 逐个订阅后建立调用池
  ⇒ 权重取自注册表 ⇒ 客户端代码与配置都不用改，两个节点按 2:1 分担。
- 计数方法：把每个服务端的输出重定向到文件后

```bash
grep -c '^{' server-1203.out      # 该节点实际服务了多少次
```

（客户端自己也会打印响应 JSON，别把客户端输出和服务端输出混在一起数。）

## 4. 配置项速查

服务端与客户端相关的主要配置（都能用环境变量设置，完整列表见 `../f_rpc/README.md`）：

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `rpcServer_port` | `1203` | 服务监听端口（`UInt16`，只填端口号） |
| `rpcServer_baseAddresses` | 空 | 种子节点地址列表（逗号分隔），启动后向它们注册自身 |
| `rpcServer_weight` | `1.0` | 服务权重，注册到注册表，客户端据此分配调用 |
| `rpcClient_serverAddress` | 无 | 要连接的服务节点，格式 `权重,地址`，多个用 `\|` 分隔（不配则打印 ERROR 并退出） |
| `rpcClient_loadbalance` | `random` | 负载均衡策略：`random` / `roundrobin`（本 demo 用轮询） |
| `rpcClient_retryCount` | `0` | 单次调用失败后的重试次数 |

## 5. 观察与排查

- **日志**：控制台是 DEBUG 级（格式见 `boot.sh` 顶部的 `logger_appender_*`），文件日志在 `./log/` 下、INFO 级。
- **调用池组成**：每条服务在服务发现时会打印
  `[FOUNTAIN_RPC.hosts] fountain::rpcdef.EchoRPC.echo v=* -> 2 host(s): 127.0.0.1:1203(1.000000) 127.0.0.1:1204(1.000000)`
  —— "池子里到底有谁、权重是多少"看这一行最直接。
- **注册**：服务端启动时打印 `[FOUNTAIN_RPC.register] base addresses ...` / `host registered ...`，
  注册表侧打印 `[FOUNTAIN_RPC.Skeleton.REGISTER] "127.0.0.1:1204,1.000000"`。
- **常见现象**：
  - `no available client for ... after 5s`：服务端没起、或客户端配置的地址不对、或服务名/版本对不上；
  - 调用全部落在同一个节点：确认注册表里两个节点都报了权重（见上面的 `hosts` 日志）；
  - 服务端报 `Connection reset by peer`：多半是客户端进程异常退出导致的断链，去看客户端那边的异常。

负载均衡（轮询/权重）曾经完全不生效（永远命中第一个节点），根因与修复记录在
`../.autocode/bugs/bug.md` 第 2 部分。
