# f_security 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `f_security_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`f_security`（16 个文件：14 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：登录状态契约与实现一致性、密钥与凭据的暴露面、重复逻辑、死代码、并发安全、存量 BUG
- **报告版本**：v1（本模块由主 Agent 直接审查：子 agent 配额用尽后按用户决定改为主 Agent 逐文件读）

## 发现

### [一般][存量] `JWTPrincipal.key` 把签名密钥放在对外返回的 principal 上，且经堆缓存长期驻留

- **位置**：`f_security/src/JWTPrincipal.cj:22`（`public let key: String`）、`f_security/src/HeapCacheStore.cj:23-31`、`f_security/src/SecurityContext.cj:24-35`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（安全性：敏感数据暴露）、§11（契约与实现）
- **证据**：静态确定 —— `key` 是 `public let`，`SecurityContext.login` 把整个 principal 交给 `store.store`，`SecurityContext.get` / `checkAndGet` 又把整个 principal 返回给任意调用方；README.md:91 明确写它是「签名密钥」
- **描述**：签名密钥与「可对外传递的登录态」是同一个对象，任何拿到 `Principal` 的代码（含业务层、日志、序列化）都能读到密钥；密钥还会随 `HeapCache` 存活到 `maxLife` 结束。密钥应当在 `JWTSecurityContext` 内部持有（`keySetter` 闭包），principal 只暴露 `id` / `username`
- **建议**：把 `key` 从 `JWTPrincipal` 移到 `PrincipalStore` 侧（如 `KeyedStore`）或让 `keySetter` 直接由 store 查表取密钥，principal 保持纯数据

### [一般][存量] `checkAndGet` 每次调用解析 JWT 两遍，两段实现逐行重复

- **位置**：`f_security/src/JWTSecurityContext.cj:24-43`（check 闭包，26-40 提取 `Authorization` → `JWT.verifier` → `getKeyId` → `verify`）、`f_security/src/JWTSecurityContext.cj:45-62`（`getPricinpal`，47-61 同一段逻辑）
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑）、§11（检查-然后-写入 / TOCTOU）
- **证据**：静态确定 —— 两段代码的 header 提取、`Bearer ` 前缀剥离、`JWT.verifier` 构造、`getKeyId` 判定完全同构，仅最后一步不同（一个 `verify()`、一个 `store.get`）
- **描述**：`checkAndGet()`（67-72）先 `check(())` 再 `getPricinpal(store)`，一次请求里把同一张 JWT 解析两遍（解码 + 取 keyId 各两次），既有 CPU 浪费，也让「校验通过」和「取到 principal」来自两次独立解析：两次解析之间 store 内容变化时，返回的 principal 可能不是刚校验过的那一个
- **建议**：让 check 闭包返回解析结果（verifier/keyId）并在 `checkAndGet` 里复用，单一解析路径

### [一般][存量] `HeapCacheStore` 用 `id.toString()` 当键，绕过 `ID` 的 `Equatable`/`Hashable` 语义

- **位置**：`f_security/src/HeapCacheStore.cj:18-32`（`store` 24、`get` 27、`remove` 30 均 `toString()`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `PrincipalStore<ID, P> where ID <: Hashable & Equatable<ID>` 承诺按 `ID` 相等性存取，实现却按 `String` 表示；`store_.store`（40-42）再包一层同样转换
- **描述**：两个不同 `ID` 只要 `toString()` 相同就命中同一条会话（例如自定义 ID 的 `toString` 截断、或 `Int64` 与 `String` 混用的封装类型）；`remove(id)` 也因此可能删掉别人的会话。`UserTokenHeapCacheStore` 只是把这一语义又包了一层，问题不变
- **建议**：`HeapCacheStore` 约束 `ID <: ToString` 换成以 `ID` 本身为键（`HeapCache<String, …>` 换成 `HeapCache<ID, …>`，`Hashable` 已有），或显式在 README 写明「按 toString 归一化」

### [轻微][存量] `StringUserTokenHeapCacheStore` 类型别名全仓零引用（死代码）

