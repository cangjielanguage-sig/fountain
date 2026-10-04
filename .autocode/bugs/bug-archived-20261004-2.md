# Bug 分析报告：客户端解码崩溃 与 客户端负载均衡（轮询/权重）（已归档）

> **归档说明（2026-10-04）**：本报告已归档到 `.autocode/bugs/bug-archived-20261004-2.md`，
> 两个问题均已关闭 —— 第 1 部分：空集合 / 空映射解码越界（`f_codec` 16/16，端到端 100 次调用无异常）；
> 第 2 部分：负载均衡不生效（`f_concurrent` 6 个新用例 + frpcdemo 三场景 50:50 / 67:33 / 67:33）。
> 后续新问题请新建 `.autocode/bugs/bug.md`（或 `bugs/bug-<日期>.md`）。

- 日期：2026-10-04
- 分支：`fix/empty-payload-decode`（worktree `.worktrees/fix-empty-payload-decode`，基于 `sts/1.3.x`）
- 修复提交：`6518cb48`（第 1 部分）、`21a9ab7b`（第 2 部分）
- 上一份归档报告：`.autocode/bugs/bug-archived-on-20261004.md`
  —— 其中仍开着的两项：**§7.12**（`f_pool` 偶发 SIGSEGV，根因未证）、**§7.3**（重复归还同一对象，已裁定暂不改）。

## 状态总览

| # | 问题 | 状态 | 说明 |
| --- | --- | --- | --- |
| 1 | 客户端 reader 解码响应时 `IndexOutOfBoundsException`（空集合 / 空映射） | ✅ 已修 | 编码/解码约定对齐 + 回归用例；`f_codec` **16/16**；见第 1 部分 |
| 2 | RPC 客户端负载均衡**完全不起作用**（轮询/权重/随机都只命中第一个节点） | ✅ 已修 | 3 个缺陷（迭代器忽略选择 / 浮点权重区间放大 / 轮询原点与取值起点绑死）；`f_concurrent` 6 个新用例 + frpcdemo 三场景实测 50:50、67:33、67:33；见第 2 部分 |
| — | 历史遗留 §7.12 / §7.3 | 🟡 / ⬜ | 见归档报告，未随本次修复改变 |

---

## 1. 现象

复现（两个终端，均在 `frpcdemo` 下）：

```
./boot.sh runServer 127.0.0.1:1203      # 第一个终端：服务端正常起来
./boot.sh runClient 127.0.0.1:1203      # 第二个终端：客户端崩在解码
```

**第二个终端（客户端）**：

```
[ERROR-fountain::f_net.client.Client]2026/10/04,16:37:08.495819938|32;Client reader error None:None true
An exception has occured:
IndexOutOfBoundsException: Index out of bounds: index is '0', but array size is '0'.
        at fountain::f_codec.default.DefaultCodec::parseInt64(UInt8, Bool, std.core::Array<...>)(f_codec/src/default/DefaultCodec.cj: 709)
        at fountain::f_codec.default.DefaultCodec::decodeData(std.io::InputStream)(f_codec/src/default/DefaultCodec.cj: 887)
        at fountain::f_codec.default.DefaultCodec::decode<...>(std.io::InputStream)(f_codec/src/default/DefaultCodec.cj: 1027)
        at fountain::f_protocol.default.Message::decode<...>(std.io::InputStream)(f_protocol/src/default/Message.cj: 293)
        at fountain::f_net.client.Client<...>::init::loop(fountain::f_net::SocketBuffer)(f_net/src/client/client.cj: 58)
```

随后 RPC 调用因断链超时失败：

```
[ERROR-...]echo RPC failed
An exception has occured:
fountain::f_rpc.base.RPCException:no available client for fountain::rpcdef.EchoRPC.echo(version *) after 5s,
check that the service node is started and registered
        at fountain::f_rpc.client.RPCClient::call<...>(f_rpc/src/client/RPCClient.cj.macrocall: 182)
        at fountain::rpcdef.EchoRPC_Stub__::echo(frpcdemo/rpcdef/src/EchoRPC.cj.macrocall: 39)
        at fountain::rpcclient.ClientInitializer::start()(frpcdemo/rpcclient/src/client.cj: 60)
```

**第一个终端（服务端）**同时出现：

