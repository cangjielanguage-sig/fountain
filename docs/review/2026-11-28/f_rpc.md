# f_rpc 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `f_rpc_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`f_rpc`（26 个文件：24 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：连接与重试的收敛性、服务发现的信任边界、配置解析健壮性、日志对入参的暴露、启动期依赖
- **报告版本**：v1（由主 Agent 直接审查；`RPCClient.cj` 与 `RPCServer.cj` 逐段读，测试与部分宏文件为抽查）

## 发现

### [严重][存量] 三处「建连/注册」是无限忙等重试，对端不可用时会打满 CPU 并刷日志

- **位置**：`f_rpc/src/server/RPCServer.cj:56-63`、`f_rpc/src/server/RPCServer.cj:64-73`、`f_rpc/src/client/RPCClient.cj:95-104`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（资源耗尽）、§6.4（低效实现）、§11
- **证据**：静态确定 —— 三层 `while(true){ try{ …; break }catch(e){ log } }` 循环体内没有任何 `sleep` / 退避 / 次数上限；`clientBuilder.build()` 与 `client.transfer(...)` 失败后立即重来
- **描述**：注册中心或对端节点宕机时，服务端注册协程与客户端发现协程会以「失败-打印-立刻重试」的节奏空转：单核 CPU 打满、日志按每秒数千条增长（`rpclog.error` 还会写盘），并可能把日志文件撑满。这是最容易被忽略的生产事故形态（服务本身「没崩」但整机不可用）
- **建议**：改为有界退避（指数退避 + 上限 + 抖动），失败超过阈值时上抛让 `start()` 失败；至少加 `sleep`

### [严重][存量] 服务版本从「进程当前目录的 cjpm.toml」读取，读不到直接抛异常

- **位置**：`f_rpc/src/server/ServiceHub.cj:26`（`private static let version = extractVersion()`）、`f_rpc/src/server/ServiceHub.cj:111-120`
- **来源**：存量
- **判据**：review-checklist §11（契约与环境依赖）、§3（启动期失败的可见性）
- **证据**：静态确定 —— `extractVersion` 用 `env.getWorkingDirectory().join("cjpm.toml")` 读文件，找不到 `version=` 就 `throw RPCVersionException`
- **描述**：`ServiceHub` 的静态初始化在第一次触碰该类时执行，因此**进程启动目录**决定了 RPC 版本号：从 `/`、systemd 默认工作目录、或容器 `WORKDIR` 之外的路径启动时，整个 RPC 框架在类初始化阶段就抛异常（表现为服务起不来且错误信息只提 cjpm.toml）；同一份二进制在不同目录下行为不同，版本号还会随「恰好在那里的 cjpm.toml」漂移
- **建议**：版本改为编译期常量（构建时注入）或从显式配置项读取；至少在读取失败时退化为「未知版本 + WARN」，不要阻断启动

### [一般][存量] `ControllerTraceAspect` 把全部入参序列化进 INFO 日志，且序列化在 try 之外

- **位置**：`f_rpc/src/base/ControllerTraceAspect.cj:35-43`（构造 `argDatas` 与 `invocation`、`log.info`）、`f_rpc/src/base/ControllerTraceAspect.cj:44-49`（`try` 只包住 `point(...)`）
- **来源**：存量
- **判据**：review-checklist §10（敏感数据进日志）、§11（异常路径）
- **证据**：静态确定 —— `argDatas` 由 `x.toData()` 逐参序列化后 `.toString()`，再拼进 `log.info`；该字符串在 `try` 之前求值，且 `log.info` 接收的是已求值字符串（不是闭包），因此无论 INFO 是否开启都会执行
- **描述**：两个后果。其一，任何带 `@PostMapping` 等注解的控制器，请求体（含密码、token、身份证号）会以 INFO 级别落盘；其二，`toData()` 在参数为不可序列化对象时抛异常，异常点在 try 外，直接把「记日志」变成「请求 500」
- **建议**：改成 `log.info{...}` 惰性求值 + 只记参数类型与关键 id；敏感类型走白名单

