# f_probe 模块审查报告（第 1/1 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_probe/`（12 个 `.cj`，其中 5 个 `_test.cj`；4 个 `.md`；共 16 个文件）
- **基线**：工作区快照（`HEAD=f309f0b55`，`git status` 中 `f_probe/` 无改动）⇒ 全部记为**存量**
- **审查重点**：扩展契约与实现一致性、注册表并发、重复逻辑、死代码、README 覆盖
- **报告版本**：v1-分部分（模块第 **1/1** 部分；同日主 Agent 的抽样版见 `docs/review/2026-11-28/f_probe.md`）

## 发现

### [严重][存量] 第三方告警渠道注册后没有任何可用路径（契约承诺但宿主未接线）（#1）

- **位置**：`f_probe/README.md:3`、`f_probe/README.md:33-36`、`f_probe/doc/contract.md:99-109`、`f_probe/doc/extension-guide.md:57-92`
- **来源**：存量（快照模式无基线；`git status` 中 `f_probe/` 干净）
- **判据**：review-checklist §14.1（承诺了但没实现 / 接线缺失）、§3（契约承诺有行为、实际路径为空）
- **证据**：静态确定 —— 全仓只有一处读 `AlarmChannelRegistry`：`fprobe/src/runtime/SupervisorRuntime.cj:498`，且只取 `isSome()` 判"渠道名已知"；`buildChannels()`（`:470-505`）只实例化 `email` 一种渠道，其余已注册名在 `:499-500` 打印「已注册但未配置，已跳过」后被丢弃。`CustomLoader.load` 的唯一调用点是 `fprobe/src/runtime/AgentRuntime.cj:52-54`（agent 模式），`grep -rn "CustomLoader" fprobe/src` 在 supervisor 侧零命中；`probe_customDir` 只定义在 `fprobe/src/config/AgentSettings.cj:37,80-81`，`fprobe.sh` 的 supervisor/resident 段也没有该参数（`fprobe/fprobe.sh:87` 仅在 agent 段）。
- **描述**：按 `doc/extension-guide.md` §3/§4 实现一个 `webhook` 渠道并在 `static init` 里 `AlarmChannelRegistry.registerChannel("webhook", ...)`，实际效果为零：supervisor 进程从不加载 `custom/`，扩展的 `static init` 不会执行；即使同进程内注册成功，`buildChannels()` 也不会取工厂、不会构造实例，只会把它当成"已注册但未配置"跳过，随后 `ChannelDispatcher` 拿到的是空的启用列表。对照可见不对称：探针侧的 `ProbeFactory.instantiate()`（`fprobe/src/collect/ProbeFactory.cj:76-88`）确实遍历注册表并调用工厂，扩展探针是能用的；只有告警渠道这条契约是空转。文档却明确写「注册完成后宿主即可枚举到 `k8s` / `webhook`」（`doc/extension-guide.md:90-92`）与「告警渠道注册后重名抛 DUPLICATE」（`doc/contract.md:108-109`），使用者会按文档做出一个永不生效的渠道，且只看到一条措辞误导的"已注册但未配置"日志。
- **建议**：二选一，必须在同一轮内收敛：① 在 fprobe 侧接线——supervisor 启动时加载 `custom/`（或抽出公共加载步骤），`buildChannels()` 对每个配置渠道名先查 `AlarmChannelRegistry.channel(name)`，`Some(factory)` 时调用工厂构造实例并加入 `channels`，`None` 时再走"未知渠道"的 CONFIG 路径；② 本轮不做扩展渠道，则删除 `README.md:3`、`README.md:33-36`、`doc/contract.md:99-109`、`doc/extension-guide.md:57-77/85/90-92` 中"扩展可提供告警渠道"的全部承诺，只保留探针扩展。代码落点在 `fprobe`（本模块范围外），本模块需要同步的是三份文档；两边不能各改一半，否则契约继续悬空。

### [一般][存量] README 声明的错误码 `UNSUPPORTED` 在枚举里不存在（#2）