- **位置**：`f_security/src/HeapCacheStore.cj:50`
- **来源**：存量
- **判据**：review-checklist §1（死代码：非公共顶级声明）
- **证据**：全仓 `grep -rn "\bStringUserTokenHeapCacheStore\b"` 只命中定义本身（`f_security/src/HeapCacheStore.cj:50`）
- **描述**：`type` 未加 `public`，是对包内可见的别名；包内无任何使用，README 也只列了 `JWTHeapCacheStore` 与 `UserTokenHeapCacheStore`
- **建议**：删除，或按用途加上 `public` 并在 README 登记

### [轻微][存量] 令牌比较用 `==`，不是常量时间比较

- **位置**：`f_security/src/UserTokenSecurityContext.cj:24`（`p.token == tpl[1]`）、`f_security/src/HttpHeaderUserTokenSecurityContext.cj:30`（`p.token == token`）
- **来源**：存量
- **判据**：review-checklist §10（安全性：凭据比较）
- **证据**：静态确定 —— 直接用 `String ==` 比较用户令牌
- **描述**：字符串比较提前返回，理论上可被远程计时侧信道利用；HTTP 头路径（`HttpHeaderUserTokenSecurityContext`）暴露在公网请求上，风险高于进程内调用。是否需要常量时间比较取决于令牌长度与熵（本项目 `UUID.random()` 生成的 token 熵足够），因此定为轻微
- **建议**：若 token 由外部提供（非本服务生成），改用逐字节异或累加的常量时间比较

### [轻微][存量] README 示例的 `keyId` 缺返回类型，却被当作 `Array<Byte>` 使用（待确认）

- **位置**：`f_security/README.md:161-168`、对照实现 `fdemo/user/src/util/UserSessionCache.cj:32-40`
- **来源**：存量
- **判据**：review-checklist §13（文档示例与实现一致性）
- **证据**：待确认 —— 仓颉函数省略返回类型时按 `Unit` 处理，则 `hmacKey(jwt, keyId(principal))` 的第二参是 `Unit`，与 `key: Array<Byte>` 不匹配；需在 WSL 用 `cjpm build` 验证 `fdemo/user` 是否真的编译通过
- **描述**：README 与 fdemo 用的是同一段代码，若不能编译则示例不可用；若可编译，说明返回类型被推断，README 应写明这一点（读者会误以为 `keyId` 返回 `Unit`）
- **建议**：给 `keyId` 补 `: Array<Byte>` 返回类型，README 与 demo 同步

## 优化可行性方案

