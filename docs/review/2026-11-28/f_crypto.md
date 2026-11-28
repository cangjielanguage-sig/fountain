# f_crypto 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_crypto`（1 个源文件 `.cj` + 2 个 `.md`，共 3 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；`git status f_crypto` 干净，`f_crypto/src/crypto.cj` 最后改动为 `4be871f2f chore: 统一换行符`），故所有问题来源均记「存量」
- **审查重点**：加密实现正确性、死代码、空实现、资源与内存、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [一般][存量] 多个 `GlobalCryptoKit` bean 静默覆盖，最终生效者由 `HashMap` 迭代顺序决定

- **位置**：`f_crypto/src/crypto.cj:26-30`（默认 `postConstruct` 无条件 `setGlobalCryptoKit(this)`）；`f_crypto/README.md:35`（把该行为写成规范）
- **来源**：存量（工作区快照无 diff；`git log -S "setGlobalCryptoKit" -- f_crypto/src/crypto.cj` 命中 `1a35aa8aa feat(f_mvc): 添加TLS证书验证功能支持`，不在本轮 diff 内）
- **判据**：review-checklist §12.1（共享可变状态无保护、缺检查-然后-写入）；`fountain-baseline.md` §4（多实现/同名注册应启动直接失败，不做隐式优先级）
- **证据**：静态确定 —— `f_bean/src/BeanFactory.cj:41` 的 bean 注册表是 `private let beans = HashMap<String, BeanManager>()`，启动初始化 `BeanFactory.cj:195-202` 按该 Map 的迭代顺序逐个 `initIfNeed()`；`f_bean/src/BeanManager.cj:77-86` 在 `new()` 里调用 `x.postConstruct()`；而 `GlobalCryptoKit.postConstruct` 的实现只有一句 `setGlobalCryptoKit(this)`，stdx 侧是 `var globalCryptoKit: ?CryptoKit` 的直接赋值（`cangjie_stdx/src/stdx/crypto/common/crypto_kit.cj:25-29`）。全链路没有任何「已注册过」的检查，也没有多实现检测。
- **描述**：同时存在两个 `GlobalCryptoKit` bean 时，全局 kit 由启动期初始化顺序决定，而该顺序来自 `HashMap` 的哈希顺序，与声明顺序、`@Bean(order: ...)`、配置都无关。使用者无法从代码判断哪个实现生效；如果是「测试用宽松 kit + 生产 kit」被同一 classpath 扫到，会静默用错加密套件。README 第 35 行把「最后完成 postConstruct 的那个生效」当作规范描述，进一步掩盖了非确定性。
- **建议**：在 f_crypto 侧维护「当前 kit 来源」状态，`postConstruct` 若发现全局 kit 已被非默认实现占用则抛异常（对齐 baseline §4「启动直接失败」）；或改为条件化 `@Bean` + 调用点 `lookupOption<...>` 显式选择，并在 README 删除「最后一个生效」的表述。

### [一般][存量] `lazy` 的 `GlobalCryptoKit` bean 会把「启动期注册」变成运行期改写，且写入是非原子全局变量

- **位置**：`f_crypto/src/crypto.cj:27-29`（注册发生在 bean 自己的 `postConstruct`）、`f_crypto/src/crypto.cj:32-34`
- **来源**：存量（快照）
- **判据**：review-checklist §12.1（可见性 / 数据竞争 / 发布逸出）；§3（契约承诺的时机与实现不符）
- **证据**：静态确定（代码路径）+ 待确认（下游是否真的声明了 `lazy`）。`f_bean/src/BeanManager.cj:69-76` 的 `initIfNeed()` 只对 `!meta.lazy` 的单例生效，`lazy` bean 要到首次 `lookup` 才 `new()`（同文件 `bean` 属性 `:98-110`，加锁粒度是**每个 bean 自己的 mutex**，不同 bean 之间不互斥）；`new()` 的顺序是「先 `postConstruct()`，再 `store`」（`:77-86`）。stdx 的全局 kit 是普通 `var`（`cangjie_stdx/src/stdx/crypto/common/crypto_kit.cj:25`），无原子、无锁、无可见性保证；读侧在请求主路径上（`f_mvc/src/MVCConfig.cj:71-74` 每请求 `getGlobalCryptoKit()`）。
- **描述**：一旦某个 `GlobalCryptoKit` bean 标了 `lazy`，全局 kit 就可能在任意请求线程里被改写：该线程创建 bean 时写 `globalCryptoKit`，其它线程同时在 `getGlobalCryptoKit()`，构成对同一普通全局变量的并发读写。此外 `postConstruct` 把 `this` 交给全局注册表时，bean 尚未 `store` 完成生命周期登记（发布逸出），其它线程可能拿到一个还没走完初始化流程的实例。后果是同一进程内前后两个请求使用不同 kit，且存在数据竞争。
- **建议**：把「注册全局 kit」从 `postConstruct` 挪到 bean 生命周期完成之后（f_bean 增加 `AfterInit` 类钩子，或在 `initBeansIfNeed()` 全部完成后统一注册）；至少在 fboot/f_mvc 启动期扫描 bean 元数据，发现 `lazy` 的 `GlobalCryptoKit` 直接失败，并在 README 写明「`GlobalCryptoKit` bean 不得 `lazy`」。