- **位置**：`f_probe/README.md:40`、`f_probe/README_en.md:42`（对照 `f_probe/src/ProbeException.cj:25-29`）
- **来源**：存量
- **判据**：review-checklist §13（文档 API 与源码不符）、§14.2（公开 API 清单写错）
- **证据**：静态确定 —— `ProbeErrorCode` 只有 `DUPLICATE` / `CONFIG` / `LOAD` / `COLLECT` 四个构造器；`grep -rn "UNSUPPORTED" f_probe/` 只命中两个 README，源码与 `doc/contract.md:113-119` 的枚举摘录都没有第五个值。
- **描述**：README 两版都写「`CONFIG`、`COLLECT`、`LOAD`、`DUPLICATE`、`UNSUPPORTED`」。扩展作者按 README 写 `case ProbeErrorCode.UNSUPPORTED => ...` 会直接编译失败；按错误码分类做降级策略的代码也会以为存在"能力不支持"这一类。中英文两版同错，说明是同一处源头的笔误而非翻译漂移。
- **建议**：删除两版 README 里的 `UNSUPPORTED`，与 `doc/contract.md` §4 和源码对齐。若确实需要该类语义，应先在 `ProbeException.cj` 补构造器并同时补 `ProbeException_test` 的用例，再改文档。

### [一般][存量] 扩展指南的中心仓依赖版本 `1.3.17` 早于本模块引入（#3）

- **位置**：`f_probe/doc/extension-guide.md:25`（对照 `f_probe/cjpm.toml:16`、`CHANGELOG:120`）
- **来源**：存量
- **判据**：review-checklist §13（示例跑不通 / 版本过期）
- **证据**：静态确定 —— `f_probe/cjpm.toml:16` 为 `version = "1.3.2021"`；`CHANGELOG:120` 的 2026-11-09 条目才是「feat(f_probe): 新增服务器监控扩展契约」，即 `1.3.17` 时代该模块尚不存在；全仓 `grep -rn "1.3.17"` 在本模块只命中这一行文档（中心仓是否确有 `1.3.17` 的 `f_probe` 制品无法从仓库内验证，属待确认；但即便存在，那也是本模块引入之前的契约版本）。
- **描述**：指南给出中心仓场景的 `"fountain::f_probe" = "1.3.17"`。照抄大概率在依赖解析阶段失败（该版本早于模块引入），而不是在编译期给出可理解的错误；即便中心仓意外存在同名旧制品，其契约也与当前实现不一致（没有 `UNSUPPORTED`、错误码表与 `sendRich` 都可能不同）。这与仓库当前 1.3.2021 的版本策略也不一致。
- **建议**：改为 `1.3.2021`；更稳的写法是「版本随 fountain 主版本（当前 1.3.2021）」，并在发布流程里由 `fountain-tag` 统一核对，避免每次升版都要手改这份文档。

### [轻微][存量] 部署章节的扩展目录与启动脚本默认值不一致（#4）

- **位置**：`f_probe/doc/extension-guide.md:100-101`（对照 `fprobe/fprobe.sh:87`、`fprobe/src/config/AgentSettings.cj:37`）
- **来源**：存量
- **判据**：review-checklist §13（路径/示例与工程实际不符）
- **证据**：静态确定 —— 指南让 `mkdir -p /opt/fprobe/custom` 并拷入，而启动脚本 agent 段默认 `--probe_customDir=./custom`，`AgentSettings.customDir` 默认值同为 `./custom`。
- **描述**：按指南部署后若直接跑 `fprobe.sh agent`，扩展目录对不上（相对当前工作目录的 `./custom`），扩展静默不加载（目录不存在等价于没有扩展），排查成本高。另外指南没有说明扩展 `.so` 在运行期如何解析 `f_probe` 运行库；这一点是否需要在同目录放 `libf_probe.so` 或设置 `LD_LIBRARY_PATH` 需实测，本轮不单列为缺陷。
- **建议**：指南里写清"目标目录必须与 `probe_customDir` 一致（脚本默认 `./custom`，可显式传 `/opt/fprobe/custom`）"，或把脚本默认值改成 `/opt/fprobe/custom` 二者取一；同时补一句扩展运行库的解析方式。

### [轻微][存量] 契约里"`data` 返回非 object"的处置描述与类型约束不符（#5）

- **位置**：`f_probe/doc/contract.md:28`（对照 `f_probe/src/ProbeAgent.cj:38`）
- **来源**：存量
- **判据**：review-checklist §13（文档描述的实现路径不存在）
- **证据**：静态确定 —— `ProbeAgent.data` 的静态类型就是 `JsonObject`，扩展无法"返回非 object"；这条约定描述的失败实际只会表现为 `data` getter 内部 `JsonValue.asObject()` 抛 `JsonException`（`f_data/src/json/JsonValue.cj:70-75`），收集器在 `fprobe/src/collect/ProbeRunner.cj:80-89` 看到的是异常而非非法返回值。
- **描述**：结论（该项标记失败、不污染快照、不影响其它项）仍成立，但机制写错了：读者会去找一个不可能出现的"非 object 返回值"分支，也不会知道该抛什么异常。同一节 `:24` 推荐的 `JsonValue.from(dto).asObject()` 正是抛 `JsonException` 的那条路径。
- **建议**：改写为「`data` 必须是 JSON object；用 `JsonValue.from(dto).asObject()` 转换失败时抛出的 `JsonException` 会被收集器记为该项的失败」。若确实想统一成 `ProbeException(COLLECT)`，应在契约里明确要求扩展自行包装。