```
[WARN-fountain::f_net.server.Server]2026/10/04,16:37:08.496251491|273;error occurred on decoding
An exception has occured:
SocketException: Failed to read data 104: Connection reset by peer.
        at std.net.TcpSocket::read(...) → fountain::f_net.SocketBuffer::read(f_net/src/SocketBuffer.cj: 79)
        at fountain::f_protocol.default.readFully(std.io::InputStream, std.core::Array<...>)(f_protocol/src/default/Message.cj: 73)
        at fountain::f_protocol.default.Message::decode<...>(std.io::InputStream)(f_protocol/src/default/Message.cj: 275)
        at fountain::f_net.server.Server<...>::start::lambda.0()(f_net/src/server/server.cj: 130)
```

⇒ 服务端这条是**客户端崩溃断链的后果**（时间戳同一毫秒），不是独立问题；一个根因、两处症状。

## 2. 根因（确切到行）

编码侧对**空集合 / 空映射**只写一个 head 字节：低半字节 = 0，**不写长度字节**（`f_codec/src/default/DefaultCodec.cj` 的 `encode`，共 3 处短路）：

| 行 | 编码分支 | 写出的头 |
| --- | --- | --- |
| 154-157 | `case x: Collection<Data>` | `[COLLECTION.value]`（低半字节 0） |
| 190-193 | `case x: Collection<(Data, Data)>` | `[MAP.value]`（低半字节 0） |
| 203-206 | `case x: Collection<(String, Data)>`（`DataDict`） | `[MAP.value]`（低半字节 0） |

解码侧 COLLECTION / MAP 分支把 `head & 0x0f` 当作「长度字节数」使用，却**没有 `s == 0` 的分支**（修前）：

```cangjie
        } else if (dataType == DataType.COLLECTION.value) {
            let list = DataList()
            let s = Int64(head & 0x0f)
            bytes = Array<Byte>(s, repeat: 0)      // s == 0 ⇒ 空数组
            size = input.read(bytes)               // 读 0 字节；且 `0 < 0` 为假 ⇒ 不会抛
            if (size < s) {
                throw CodecException('current data head is ${toHex(head)}, but read ${size} bytes')
            }
            size = parseInt64(head, true, bytes)   // ← 空数组进 parseInt64 的 else 分支 ⇒ bytes[0] 越界
```

`parseInt64`（同文件 690-711）只在 `bytes.size ∈ {1..8}` 时按位拼接，`size == 0` 会落到最后的 `else` 分支（708-711）⇒ `bytes[0]` ⇒ **`IndexOutOfBoundsException: index is '0', but array size is '0'`**，与栈完全一致（`DefaultCodec.cj:887 → 709`）。

同文件里其它「低半字节编码长度」的分支**都有**零值处理，只有 COLLECTION / MAP 漏了：

- STRING：`ss == 0` ⇒ 返回 `''`（754-758）；
- INT / FLOAT / INPUTSTREAM / `readBigInt1`：`head & 0x07` 且 `0 ⇒ 8`（779-782、814-817、951-954、1061-1064）。

**为什么现在才暴露**：客户端 reader 用 `Message.decode<DataAny>`（`f_net/src/client/client.cj:58`）做**中性解码**，会真的去解「参数为空」的集合（ACK / 空 params 的响应）；这个改动随 §7.10 的修复进入 `sts/1.3.x`。此前按 `RPCMessage` 宽松解码不会走到这条分支 ⇒ 空集合路径**从未被用例覆盖**。

## 3. 修法

`decodeData` 按编码侧约定补上零值处理（与 STRING 分支对齐，`parseInt64` 不动）：

- COLLECTION：`s == 0` ⇒ 直接返回空 `DataList()`（DefaultCodec.cj:885-887）；
- MAP：`s == 0` ⇒ 直接返回空 `DataTuples()`（DefaultCodec.cj:903-905）—— 同时覆盖 `Collection<(Data, Data)>` 与 `Collection<(String, Data)>` 两种编码来源。

## 4. 用例与验证

- 新增回归用例 `DefaultCodec_test.testEmptyCollectionAndMap`（空集合 + 空映射的编解码往返）：
  - **修前**：`[ ERROR ] CASE: testEmptyCollectionAndMap`（`15 passed / 1 error`）—— 先复现、后修复；
  - **修后**：`f_codec` **16/16**，`EXIT=0`。