### [一般][存量] REGISTER 无来源校验，任意节点可自定权重把自己塞进全局服务列表

- **位置**：`f_rpc/src/server/RPCServer.cj:128-139`（`RegisterExecutor.exec` 直接 `serviceHosts.add(...)`）、`f_rpc/src/server/RPCServer.cj:22`（`serviceHosts` 是包级全局）
- **来源**：存量
- **判据**：review-checklist §10（越权 / 信任边界）、§11
- **证据**：静态确定 —— 地址取自 `buffer.remoteAddress`（不可伪造），但 **端口与权重来自报文**（`server` 字符串按 `,` 拆分后 `UInt16.parse` / `Float64.parse`），没有任何白名单、签名或「只允许注册自身监听端口」的校验
- **描述**：任何能连上 RPC 端口的进程都能以 `(自己的IP, 任意端口, 任意权重)` 注册；随后 `SUBSCRIBE(hosts: true)` 会把这份列表发给所有客户端，客户端据此建连与加权。一个失控/被入侵的节点用一个极大权重就能吃掉全部流量（指向它自己的错误端口 = 全站 RPC 失败）
- **建议**：注册只接受「与本节点同端口」「配置白名单内」的地址；权重由中心侧配置而非报文决定

### [一般][存量] `ServiceMeta` 版本号按 `.` 拆分后直接取 `v[1]`，非法版本串会越界

- **位置**：`f_rpc/src/base/RPCMessage.cj:86-92`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 空值）
- **证据**：静态确定 —— `let v = version.split('.'); '${v[0]}.${v[1]}'`，当 `version` 为 `'1'`、`''` 或 `'*'`（`*` 已在上一分支处理）之外的无点串时 `v[1]` 越界
- **描述**：版本来自 `cjpm.toml`（见上一条）或调用方显式传入；`exactlyVersion=false` 的路径上只要版本号不是三段式就抛 `OutOfBoundsException`，且异常发生在 `ServiceMeta` 构造里 —— 骨架注册阶段会把它变成整个模块注册失败
- **建议**：`v.size >= 2` 才截断，否则原样保留；或统一用 `Version` 类型解析

### [一般][存量] `metas` / SUBSCRIBE 的「先取 size 再取迭代器」在并发注册下会随机抛错

- **位置**：`f_rpc/src/server/ServiceHub.cj:105-109`、`f_rpc/src/server/RPCServer.cj:150-165`
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 快照不一致）
- **证据**：静态确定 —— 两者都是 `Array<X>(map.size){_ => itr.next().getOrThrow()}`：`size` 与 `next()` 来自两次独立读取，`ConcurrentHashMap` 不保证两者之间元素数不变
- **描述**：骨架注册（启动期）与 SUBSCRIBE（客户端并发拉取）重叠时，`itr.next()` 可能返回 `None` → `getOrThrow()` 抛 `NoneValueException`；客户端拿到的是 ERROR 而不是服务列表，表现为「偶发服务发现失败」，重试才成功
- **建议**：直接 `hub.keys()` / `entryView` 收集成数组（一次遍历），不要用 size 预分配 + 迭代器

### [轻微][存量] `RPCTypeRegistration` 用 `catch (_: Exception)` 静默吞掉注册失败

- **位置**：`f_rpc/src/base/RPCTypeRegistration.cj:36-51`
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）
- **证据**：静态确定 —— 反射失败、`dataFields()` 缺失、类型不满足 `SimpleDataObject` 都走空 catch，无日志、无返回值
- **描述**：类型没登记成功时，第一次跨 RPC 传输该类型会在解码侧报「未知类型」，与真正原因（这里吞掉的反射异常）相隔很远
- **建议**：至少 `rpclog.debug` 记录被跳过的类型与原因

### [轻微][存量] 配置解析多处直接下标，缺项时是越界而不是可读的错误