### [轻微][存量] 两个注册表是逐行同构的复制实现（#6）

- **位置**：`f_probe/src/ProbeRegistry.cj:28-66` 与 `f_probe/src/AlarmChannelRegistry.cj:27-65`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 同文件内函数体一一对齐）
- **证据**：静态确定 —— 逐函数比对：`registerAgent`/`registerChannel`（取锁 → `contains` → 抛 `DUPLICATE` → `add`）、`agents`/`channels`（取锁 → 遍历 `HashMap` 收集键 → `toArray`）、`agent`/`channel`（取锁 → `get`）、`clear`/`clear`（取锁 → `clear`）四组语义完全一致；差异只有三处：值类型 `() -> ProbeAgent` vs `() -> AlarmMessageChannel`、错误前缀 `"duplicate probe kind: "` vs `"duplicate alarm channel: "`、类名与文档。
- **描述**：两份 39 行的实现（含 4 个方法）没有语义差异，任何一处策略调整（并发方式、快照顺序约定、异常文案格式）都要双改，已经出现过"中英文档同错"这种同源问题；并发用例也是两份各写一遍（`ProbeRegistry_test.cj:62-76`、`AlarmChannelRegistry_test.cj:63-77`）。
- **建议**：抽一个包内 `private class FactoryStore<V>`（`Mutex` + `HashMap<String, V>` + `label: String` 用于拼错误文案），两个 public 类各持一个 `private static let store = FactoryStore<...>("probe kind")`，方法体退化为一行委托。必须保留：public 方法名/签名不变、错误文案前缀不变、`agents()`/`channels()` 返回快照的语义不变。不要为了消重把两个 public 类合并成一个带 kind 参数的 API（那是对外契约变更）。

## 优化可行性方案

本轮无带基线的优化方案：本模块没有运行期热路径——注册发生在动态库加载期（`ProbeRegistry.registerAgent` 的生产调用点只有 `fprobe/src/collect/ProbeFactory.cj:94-99` 与扩展 `static init`，其余均为测试），查表/快照发生在 `fprobe/src/runtime/AgentRuntime.cj:55` 的启动装配处，`AgentRuntime.kinds()` 也只在日志里取一次；`agents()` 的 `ArrayList` + `toArray` 分配量级为"每次调用几十个字符串引用"，既无输入规模也无修改前/后对照，按铁律不写成 CPU / 堆内存方案。

## 待验证假设