### [轻微][存量] 模块级初始化块与 stdx `DefaultCryptoKit` 的 `static init` 重复

- **位置**：`f_crypto/src/crypto.cj:32-34`；对照 `cangjie_stdx/src/stdx/crypto/kit/default_crypto_kit.cj:17-19`
- **来源**：存量（快照）
- **判据**：review-checklist §2（同语义两处实现，换形式不换行为）
- **证据**：静态确定 —— stdx 的 `DefaultCryptoKit` 自带 `static init() { setGlobalCryptoKit(DefaultCryptoKit()) }`；仓颉文档说明静态初始化器在控制流首次进入仓颉代码前全部完成（`cangjie_docs/docs/dev-guide/source_zh_cn/multiplatform/cangjie-android-Java.md:1720`），而 `f_crypto` 在 `crypto.cj:19` 已 `public import stdx.crypto.kit.*`，所以进入本模块 init 时全局 kit 已经是同一个默认实现。
- **描述**：两处做的事完全相同，本模块只是多构造一个 `DefaultCryptoKit` 并再覆盖一次。它使 f_crypto 的默认行为与 stdx 版本耦合：stdx 若更换默认实现，本块会把它悄悄改回去，且现场无注释说明这是有意兜底。
- **建议**：二选一——删除本块、README 改为「默认注册来自 `stdx.crypto.kit`」；或保留并加注释「防 stdx 版本差异的兜底」，同时在 README 说明覆盖来源，避免读者以为是 f_crypto 提供的保证。

### [轻微][存量] 公开声明无文档注释，接口排版与仓库风格不一致

- **位置**：`f_crypto/src/crypto.cj:23`、`f_crypto/src/crypto.cj:26-30`
- **来源**：存量（快照）
- **判据**：review-checklist §10（可读性 / 可维护性）、§14.2（公开 API 文档）
- **证据**：静态确定 —— 两个 `public interface` 都没有 `/** */` 注释；`public interface CertificateVerifier{` 大括号前缺空格；三个顶层声明之间无空行。README.md:40-45 已有现成注释文本，但没回写到源码。
- **建议**：把 README 中的注释搬到源码作为 doc comment（`GlobalCryptoKit` 补「默认实现会覆盖全局 kit」的说明），`CertificateVerifier {` 补空格并加空行分隔。

### [轻微][存量] README 示例缺少 import，`f_bean` 也未随 `public import` 转出

- **位置**：`f_crypto/README.md:28-33`、`f_crypto/README_en.md:28-33`
- **来源**：存量（快照）
- **判据**：review-checklist §13（示例代码不能用）
- **证据**：静态确定 —— 示例用 `@Bean` 声明类，但整段没有任何 `import`；本模块只对两个 stdx 包做了 `public import`（`crypto.cj:18-19`），`f_bean` 是默认（private）导入（`crypto.cj:21`），下游拿不到 `@Bean` / `PostConstruct`。
- **描述**：照抄示例会在 `@Bean` 处编译失败；另外 `GlobalCryptoKit` 的父接口 `PostConstruct` 来自未转出的 `f_bean` 包，实现者必须自行加该依赖，README 完全没提。
- **建议**：示例补 `import fountain::f_bean.*`；「全局CryptoKit」段落加一句「下游需依赖 `fountain::f_bean`」。