- **位置**：`f_rpc/src/client/ClientConfig.cj:54-60`（`arr[0]` / `arr[1]`）、`143`、`153`、`f_rpc/src/server/RPCServer.cj:132-136`
- **来源**：存量
- **判据**：review-checklist §11（配置校验）
- **证据**：静态确定 —— `split(',')` 后不校验长度即取 `arr[1]` / `arr[2]`；`Float64.parse` / `Int32.parse` 也不捕获
- **描述**：`rpcClient_serverAddress=1.0`（漏写地址）这类笔误会抛 `OutOfBoundsException`，堆栈指向 `ClientConfig` 内部，运维看不出是哪个配置项
- **建议**：统一走「解析失败 → 抛带配置项名与原文的配置异常」

### [轻微][存量] 首个 RPC 调用在服务发现完成前按 20ms 轮询阻塞调用线程

- **位置**：`f_rpc/src/client/RPCClient.cj:164-177`
- **来源**：存量
- **判据**：review-checklist §6.4（忙轮询）
- **证据**：静态确定 —— `while(true){ if(services.get(meta)) return; if(now>=deadline) break; sleep(20ms) }`
- **描述**：默认 5s 超时内每 20ms 唤醒一次；并发调用 N 个未发现服务时会形成 N 倍的轮询唤醒，且调用方线程被整段阻塞（不是异步等待）。当前规模下影响有限，故定为轻微
- **建议**：换成条件变量 / 事件通知，或至少指数退避

## 优化可行性方案

### [CPU] 注册/发现的重试循环加退避