- 同族排查（避免只修一半）：
  - STRING / INT / FLOAT / INPUTSTREAM / BigInt1：已有零值处理 ✓；
  - BYTES（`readBytes`，被 `readBytes`/`readBigInt2`/OBJECT murmur 使用）：编码侧走 `encodeSizeOfValue`，长度字节数恒 ≥ 1（空数组也会写 1 个 `0x00`）⇒ 不会出现低半字节 0 ✓ 无需改；
  - 编码侧空值短路共 3 处，全部落在 COLLECTION / MAP 两个数据类型的头上 ⇒ 本次两个守卫已全覆盖。
- 端到端验收（**待确认**）：按第 1 节的两条命令重跑，预期
  1. 客户端不再出现 `IndexOutOfBoundsException`，`echo RPC` 能拿到结果；
  2. 服务端不再出现 `error occurred on decoding` + `Connection reset by peer`。

## 5. 备注

- 这类缺陷的形态是「**空值有专门的紧凑编码，解码侧却只按非空路径读**」：只靠常规往返用例（非空集合）覆盖不到，必须显式测「空」。
- 下次遇到「解码越界 / 读到 0 字节」类问题，先确认**编码侧可能写出哪些 head 形态**——本 bug 的编码约定分散在 `encode` 的空值短路与 `encodeSizeOfValue`（低半字节 = 长度字节数，恒 ≥ 1）两处，对齐这两处即可穷举。

---

# 第 2 部分：RPC 客户端负载均衡（轮询 / 权重）：验证与修复（2026-10-04）

## 1. 验证结论

`frpcdemo` 的客户端改为**轮询**、`start()` 循环调用 `echo.echo(po)` **100 次**；服务端每次处理都会打印收到的 JSON，
因此各服务节点被调用的次数可以直接按行数出来。三个场景实测：

| 场景 | 两个服务节点的权重 | 客户端配置 | 实测（1203 : 1204） | 期望 |
| --- | --- | --- | --- | --- |
| 1 | 1203 = 1.0，1204 = 1.0（各自独立启动） | `127.0.0.1:1203,127.0.0.1:1204` | **50 : 50**（100/100 成功） | 各一半 ✓ |
| 2 | 1203 = **2.0**，1204 = 1.0 | 同上 | **67 : 33** | 2 : 1 ✓ |
| 3 | 1203 = 2.0（**种子节点**）、1204 = 1.0（只向种子注册） | 只配 `127.0.0.1:1203` | **67 : 33** | 2 : 1 ✓ |

场景 3 的链路：客户端只认识种子节点 ⇒ `SUBSCRIBE(data:true)` 从种子拿到全部服务节点地址（1203 自己 + 1204）⇒
逐个 `SUBSCRIBE(data:false)` 订阅后建立调用池，权重取自注册表 ⇒ 权重跨节点生效。

## 2. 演示代码改动（`frpcdemo`）

- `rpcclient/src/client.cj`：`start()` 按 `rounds = 100` 循环调用 `echo.echo(po)`（单次失败只记日志并继续），
  最后打印 `echo 调用完成：成功 N/100` 与最后一次响应的 JSON。
- `boot.sh`：
  - `runServer <主机:端口> [种子节点|-] [权重]`：从「主机:端口」里**拆出端口**填 `rpcServer_port`；`rpcServer_weight` 可配；
    `baseAddresses` = 显式给的种子节点 + **自己**；
  - `runClient <主机:端口>[,<主机:端口>...]`：逗号分隔多个地址 ⇒ 生成 `权重,地址|权重,地址`（各 1.0），
    并固定 `rpcClient_loadbalance=roundrobin`（轮询）。

为什么服务节点要「把自己也作为注册目标」：**权重是通过注册表传播的** —— 客户端从 `SUBSCRIBE(data:true)` 返回的
`host,weight` 里读权重，注册表里查不到的节点只能退回客户端配置里的权重（1.0）。让每个节点把自己也注册进去，
它自己的权重才会出现在注册表里（场景 3 中种子节点自身的权重也是这样生效的）。

## 3. 修复的库缺陷（3 个，都会让负载均衡失效）

### 3.1 `LoadBalanceIterator` 忽略算法选择（`f_concurrent/src/LoadBalance.cj`）