### [轻微][存量] README 未说明 `CertificateVerifier.verify` 的入参语义与失败处理

- **位置**：`f_crypto/README.md:43-48`、`f_crypto/README_en.md:43-48`
- **来源**：存量（快照）
- **判据**：review-checklist §14.2（缺注意事项）、§13（契约描述不足）
- **证据**：静态确定（缺失本身）—— 接口只有 `func verify(certificate: Array<Certificate>): Bool`（`crypto.cj:24`），README 未说明数组是整条链还是单证书、元素顺序、空链应返回什么、抛异常是否等同拒绝；`f_mvc/src/MVCConfig.cj:105-106` 直接 `CustomVerify(verifier.verify)` 转交，语义全部留给实现者猜。stdx 侧实际传入的内容需按 `CertificateVerifyMode.CustomVerify` 文档确认（本轮未取证）。
- **建议**：补一段：`certificate` 的内容与顺序以 stdx `CustomVerify` 为准、空链不得返回 `true`、异常按验证失败处理；并给一个返回「按 CN 白名单校验」的最小实现示例。

## 优化可行性方案

> 本模块是纯转出 + 两个接口定义，唯一的运行期对象是模块级 `DefaultCryptoKit()` 单例，没有循环、容器、缓存或序列化路径，**不存在有数据支撑的堆内存 / CPU 优化项**。`docs/LocalMode.md:472` 也已给出「只有接口 + `DefaultCryptoKit`，实现在 stdx；不做」的结论。不加无基线收益的条目。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 全局 kit 读取在每请求路径上的开销可忽略（`lookupOption<CryptoKit>() ?? getGlobalCryptoKit()` 每请求一次） | `f_mvc/src/MVCConfig.cj:71-74`（本模块导出能力的消费点） | 单次耗时与调用频次占比 | `cjprof record` 跑 TLS 请求压测，取 `MVCConfig.cryptoKit` 自耗时占比 |
| 2 | 模块加载期构造 `DefaultCryptoKit()`（含 `SecureRandom` 等）对启动耗时贡献可忽略 | `f_crypto/src/crypto.cj:33` | 启动阶段分段计时 | 在 fboot 启动日志里加模块 init 前后时间戳，多轮取中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_crypto/README.md` | .md | ✅ | 与实现基本一致；示例缺 import、`verify` 语义缺失两条见「发现」对应轻微条目；「最后 postConstruct 生效」表述见第一条一般条目 |
| 2 | `f_crypto/README_en.md` | .md | ✅ | 与 `README.md` 章节、示例、结论逐段对照一致（4 节结构相同），存在同样两处问题 |
| 3 | `f_crypto/src/crypto.cj` | .cj | ✅ | 34 行全文；两接口 + 一处模块级初始化；问题见 4 条实现侧发现 |

合计：`.cj` 1 个 / `.md` 2 个 / 共 3 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 0：无运算/分支/资源路径；设计 2（多实现选择机制、注册时机）；可读性 1（无 doc comment / 排版）；语言特性 0（`public import` 重导出用法与 `package/import.md:287-336` 一致）；安全性 0（无凭据、无外部输入、默认实现取 stdx 安全默认） |
| §1 死代码 | 0 | 逐个核对：`CertificateVerifier`、`CertificateVerifier.verify`、`GlobalCryptoKit` 均为对外可达 `public`（顶层 `public interface`），且 `verify` 被 `f_mvc/src/MVCConfig.cj:105` 使用、`postConstruct` 由 `f_bean/src/BeanManager.cj:79-80` 经接口调用、`GlobalCryptoKit` 被 `f_mvc/src/MVCConfig.cj:69` 使用；`private let _`（`crypto.cj:32`）形似「读了不用」，但它是模块级初始化器、执行期由包加载触发，不是死代码（其重复性结论见「模块级初始化与 stdx 重复」条目）。全仓搜索：`grep -rn "GlobalCryptoKit\|CertificateVerifier"` 命中仅本模块 + f_mvc + f_crypto README |
| §2 重复逻辑 | 1 | 同文件只有一个初始化表达式，无可两两比对函数体；跨文件比对发现 `crypto.cj:32-34` 与 `cangjie_stdx/src/stdx/crypto/kit/default_crypto_kit.cj:17-19` 语义相同（见「模块级初始化与 stdx 重复」条目） |
| §3 空实现 | 0 | 两个接口的 `verify` 是抽象方法（无默认体，README 明说「只定义契约」）；`GlobalCryptoKit.postConstruct` 默认实现有实际副作用；无 `TODO` / `catch {}` / `return None` |
| §4 栈溢出 | 0 | 无函数递归、无递归数据结构、无深拷贝；仅一个无参 lambda 立即调用 |
| §5 OOM | 0 | 无常量容器、无按输入预分配、无缓存；唯一长期对象是 1 个 `DefaultCryptoKit` 单例 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点不成立；两条线索降级进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本模块无锁、无临界区 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无任务队列 |
| §6.4 低效算法 | 0 | 无循环、无查找、无字符串拼接 |
| §7 降堆内存方案 | 0 | 无可缩短生命周期/可去副本的对象（见「优化可行性方案」说明） |
| §8 降 CPU 方案 | 0 | 同上；读取路径在本模块之外（f_mvc） |
| §9 local mode 可行性 | 0 | 本模块无函数内临时对象；`docs/LocalMode.md:472` 已判定「不做」，`docs/LocalMode.md:336` 亦标注 crypto 属 stdx/FFI 路径不受 local region 影响 |
| §11 现有代码的 BUG（存量） | 2 | 已核对 34 行全部语句：2 个接口 + 1 个初始化表达式，无越界/空值/错误处理/资源释放面；命中的是全局状态注册语义（两条一般条目） |
| §12 并发安全与锁粒度 | 1 | 共享路径明确：stdx `globalCryptoKit` 普通 `var`（`crypto_kit.cj:25`）被 bean `postConstruct` 写、被 `getGlobalCryptoKit()` 读；无锁/无原子/无可见性手段（见「懒加载 GlobalCryptoKit」条目）。锁粒度无从谈起（本模块无锁） |
| §14 功能完备性与 README 覆盖 | 2 | 已用 `src/` 公开声明（`CertificateVerifier`、`GlobalCryptoKit`）与 README 逐项对照：两者均有章节、重导出的 stdx 包有说明、示例 API `certificateFromPem` 存在于 `CryptoKit`（`crypto_kit.cj:22`）；缺的是示例 import 与 `verify` 语义（两条 README 轻微条目）。模块已在根 `cjpm.toml:13` 与根 `README.md:197-202` 登记，无索引缺失 |
| 文件覆盖（§13 等） | 3/3 | 无缺读文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

f_crypto 只有 34 行：两个接口（`GlobalCryptoKit`、`CertificateVerifier`）+ 一处把 stdx 加密套件设为全局默认值的模块级初始化。**没有加密算法实现**，全部落在 stdx，因此本模块不承担算法正确性风险；也没有循环、容器、锁、I/O、递归，§4–§9 全部为 0，无死代码、无空实现。

真正需要决策的是「全局 CryptoKit 的选取机制」：当前是「谁最后 `postConstruct` 谁赢」，生效者取决于 `HashMap` 迭代顺序，与 fountain 基线 §4「多实现应启动失败、不做隐式优先级」相反；而且一旦 bean 标 `lazy`，注册时点会漂移到任意请求线程，而存储侧是普通 `var`，与并发读构成数据竞争。这两条是唯一的实质风险，建议排期修（改成一个启动期校验 + 显式选择，而不是在 README 里把非确定性写成规范）。

其余四条是文档/风格问题：模块初始化块与 stdx 默认注册重复、公开接口无 doc comment、README 示例缺 `import fountain::f_bean.*`（`@Bean` 无法解析）、`CertificateVerifier.verify` 的入参语义没写。均可随手修，不阻塞。

范围外提示：`f_mvc/src/MVCConfig.cj:68-70` 的 `static init()` 里 `lookupOption<GlobalCryptoKit>()` 只为触发 bean 初始化而丢弃返回值，同样依赖「先注册后使用」的时序假设，与本模块「懒加载 GlobalCryptoKit」条目同源，建议在 f_mvc 轮次一并评估。

存量缺陷共 6 条（2 一般 + 4 轻微），是否纳入修复待用户决定；本报告不改源码，未跑构建。