- **现状**：失败即重试，无退避（`RPCServer.cj:56-73`、`RPCClient.cj:95-104`）；对端不可用时单核被打满
- **方案**：指数退避 100ms → 5s，加 ±20% 抖动，上限重试次数可配
- **预期**：无对端时 CPU 从「忙等」降到近似 0；日志量按退避间隔线性下降
- **代价**：故障恢复延迟从「立即」变为「最多一个退避窗口」
- **验证**：`cjprof record` 跑「注册中心不可达」场景 60s，对比改前改后进程 CPU 时间与日志条数
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `client.transfer(...).get()` 在未配置 `rpcClient_readTimeout` 时会无限阻塞 | `RPCClient.cj:203`、`ClientConfig.cj:119-123` | f_net Client 的默认读超时 | 读 f_net `Client` 构造默认值；或起一个只 accept 不回包的假服务端，观察调用线程是否永久阻塞 |
| 2 | `ControllerTraceAspect` 的入参序列化占单请求 CPU 的可测量比例 | `ControllerTraceAspect.cj:35-41` | 自耗时占比 | `cjprof` 跑 fdemo 控制器稳态负载，看 `toData` 与 `JsonValue.from` 自耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rpc/README.md` | .md | 未读 | 仅确认存在；本轮按源码为准 |
| 2 | `f_rpc/README_en.md` | .md | 未读 | 同上 |
| 3 | `f_rpc/src/RpcTestSetup_test.cj` | .cj | 未读 | 测试基建，未展开 |
| 4 | `f_rpc/src/base/ControllerTraceAspect.cj` | .cj | ✅ | 见发现 3 |
| 5 | `f_rpc/src/base/PoolConfig.cj` | .cj | ✅ | CAS 后初始化池，无锁但有极小窗口（未单列） |
| 6 | `f_rpc/src/base/RPCException.cj` | .cj | ✅ | 模板异常类 |
| 7 | `f_rpc/src/base/RPCMessage.cj` | .cj | ✅ | 见发现 5 |
| 8 | `f_rpc/src/base/RPCTypeRegistration.cj` | .cj | ✅ | 见轻微 1 |
| 9 | `f_rpc/src/base/imports.cj` | .cj | ✅ | 日志辅助，`logmsg` 三个重载有重复（未单列） |
| 10 | `f_rpc/src/client/ClientConfig.cj` | .cj | ✅ | 见轻微 2 |
| 11 | `f_rpc/src/client/RPCClient.cj` | .cj | ✅ | 见发现 1/6、轻微 3 |
| 12 | `f_rpc/src/client/imports.cj` | .cj | 未读 | 纯 import |
| 13 | `f_rpc/src/encodedmessage_release_test.cj` | .cj | 未读 | 测试 |
| 14 | `f_rpc/src/health/HealthRPC.cj` | .cj | 未读 | 接口声明 |
| 15 | `f_rpc/src/health/server/HealthRPCImpl.cj` | .cj | 未读 | 实现 |
| 16 | `f_rpc/src/macros/RPCSkeleton.cj` | .cj | ✅（部分） | 见 §2 说明：`args[$i]` 由 `ConsumeExecutor` 的 catch 兜住 |
| 17 | `f_rpc/src/macros/RPCStub.cj` | .cj | 未读 | 宏模板，未展开 |
| 18 | `f_rpc/src/macros/TypeRegistration.cj` | .cj | 未读 | 宏 |
| 19 | `f_rpc/src/macros/imports.cj` | .cj | 未读 | 纯 import |
| 20 | `f_rpc/src/rpc.cj` | .cj | ✅ | 只有包声明（无声明，属冗余文件，未单列） |
| 21 | `f_rpc/src/server/LogMessage.cj` | .cj | 未读 | 日志载荷 |
| 22 | `f_rpc/src/server/RPCServer.cj` | .cj | ✅ | 见发现 1/4/6 |
| 23 | `f_rpc/src/server/RPCServerInitializer.cj` | .cj | 未读 | 启动器 |
| 24 | `f_rpc/src/server/ServerConfig.cj` | .cj | 未读 | 配置读取 |
| 25 | `f_rpc/src/server/ServiceHub.cj` | .cj | ✅ | 见发现 2/6 |
| 26 | `f_rpc/src/server/imports.cj` | .cj | 未读 | 纯 import |

合计：`.cj` 12 个逐段读完 / 12 个未读（测试、imports、宏模板、健康检查、配置读取）/ `.md` 2 个未读。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 发现 3（日志泄露）、4（信任边界）、5（越界） |
| §1 死代码 | 0 | 抽查的 `private` / `protected` 符号均有调用者；`rpc.cj` 空文件按冗余单列（见文件覆盖） |
| §2 重复逻辑 | 1 | `imports.cj` 的三个 `logmsg` 重载 + `ClientConfig.createClient` 内的 `checker` 与 `imports.cj:64` 的 `checker` 同实现（未单列，属小重复） |
| §3 空实现 | 1 | 发现 7（静默吞异常） |
| §4 栈溢出 | 0 | 无递归 |
| §5 OOM | 1 | 无界重试的日志增长（发现 1），已并入该条 |
| §6.1 热点瓶颈 | 0 | 无 profile 数据，入参序列化列待验证假设 2 |
| §6.2 大粒度锁 | 0 | 无显式锁；`ConcurrentHashMap` 分段 |
| §6.3 并发串行 | 0 | 无 |
| §6.4 低效算法 | 2 | 发现 1（忙等）、轻微 3（20ms 轮询） |
| §7 降堆内存方案 | 0 | 无大对象驻留 |
| §8 降 CPU 方案 | 1 | 「重试加退避」方案，无基线 |
| §9 local mode 可行性 | 0 | 无稳定的大临时对象证据 |
| §11 现有代码的 BUG（存量） | 5 | 发现 1/2/5/6/7 |
| §12 并发安全与锁粒度 | 1 | 发现 6（size/iterator 竞态）；`Box<Array<Client>>` 跨线程写入可见性未单列 |
| §14 功能完备性与 README 覆盖 | 0 | 本轮未逐项对照 README（README 未读） |
| 文件覆盖（§13 等） | 12/26 | 未读项已在覆盖表逐行标注 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 4 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

主干设计是清楚的（`ServiceMeta` 明确把 `weight` 排除出相等/哈希、负载均衡按累计权重取桶、每个请求清 thread-local trace），代码注释里也保留了大量「曾经踩过的坑」——这些都是优点。风险集中在三处：**故障期的收敛性**（三处无退避忙等，发现 1）、**启动期对工作目录的硬依赖**（发现 2），以及**日志与信任边界**（发现 3/4）。前两条会直接把「对端故障」放大成「本机不可用」，应优先处理。存量 4 条（严重 2 / 一般 2），是否纳入修复待用户决定。