无（本模块为薄封装层，未发现可用数据支撑的 CPU/内存优化点）。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | JWT 双解析占单请求 CPU 的可测量比例 | `JWTSecurityContext.cj:24-62` | 单请求耗时中 JWT 解析占比 | `cjprof record` 跑 fdemo 的 `/user/verify` 稳态负载，看 `JWT.verifier` / `getKeyId` 自耗时 |
| 2 | `HeapCacheStore` 的 `toString` 键在真实业务 ID 上是否会产生碰撞 | `HeapCacheStore.cj:23-31` | 业务 ID 类型与 `toString` 实现 | 采集使用方的 ID 类型清单（当前仓内仅 `String` / `Int64`），确认无自定义 ID |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_security/README.md` | .md | ✅ | 全部 183 行；见发现 1/6 |
| 2 | `f_security/README_en.md` | .md | 未读 | 仅 grep 抽查（`remove` / `maxLife` 段落与中文版对应），未逐行核对 |
| 3 | `f_security/src/BaseUserData.cj` | .cj | ✅ | 单接口声明，无问题 |
| 4 | `f_security/src/HeapCacheStore.cj` | .cj | ✅ | 见发现 3/4 |
| 5 | `f_security/src/HttpHeaderUserTokenSecurityContext.cj` | .cj | ✅ | 见发现 5；`getPricinpal` 与 check 闭包重复（与发现 2 同根因） |
| 6 | `f_security/src/JWTPrincipal.cj` | .cj | ✅ | 见发现 1 |
| 7 | `f_security/src/JWTSecurityContext.cj` | .cj | ✅ | 见发现 2 |
| 8 | `f_security/src/Principal.cj` | .cj | ✅ | 接口声明，无问题 |
| 9 | `f_security/src/PrincipalStore.cj` | .cj | ✅ | `remove` 库内零调用，属接口暴露（微轻，未单列） |
| 10 | `f_security/src/SecurityContext.cj` | .cj | ✅ | `store` 为 `protected let`，外部无法登出（见发现 1 建议） |
| 11 | `f_security/src/UserIdData.cj` | .cj | ✅ | `String` / `Int64` 扩展，无问题 |
| 12 | `f_security/src/UserNamePasswordUserData.cj` | .cj | ✅ | `password` 公开，README 已声明 |
| 13 | `f_security/src/UserTokenPrincipal.cj` | .cj | ✅ | `token` 公开，README 已声明 |
| 14 | `f_security/src/UserTokenSecurityContext.cj` | .cj | ✅ | 见发现 5 |
| 15 | `f_security/src/exception/SecurityException.cj` | .cj | ✅ | 四构造器模板类，无问题 |
| 16 | `f_security/src/imports.cj` | .cj | ✅ | `internal import`，无问题 |

合计：`.cj` 14 个全部读完 / `.md` 2 个（1 读、1 抽查）/ 共 16 个。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 见发现 1（密钥暴露）、2（TOCTOU+重复）、5（比较方式）、6（示例） |
| §1 死代码 | 1 | 逐个 `private` / `internal` / `protected` 符号全仓搜过：`getPricinpal` 有调用者、`StringUserTokenHeapCacheStore` 零引用（发现 4）；`public` 类型不判 |
| §2 重复逻辑 | 1 | 同文件两段 JWT 解析逐行同构（发现 2）；跨文件的 `checkAndGet(_: Unit)` 转发属正常重载，不计 |
| §3 空实现 | 0 | 14 个 .cj 无空函数体、无 TODO、无吞异常 |
| §4 栈溢出 | 0 | 无递归调用 |
| §5 OOM | 0 | 无按不可信长度预分配；缓存由 `HeapCache` 的 `maxLife` 约束 |
| §6.1 热点瓶颈 | 0 | 无 profile 数据，双解析列为待验证假设 1 |
| §6.2 大粒度锁 | 0 | 模块内无显式锁，缓存自身同步在 f_cache 审 |
| §6.3 并发串行 | 0 | 无串行点 |
| §6.4 低效算法 | 1 | 双解析属重复计算（发现 2） |
| §7 降堆内存方案 | 0 | 无大对象持有；密钥驻留问题已在发现 1 覆盖 |
| §8 降 CPU 方案 | 0 | 需 profile，见待验证假设 1 |
| §9 local mode 可行性 | 0 | 无函数内临时大对象，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 3 | 发现 1/2/3 |
| §12 并发安全与锁粒度 | 0 | 无共享可变状态（`context` 是 static let，内部缓存同步由 f_cache 负责）；`HeapCacheStore` 线程安全继承自 `HeapCache`，本模块未引入额外共享点 |
| §14 功能完备性与 README 覆盖 | 2 | `JWTSecurityContext.init(store:principalMaker:keySetter:)` 未进 README（§14.2）；`StringUserTokenHeapCacheStore` 未登记 |
| 文件覆盖（§13 等） | 15/16 | `README_en.md` 仅抽查 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

模块本身是薄封装（接口 + 两种 `SecurityContext` 实现 + 堆缓存适配），没有并发与资源生命周期问题。真正的风险在凭据模型：签名密钥被放进对外返回的 `Principal` 并由堆缓存长期持有（发现 1），加上 `HeapCacheStore` 用 `toString` 当键（发现 3），一旦业务层把 principal 透传或自定义 ID，会同时出现密钥扩散与会话串号。JWT 路径的双解析（发现 2）是设计层面的重复，修法简单但会动公开行为（check 闭包签名），需要走 propose 再改。存量 3 条，是否纳入修复待用户决定。