本轮无待验证假设。清单要求的是"缺性能数据的猜测"，而本模块既没有可测的循环/批处理，也没有任何 profile 或 bench 数据可补——注册表操作的调用次数由启动装配固定（1 次/进程），不存在"输入规模"维度可扫。若后续把注册表移到请求路径（例如按请求解析渠道名），再补 `cjprof record` 与调用频次统计。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_probe/README.md` | .md | ✅ | 错误码多写 `UNSUPPORTED`（#2）；扩展渠道承诺未实现（#1） |
| 2 | `f_probe/README_en.md` | .md | ✅ | 与中文版同构，同错（#2） |
| 3 | `f_probe/doc/contract.md` | .md | ✅ | 枚举摘录与源码一致；`:28` 非 object 分支描述不符（#5） |
| 4 | `f_probe/doc/extension-guide.md` | .md | ✅ | 版本 `1.3.17`（#3）、部署目录（#4）、渠道承诺（#1） |
| 5 | `f_probe/src/AlarmChannelRegistry.cj` | .cj | ✅ | 与 ProbeRegistry 同构（#6）；线程安全实现正确 |
| 6 | `f_probe/src/AlarmChannelRegistry_test.cj` | .cj | ✅ | 覆盖重名/枚举/24 线程并发；未见缺陷 |
| 7 | `f_probe/src/AlarmMessageChannel.cj` | .cj | ✅ | 默认 `sendRich` 退化为 `send`，与文档一致 |
| 8 | `f_probe/src/AlarmMessageChannel_test.cj` | .cj | ✅ | 断言退化后的 message/receiver；未见缺陷 |
| 9 | `f_probe/src/ExtensionExample_test.cj` | .cj | ✅ | 文档示例的可编译校验；会 `clear()` 全局注册表（测试内自洽） |
| 10 | `f_probe/src/ProbeAgent.cj` | .cj | ✅ | 接口与默认 `host` 实现正确 |
| 11 | `f_probe/src/ProbeAgent_test.cj` | .cj | ✅ | 覆盖默认 `host` 为空串 |
| 12 | `f_probe/src/ProbeException.cj` | .cj | ✅ | 四个错误码；`==` 手写实现完整（`Equatable` 自带 `!=` 默认实现） |
| 13 | `f_probe/src/ProbeException_test.cj` | .cj | ✅ | 四个错误码 + `BaseException` 可捕获语义 |
| 14 | `f_probe/src/ProbeRegistry.cj` | .cj | ✅ | 线程安全正确；与 #6 重复实现 |
| 15 | `f_probe/src/ProbeRegistry_test.cj` | .cj | ✅ | 覆盖重名保留首次工厂、24 线程并发、缺失返回 None |
| 16 | `f_probe/src/f_probe.cj` | .cj | ✅ | 仅包级文档注释（与 `f_svg/src/f_svg.cj` 同风格），无声明 |

合计：`.cj` 12 个 / `.md` 4 个 / 共 16 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 设计维度命中 #1（注册表契约与宿主接线不一致）；语言特性已核对 `Equatable` 默认 `!=`（std `core_package_interfaces.md:915-935`）、接口默认实现、`Mutex` + `synchronized` 用法，均正确；无外部输入、无注入面、无凭据 |
| §1 死代码 | 0 | 已机械过：`ProbeRegistry.cj:29-30`、`AlarmChannelRegistry.cj:28-29` 四个 `private static let` 均在同类内被读；顶层声明仅 6 个 `public`（ProbeAgent / AlarmMessageChannel / ProbeErrorCode / ProbeException / ProbeRegistry / AlarmChannelRegistry），全部对外可达，按硬原则一不判；无 `internal` / `protected` / 顶层 `let`；逐个 `return`/`throw`/`catch` 后无同层语句；12 个文件的 `import` 全部有使用（`ArrayList`/`HashMap`/`Mutex`/`JsonObject`/`BaseException`/unittest 宏） |
| §2 重复逻辑 | 1 | 命中 #6（两个注册表 4 组函数体一一对齐）。同文件内两两比对：`registerAgent`/`agents`/`agent`/`clear` 语义互不相同，无同文件重复；测试里的三个极简 `ProbeAgent` 实现（`RegistryProbeAgent`、`HostlessAgent`、`K8sProbeAgent`）按误报边界（测试准备代码）不计；跨文件字面量搜索 `"duplicate `、`JsonObject()`、`"probe_channel_` 未见应合并的重复 |
| §3 空实现 | 0 | `AlarmMessageChannel_test.cj:51` 与 `AlarmChannelRegistry_test.cj:87`、`ExtensionExample_test.cj:70` 的 `send` 空体是测试替身（有意 no-op，有注释语义）；生产代码无空函数体、无 `TODO`/`FIXME`、无 `catch {}`。真实"空转"归入 §14 的 #1，不重复计数 |
| §4 栈溢出 | 0 | 无递归：6 个生产类型共计 11 个方法 + 2 个接口默认实现，调用深度固定（注册表方法不回调业务代码；`agent()` 只返回闭包，不在此处执行）；`ProbeErrorCode.==` 的 `match` 是平坦的 4 个 case |
| §5 OOM | 0 | 无全量物化、无按报文长度预分配、无全局只增容器：注册表键数量 = 内置项 + 扩展项，由动态库数量决定，进程生命周期内只增但被 `DUPLICATE` 限制为"每种 kind 一条"，量级为个位数～几十 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据；调用点全部在启动装配（`AgentRuntime.cj:51-55`），无请求主路径，热点结论不成立，已按铁律不列为发现 |
| §6.2 大粒度锁 | 0 | 两把锁分别保护两个互不相关的 `HashMap`，临界区内只有 `contains`/`add`/`get`/遍历键，无 I/O、无日志、无业务回调；单次持有时长量级为纳秒～微秒，且只在启动期竞争 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get`（`spawn` 只出现在测试的 `concurrentRegistration`，先全部提交后统一 `get`，属于正确用法） |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `remove(at: 0)`、无循环内字符串拼接；`agents()` 的遍历是 O(n) 且 n 为注册项数 |
| §7 降堆内存方案 | 0 | 常驻内存 = 两个 `HashMap` 的键与闭包引用，量级同 §5；`clear()` 不还物理内存（`HashMap.clear` 语义），但注册表不经历反复增删，无稳态碎片问题 |
| §8 降 CPU 方案 | 0 | 无循环热点可降；#6 的合并只是可维护性收益，不改 CPU，故列在 §2 而非此处 |
| §9 local mode 可行性 | 0 | 函数内临时对象只有 `agents()`/`channels()` 的 `ArrayList` 与 `toArray`，生命周期跨 `return`（返回值逃逸），且调用次数为启动期 1 次，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 0 | 本轮读到的 11 个生产方法与 2 个接口默认实现，其边界与空值路径已核对：空 `HashMap` 上 `agents()` 返回空数组、`agent()` 返回 `None`、`getOrThrow()` 只在测试使用；异常路径 `synchronized` 内抛 `ProbeException` 不泄漏锁；`ProbeException` 两个构造器与 `f_base/src/BaseException.cj:44-57` 签名一致。唯一的存量契约缺口（#1）按 §14 计数，避免重复 |
| §12 并发安全与锁粒度 | 0 | 已列出共享点：`ProbeRegistry.factories`（`ProbeRegistry.cj:30`）与 `AlarmChannelRegistry.factories`（`AlarmChannelRegistry.cj:29`）是 `static` 可变状态，唯一同步手段是同文件的 `static let lock`，所有读写都在 `synchronized(lock)` 内（含读路径），无检查-然后-写入漏锁；`agent()` 返回的闭包在锁外执行（`fprobe/src/collect/ProbeFactory.cj:80-86` 的用法），临界区不含业务代码，即便 `Mutex` 按 std 文档为可重入（`sync_package_classes.md:8919-8931`）也不依赖该性质 |
| §13 文档与代码一致性 | 4 | 命中 #2（README 多写 `UNSUPPORTED`）、#3（依赖版本 `1.3.17`）、#4（部署目录）、#5（非 object 分支）；4 个 `.md` 的 API 签名、示例、中英对照已逐节比对：`doc/contract.md:87-126` 的注册表与异常声明与源码逐条一致，`README_en.md` 与 `README.md` 章节一一对应（只同步了同一处笔误） |
| §14 功能完备性与 README 覆盖 | 1 | 命中 #1（扩展告警渠道接线缺失）；README 覆盖方面：#2 的错误码写错计入 §13，其余 public 声明（`ProbeAgent` 三属性、`AlarmMessageChannel` 四方法、两个注册表各四方法、`ProbeException.code`）均能在 README 的主表或「其他公开 API」段检索到；未文档化的只有 `ProbeException(code,message,caused)` 构造器（`doc/contract.md:124` 有，README 未列），影响小，不单列 |
| 文件覆盖（§13 等） | 16/16 | 无缺文件；`.md` 与 `.cj` 均已逐行读完并做交叉核对 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 2 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