`LoadBalance` 的 TreeMap 以各节点**累计权重**为键，`iterator()` 构造了「从算法选定位置开始」的 `sub` 迭代器，
但 `LoadBalanceIterator.next()` 读的是 `itr`（整棵树、按键升序）—— `sub` 从未被使用 ⇒ 算法的选择完全被忽略，
每次都命中键最小的节点（= 最先 `add` 的节点）⇒ 轮询、随机、权重全部失效（实测 A=100 / B=0）。

修法：`next()` 先取 `sub`，取空后再从头（`itr`）绕回。诊断用例的产出序列：修前 `AAAAAA` ⇒ 修后 `ABABAB`。

### 3.2 `Float64Weight` 对浮点用了 `closed: true`（等价于 +1.0）

`random.nextFloat64(min, max, closed: true)` 是 `rand * (max - min + 1.0) + min`（+1 是给**整数**类型准备的），
浮点用它会把握区间放大成 `[min, max+1)` ⇒ 权重比例整体失真：等权 `[0,2]` 实测命中 **653 : 347**，
权重 2:1 的 `[0,3]` 实测 **755 : 245**。

修法：浮点改用 `[min, max)`（均匀分布取到端点的概率为 0，与闭区间等价）。

### 3.3 轮询接线：累计键原点与算法取值起点被绑成同一个 `min`

`MultiClientBuilder.roundRobin(step, min, max)` 把 `min` 同时当作 `LoadBalance` 的**累计键原点**与 `RoundRobin`
的**取值起点**。`ClientConfig` 传入 `min = 0.5`（为了避开桶边界）后，桶边界随之变成 1.5 / 2.5，而取值序列
0.5 / 1.5 / 2.5 正好**踩在边界上**（`forward(v, inclusive: true)` 把边界归给前一个桶）⇒ 永远命中第一个节点，
表现与修复前**完全一样**（A=100 / B=0），极易误判成「修复没生效」。

修法：
- `MultiClientBuilder.roundRobin(step, min, max, origin!: ?W = None)`：新增 `origin` 作为累计键原点（缺省等于 `min`，兼容旧行为）；
- `ClientConfig`：`builder.roundRobin(1.0f64, 0.5f64, Σw, origin: 0.0f64)`（随机侧对应 `builder.random(0.0f64, Σw)`）。

排查手法（可复用）：① 在发现阶段打印 `hosts` 组成（确认调用池里确实有两个节点）；② 在 `MultiClient.iterator()`
打印实际产出顺序；③ 在 `LoadBalance.iterator()` 打印 `tree.size`。三者结合可以把「池子建错了」与「选了但不生效」
彻底分开——本次正是靠 ③ 看到 `tree.size=2`、靠 ② 看到前四次产出交替，才把范围收敛到「取值与桶边界对齐」。

## 4. 用例与验证

- 新增 `f_concurrent/src/LoadBalance_test.cj`（6 个断言型用例）：迭代必须跟随算法选择（`ABABAB` / `AABAAB`）、
  等权轮询 50/50、2:1 轮询 67/33、4:1 轮询 80/20、等权随机 ~50/50、2:1 随机 ~67/33 ⇒ `--filter '*LoadBalance*'` **6/6**。
- 端到端：第 1 节表格（每场景 100 次调用，服务端逐次打印、按行计数）。
- 回归：`f_net` / `f_rpc` 全量用例（见提交信息）。

## 5. 备注

- **`rpcServer_port` 只接受 `UInt16`**（见 `f_rpc/README.md` 的配置表）：修前 `./boot.sh runServer 127.0.0.1:1204`
  把整个 `"127.0.0.1:1204"` 交给它，`UInt16.tryParse` 失败 ⇒ **静默回落到默认端口 1203**，两个服务节点会撞端口。
  已在 `boot.sh` 里拆出端口（实测 `UInt16.tryParse("127.0.0.1:1203") == None`）。
- 轮询用「单位网格」取值（`step = 1.0` 从 0.5 起）：整数权重下比例精确，非整数权重是近似比例。
- 权重依赖注册表传播：`rpcClient_serverAddress` 里的权重只在注册表没有该节点信息时兜底。
- 新增一条 DEBUG 日志 `[FOUNTAIN_RPC.hosts] <服务> -> N host(s): ...`（服务发现每次刷新打印调用池组成），
  排查这类「池子里有谁」的问题时不必再临时加探针。
