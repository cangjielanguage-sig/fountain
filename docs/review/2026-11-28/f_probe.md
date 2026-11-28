# f_probe 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `f_probe_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`f_probe`（16 个文件：12 个 .cj + 4 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：扩展契约与实现一致性、注册表并发与全局状态、重复逻辑、死代码、README 覆盖率
- **报告版本**：v1（由主 Agent 直接审查）

## 发现

### [一般][存量] README 的错误码清单里有一个实现中不存在的 `UNSUPPORTED`

- **位置**：`f_probe/README.md:40`（`ProbeErrorCode`：`CONFIG`、`COLLECT`、`LOAD`、`DUPLICATE`、`UNSUPPORTED`）对照 `f_probe/src/ProbeException.cj:25-30`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺源 + 缺失证据）
- **证据**：静态确定 —— 枚举只有 `DUPLICATE` / `CONFIG` / `LOAD` / `COLLECT` 四项；全仓 `grep -rn "UNSUPPORTED"` 在 `f_probe` / `fprobe` 内零命中（其余命中属 f_mvc 的 `UNSUPPORTED_MEDIA_TYPE`、f_rule 文档等无关符号）
- **描述**：文档承诺了第五个错误码，扩展作者会写出 `catch (e: ProbeException) { if (e.code == UNSUPPORTED) … }` 这类不存在的分支；更常见的是按 README 判「未知数据格式 = UNSUPPORTED」，而实际实现只能抛 `COLLECT`
- **建议**：二选一——从 README 删掉 `UNSUPPORTED`；或真的加进枚举并在需要「不支持的采集类型」的地方使用

### [一般][存量] README 把注册 API 写成 `register`，实际方法名是 `registerChannel`

- **位置**：`f_probe/README.md:33`（`AlarmChannelRegistry.register(name, factory)`）对照 `f_probe/src/AlarmChannelRegistry.cj:32`（`registerChannel`）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致）、§14.2（公开声明未正确进 README）
- **证据**：静态确定 —— 类中只有 `registerChannel` / `channels` / `channel` / `clear`；`doc/contract.md:102` 写的是正确名字 `registerChannel`，两处文档自相矛盾
- **描述**：按 README 写扩展会直接编译失败（`register` 不存在），而 `doc/contract.md` 又是对的，读者无从判断哪份为准
- **建议**：README 改成 `registerChannel`，并把 `doc/contract.md` 作为唯一事实源在 README 里显式声明

### [一般][存量] `ProbeRegistry` 与 `AlarmChannelRegistry` 是逐行同构的两份实现

- **位置**：`f_probe/src/ProbeRegistry.cj:28-66` 与 `f_probe/src/AlarmChannelRegistry.cj:27-65`
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑：只改类型名）
- **证据**：静态确定 —— 两者都是「`private static let lock = Mutex()` + `HashMap<String, 工厂>` + `register*`（重名抛 `ProbeException(DUPLICATE, ...)`）+ `agents/channels`（加锁遍历成 `Array<String>`）+ `agent/channel`（加锁 `get`）+ `clear`；差异只在工厂返回类型与错误消息前缀
- **描述**：重名检测、快照语义、加锁范围需要两处同步修改；一旦有人在其中一处加「空名拒绝」或「按名排序」，两份行为就会漂移（当前错误消息已不一致：`duplicate probe kind:` vs `duplicate alarm channel:`，属有意为之）
- **建议**：抽一个 `Registry<T>`（`HashMap<String, () -> T>` + 名字参数化）供两者复用，公开 API 保持不变

### [轻微][存量] `clear()` 是公开的生产可调用入口，会不可恢复地清空全局注册表

- **位置**：`f_probe/src/ProbeRegistry.cj:60-65`、`f_probe/src/AlarmChannelRegistry.cj:59-64`
- **来源**：存量
- **判据**：review-checklist §10（API 设计：全局可变状态）
- **证据**：静态确定 —— 内置探针在 `dlopen` 期注册一次，`clear()` 之后没有任何重建路径；`doc/contract.md:91,105` 只写「仅供测试」
- **描述**：任何业务代码（或扩展）误调一次 `clear()`，此后 `agents()` 为空、`collect` 全部找不到工厂，且无法在运行期恢复
- **建议**：改为测试专用入口（`@TestOnly` 或包内 `internal` + 测试放在同包），或在 `clear()` 里检查 `@When[test]` 条件编译

### [轻微][存量] `f_probe.cj` 只有包声明与文档注释，无任何声明

- **位置**：`f_probe/src/f_probe.cj:16-22`
- **来源**：存量
- **判据**：review-checklist §1（冗余文件）
- **证据**：静态确定 —— 文件在 `package fountain::f_probe` 与一段文档注释后结束；模块文档已在 `README.md` 与 `doc/contract.md`
- **描述**：空文件对编译与文档都不产生作用，读者会误以为里面还有初始化逻辑
- **建议**：删除，或把该段模块说明移到包注释所在的实体文件

## 优化可行性方案

