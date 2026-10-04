# Bug 分析报告（当前活动）：RPC 客户端解码「空集合 / 空映射」响应时崩溃

- 日期：2026-10-04
- 分支：`fix/empty-payload-decode`（worktree `.worktrees/fix-empty-payload-decode`，基于 `sts/1.3.x`）
- 修复提交：`6518cb48`
- 历史报告（已归档）：`.autocode/bugs/bug-archived-on-20261004.md`
  —— 其中仍开着的两项：**§7.12**（`f_pool` 偶发 SIGSEGV，根因未证）、**§7.3**（重复归还同一对象，已裁定暂不改）。

## 状态总览

| # | 问题 | 状态 | 说明 |
| --- | --- | --- | --- |
| 1 | 客户端 reader 解码响应时 `IndexOutOfBoundsException`（空集合 / 空映射） | ✅ 已修 | 编码/解码约定对齐 + 回归用例；`f_codec` **16/16**；见下文 |
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