代码本身的质量是好的：6 个生产类型、约 300 行（含版权头与注释），职责收敛（只做契约 + 注册表 + 错误码），依赖只有 `f_base` / `f_data`，与 README 的"扩展方不必引入 RPC / 邮件 / TUI"承诺一致；两个注册表各用一把 `Mutex` 包住全部读写，没有漏锁或检查-然后-写入的竞态，测试覆盖了重名保留首次工厂、24 线程并发注册、`None` 查找与 `sendRich` 降级，属于本仓里少见的"契约模块测试比实现长"的写法。

风险集中在**契约与宿主的一致性**，而不是模块内部实现：唯一阻塞项是 #1——文档向第三方承诺了"注册告警渠道即可被宿主使用"，而 supervisor 侧既不加载 `custom/`，也从不实例化注册表里的渠道工厂，实现出来只会得到一条误导性的"已注册但未配置"日志。探针侧是通的（`ProbeFactory.instantiate` 确实走注册表），所以问题容易被"扩展能用"的假象盖住。这条要么在 fprobe 补齐接线，要么把三份文档的承诺收回，不能留在中间状态。

其余五条都是文档 / 可维护性可修项，建议本轮一并收掉：#2 的 `UNSUPPORTED` 会直接让扩展作者编译失败，#3 的 `1.3.17` 很可能让中心仓依赖解析失败（该版本早于本模块引入），这两条按"文档即对外契约"应当视为需要修的一般问题；#4、#5 是路径与措辞层面的轻微问题。#6 的注册表同构复制不构成缺陷，是否合并由维护者按"对外 API 不动"的前提决定。存量 6 条（严重 1 / 一般 2 / 轻微 3），是否纳入修复待用户决定。