无（模块只有两张注册表，无热点路径与内存驻留问题；`channels()` / `agents()` 每次都新建 `ArrayList` 属 O(n) 小分配，不构成优化项）。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `channels()` 在渠道数增长后成为采集路径热点 | `AlarmChannelRegistry.cj:42-50` | 调用频次与渠道数 | 在 fprobe 稳态负载下 `cjprof` 看 `channels` 自耗时；当前渠道数是个位数，预期不成立 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_probe/README.md` | .md | ✅ | 全文 57 行；见发现 1/2 |
| 2 | `f_probe/README_en.md` | .md | 未读 | 仅确认存在（与中文版同结构），未逐行核对 |
| 3 | `f_probe/doc/contract.md` | .md | ✅ | 抽查关键段（`host` 语义、`sendRich`、注册表签名、`clear` 说明），签名与实现一致 |
| 4 | `f_probe/doc/extension-guide.md` | .md | 未读 | 仅抽查 `registerChannel` 示例（第 85 行，与实现一致） |
| 5 | `f_probe/src/AlarmChannelRegistry.cj` | .cj | ✅ | 见发现 3/4 |
| 6 | `f_probe/src/AlarmChannelRegistry_test.cj` | .cj | ✅ | 覆盖重名拒绝与 24 线程并发注册，断言到 `DUPLICATE` 与消息内容 |
| 7 | `f_probe/src/AlarmMessageChannel.cj` | .cj | ✅ | `sendRich` 默认实现正确退化，无问题 |
| 8 | `f_probe/src/AlarmMessageChannel_test.cj` | .cj | ✅ | 覆盖默认退化与空 `receive` |
| 9 | `f_probe/src/ExtensionExample_test.cj` | .cj | ✅ | 文档示例的可编译校验，无问题 |
| 10 | `f_probe/src/ProbeAgent.cj` | .cj | ✅ | `host` 默认空串，与 contract.md:23 一致 |
| 11 | `f_probe/src/ProbeAgent_test.cj` | .cj | ✅ | 覆盖 `host` 默认值 |
| 12 | `f_probe/src/ProbeException.cj` | .cj | ✅ | 见发现 1 |
| 13 | `f_probe/src/ProbeException_test.cj` | .cj | ✅ | 覆盖四个错误码与 `BaseException` 可捕获性 |
| 14 | `f_probe/src/ProbeRegistry.cj` | .cj | ✅ | 见发现 3/4 |
| 15 | `f_probe/src/ProbeRegistry_test.cj` | .cj | ✅ | 覆盖注册/重名/并发/缺失四类场景 |
| 16 | `f_probe/src/f_probe.cj` | .cj | ✅ | 见发现 5 |

合计：`.cj` 12 个全部读完 / `.md` 4 个（2 读、2 抽查）/ 共 16 个。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 发现 4（全局清空入口） |
| §1 死代码 | 1 | 逐个 `private` / `internal` 符号全仓搜过：`lock` / `factories` 均被使用；`public` 的 `clear` / `channel` / `channels` 对外可达不判；空文件按冗余文件单列（发现 5） |
| §2 重复逻辑 | 1 | 两张注册表逐行同构（发现 3）；接口默认方法 `sendRich` 不算重复 |
| §3 空实现 | 0 | 生产代码无空函数体；`RegistryChannel.send` 空体在测试替身里，属正常桩 |
| §4 栈溢出 | 0 | 无递归 |
| §5 OOM | 0 | 注册表规模由 `dlopen` 数量决定，无按不可信长度预分配 |
| §6.1 热点瓶颈 | 0 | 无 profile 数据，`channels()` 列待验证假设 1 |
| §6.2 大粒度锁 | 0 | 临界区只包 `HashMap` 读写，无 I/O |
| §6.3 并发串行 | 0 | 注册与查询都只是内存操作，串行代价可忽略 |
| §6.4 低效算法 | 0 | 无 |
| §7 降堆内存方案 | 0 | 无大对象 |
| §8 降 CPU 方案 | 0 | 无 |
| §9 local mode 可行性 | 0 | 工厂闭包生命周期与进程同长，无临时大对象 |
| §11 现有代码的 BUG（存量） | 2 | 发现 1/2（文档承诺与实现不符） |
| §12 并发安全与锁粒度 | 0 | 共享状态只有两张 `HashMap`，全部读写都在 `synchronized(lock)` 内；`channels()` 返回新数组，无发布逸出 |
| §14 功能完备性与 README 覆盖 | 2 | 见发现 1（缺 `UNSUPPORTED` 实现）、发现 2（API 名错） |
| 文件覆盖（§13 等） | 14/16 | `README_en.md`、`doc/extension-guide.md` 仅抽查 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

代码质量良好：注册表加锁范围小、重名冲突显式抛错（`fountain` 的「重名必须报错」约定得到遵守）、接口默认方法给了扩展作者向后兼容的余地、测试覆盖了并发注册与错误码。问题都在文档与 API 表面：README 的错误码清单多了一个不存在的 `UNSUPPORTED`、注册方法名写错，以及两张同构注册表需要同步维护。存量 5 条，是否纳入修复待用户决定。
