# f_version 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_version`（2 个源文件 + 2 个文档，共 4 个文件）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；无 diff，全部问题记「存量」）
- **审查重点**：正确性、死代码、重复逻辑、空实现、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [一般][存量] README 指认的发布命令不会改写 `Version`，版本号的两处真相在下次发版时会漂移

- **位置**：`f_version/README.md:17`（`README_en.md:17`；同段代码示例与注释在 `README.md:12-14` / `README_en.md:12-14`）
- **来源**：存量（快照模式无基线）。`git blame -L 12,17 -- f_version/README.md`：该句由 `2623bbfff2 2026-10-06` 写入，示例注释由 `4be871f2fd 2026-10-02` 起未改；此后从 1.3.9 到 1.3.2021 的十余次 `chore(release)` 只改 `f_version/src/FountainVersion.cj`（最近 `06ebb90ebf 2026-11-24`），`README.md` 最后一次修改停在 `2623bbfff2`，`README_en.md` 于 `b2d31d5cb 2026-10-07` 新增时照抄了同一句，版本示例从未随发版回改。
- **判据**：review-checklist §13（文档与实现不符）+ §14.1（承诺的发布行为不存在）
- **证据**：静态确定 —— 当前源码 `f_version/src/FountainVersion.cj:21-22` 已不存在 `fountain(x.y.z)` 字面量，`FountainVersion` 是由 `"fountain(" + Version + ")"` 拼接出来的常量。两个被点名的工具都只匹配字面量：
  - `fboot version`：`f_app/src/App.cj:398-401`，`Regex('fountain\((\d+\.)+\d+\)')` 与 `Regex('release-(\d+\.)+\d+')` 对当前文件均无匹配，`Version` 常量不被触碰；
  - `cangjie.sh`：`cangjie.sh:126`（`cangjie-hmos.sh:137` 同）的 `sed -E "s/fountain\([0-9]+\.[0-9]+\.[0-9]+\)/fountain($1)/g"` 同样只认 `fountain(...)` 字面量，对当前文件是空操作。
  仓内唯一会改写 `Version` 的是 `fboot pub`：`f_app/src/PublishCommand.cj:56-60` 用 `\d+\.\d+\.\d+` 对整文件替换，README 未提。
- **描述**：按 README 的指引执行 `fboot version 1.3.2022` 时，`f_app/src/App.cj:82-115` 会先递归把所有 `cjpm.toml` 的 `version` 改成新值并在 `:117-165` `git commit` / `git push`，而 `f_version/src/FountainVersion.cj:21-22` 仍是 `1.3.2021`。结果是「所有模块 cjpm.toml 是新版本、`f_version` 的 `Version` / `FountainVersion` 是旧版本」的漂移，直接违反 `fountain-baseline.md §1`（模块 version 必须与 fountain 版本对齐）。下游 `skills/fountain-add-dependency/scripts/fountain_lookup.py:76,131-134` 正是从 `Version` 常量解析依赖版本，漂移后会按旧版本号生成 `"fountain::f_*"` 依赖，拉到旧制品。
- **建议**：二选一，并中英同步：
  1. 改工具：`replaceVersion` 除 `fountain(...)` 外再改写 `Version = "..."`（更简单的做法是让 `Version` 成为唯一写入点，`FountainVersion` 保持派生）；
  2. 改文档：把 `fboot version x.y.z` / `cangjie.sh` 换成实际生效的 `fboot pub x.y.z`，并写明它同时改 `cjpm.toml` 与 `Version`。

### [一般][存量] `AppVersion` 用三个无同步的静态可变字段发布，`set` 无幂等也无「已设置」信号，读取方缓存后不会跟随

- **位置**：`f_version/src/AppVersion.cj:19-27`（共享路径的另一端在范围外：`f_log/src/base/LogPattern.cj:167,174`，由同文件 `:27-28` 的静态成员构造）
- **来源**：存量（`git blame -L 18,27 -- f_version/src/AppVersion.cj` → `4be871f2fd 2026-10-02`，纯换行符 / 包名迁移，逻辑未变；快照模式无基线）
- **判据**：review-checklist §12.1（共享可变状态无保护、发布 / 可见性）+ §11（契约与实现不符）
- **证据**：静态确定 —— `set`（`AppVersion.cj:23-27`）对 `banner_` / `name_` / `version_` 三个 `static var` 逐条赋值，无锁、无原子引用替换、无「已设置」标志，重复调用直接覆盖；「进程内只应调用一次」只写在 README，代码不校验。读取方会缓存：`AppLogPart` / `AppVersionLogPart` 在构造时把 `AppVersion.name` / `.version` 存入 `private let`（`f_log/src/base/LogPattern.cj:167,174`），而这两个对象是 `LogPattern` 的静态成员（`:27-28`）。
  待确认 —— `f_log` 包初始化与 `fboot build` 生成的 `<app>_stAtIc__` 模块初始化（`f_app/src/App.cj:408-413`，顶层 `private let _ = AppVersion.set(...)`）的先后顺序；这决定正常启动下 `%app` / `%appver` 是否为空。
- **描述**：三种后果，触发条件不同：
  1. 若 `f_log` 的静态 `LogPattern` 先于生成模块初始化，`%app` / `%appver` 会整进程保持空串，与 `f_version/README.md:36`「`%app`、`%appver` 就是从这三个属性取值」的承诺不符；
  2. 任何运行期二次 `set` 都只影响之后新建的读取对象，已缓存的日志部件与 `f_app` 已打印的启动行不会更新，属静默部分生效；
  3. 并发 `set` 与 `banner` / `name` / `version` 读取之间没有 happens-before 保障，可能读到「新 name + 旧 version」的组合（三个字段不是一次原子发布）。
  当前仓内唯一调用点是生成模块的包初始化，未发现运行期二次调用，因此不是现网故障；但契约对调用时机、线程与重复调用没有任何约束，模块也无法向调用方暴露「已设置」。
- **建议**：把三个字段收进一个不可变 `struct AppInfo` 后一次性赋值（或加 `isSet_` 守卫，重复 `set` 显式抛错 / 忽略并 warn），并在 README 写明「必须在任何读取方初始化之前、仅调用一次」；读取侧（`f_log`）改为渲染时取 getter，而不是构造时快照——该项属 f_log 范围，另案处理。

### [轻微][存量] README 示例版本仍是 `1.3.7`，且通篇按三段式 `x.y.z` 描述四段版本 `1.3.2021`

- **位置**：`f_version/README.md:13`（`README_en.md:13`），相关叙述在 `README.md:17` / `README_en.md:17`
- **来源**：存量（`git blame -L 13,13 -- f_version/README.md` → `2623bbfff2 2026-10-06`；`FountainVersion.cj:21` 由 `06ebb90ebf 2026-11-24` 更新为 `1.3.2021`）
- **判据**：review-checklist §13（文档过期：示例值 / 版本形态与实现不一致）
- **证据**：静态确定 —— `f_version/cjpm.toml:6` 与 `f_version/src/FountainVersion.cj:21` 都是 `1.3.2021`；README 示例写 `public const Version = "1.3.7"`，正文又用 `fboot version x.y.z` 的三段式口径。
- **描述**：读者会以为版本恒为三段，照抄示例会写成 `1.3.2022` 这类形式，与本仓库现有的 `1.3.2021` 及 `release-1.3.2021` 标签形态不一致；示例值过期也会让人误判当前版本。
- **建议**：示例改成 `public const Version = "1.3.2021"`（或写 `<当前版本>`），并把 `fboot version x.y.z` 改成实际接受的写法；若四段（`1.3.<build>`）是有意约定，在 README 里明确说明。中英同步。

**范围外提示**（不计入本模块统计）：`f_log/src/base/LogPattern.cj:167,174` 在构造时快照 `AppVersion`，建议 f_log 轮次确认正常启动下 `%app` / `%appver` 是否为空。

## 优化可行性方案

> 本模块只有 2 个 `.cj`（共 65 行）：常量、三个字符串 getter、一次 `MonoTime.now()`。无堆容器、无循环、无锁、无序列化、无 I/O，也没有函数内临时大对象，不构成 CPU / 堆内存 / local mode 优化对象。0 条方案。

## 待验证假设

> 本模块无可疑热点（无循环、无分配热点、无锁竞争路径），未采集也未提出性能假设。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| — | 无 | — | — | — |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_version/README.md` | .md | ✅ | 结构完整、覆盖全部 public 符号；发布命令与版本示例过期，见发现 #1 / #3 |
| 2 | `f_version/README_en.md` | .md | ✅ | 与中文版逐段对齐（45 行对 45 行），同 #1 / #3 |
| 3 | `f_version/src/AppVersion.cj` | .cj | ✅ | 版权头在 `package` 之前；静态可变状态契约缺失，见发现 #2；`private init` 为全仓静态命名空间惯例，非死代码 |
| 4 | `f_version/src/FountainVersion.cj` | .cj | ✅ | 版权头规范、`import std.time.MonoTime` 已使用；常量派生关系正确，见发现 #1 / #3 |

合计：`.cj` 2 个 / `.md` 2 个 / 共 4 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 正确性：常量派生关系正确、无边界计算；设计：模块只做「版本与启动时刻」的单一职责，无分层问题，唯一设计风险是可变全局状态（发现 #2）。语言特性：`struct` 承载静态成员、`const` 编译期拼接、`let` 包初始化求值均用法正确；`public const Version` 未写类型注解但可推断为 `String`，无隐患。可读性：命名与缩写一致（`banner_` / `name_` / `version_`）。安全性：不解析外部输入、无凭据、无日志输出，0 条。 |
| §1 死代码 | 0 | 逐个符号搜过：`banner_` / `name_` / `version_` 均被对应 getter 读取；`set` 的三个参数均被使用；`AppStarts` 被 `f_app/src/App.cj:56` 使用；`Version` 被 `FountainVersion.cj:22` 使用；`FountainVersion` 被 `f_app` / `f_log` / `f_dbd` 多处使用；`import std.time.MonoTime` 已使用；无 `return` 后置语句、无未读局部变量。`AppVersion.cj:22` 的 `private init(){}` 无调用者，但它是阻止全静态结构体被实例化的访问控制手段（同形惯例见 `f_base/src/Console.cj:23`、`f_http/src/MediaTypes.cj:27` 等 20 余处），删掉会改变可见性契约，不判死代码。其余 `public` 声明（`AppVersion` 及其 `set` + 3 个属性、`AppStarts`、`Version`、`FountainVersion`）均对外可达，不判死代码。 |
| §2 重复逻辑 | 0 | 已两两比对 3 个 getter 与 `set`、`FountainVersion` 两行常量：getter 逐行同构但输出字段不同，属静态命名空间的必要展开，不构成同语义实现；`.cj` 内无重复的错误消息 / 正则 / 字面量。版本号「两处真相」（`Version` 常量 vs 工具匹配的 `fountain(...)` 字面量，及两版 README 的手抄示例）跨文档 / 工具，已并入发现 #1 / #3，不另计。 |
| §3 空实现 | 0 | 无 `TODO` / `FIXME` / `throw UnsupportedException` / `catch {}`；`private init(){}` 与 `set` 均有实际语义，前者是全仓静态命名空间惯例，不是未完成实现；无接口默认空实现。 |
| §4 栈溢出 | 0 | 两个文件无递归、无自引用结构、无深度遍历；调用链深度固定（getter → 静态字段）。 |
| §5 OOM | 0 | 无容器、无预分配、无全量物化；仅 3 个常驻 `String` 引用与一次 `MonoTime.now()`，大小与输入无关。 |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof` / `cjpm bench` 数据；模块内无循环与 I/O，`set` 只在包初始化执行一次，不具备热点特征，不列待验证假设。 |
| §6.2 大粒度锁 | 0 | 无线程、无锁、无 `synchronized`；`set` 的单次持有时长概念不适用。 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 队列 / 批处理。 |
| §6.4 低效算法 | 0 | 无循环、无查找、无 `contains`、无循环内字符串拼接（`FountainVersion` 是编译期常量拼接）。 |
| §7 降堆内存方案 | 0 | 常驻对象只有 3 个 `String` 引用与 1 个 `MonoTime` 值，无生命周期可缩短、无副本可去、无缓存可淘汰，收益低于噪声。 |
| §8 降 CPU 方案 | 0 | 无计算、无序列化、无日志放大；getter 只返回字段，无可降复杂度。 |
| §9 local mode 可行性 | 0 | 函数内无临时大对象（`set` 只做三次赋值），无峰值内存收益可证明，不适用。 |
| §11 现有代码的 BUG（存量） | 1 | 已核对 `set` / 三个 getter 共 4 个函数与 2 处常量初始化的边界与空值路径：无越界、无除零、无 `Option` 丢弃；唯一问题是对「只调用一次」的契约没有校验、读取方缓存导致二次设置静默失效（发现 #2，同一根因）。 |
| §12 并发安全与锁粒度 | 1 | 共享路径已定位：`AppVersion` 的 3 个进程级 `static var` 由生成模块包初始化写入，由 `f_app` 启动路径与 `f_log` 的 `LogPart` 构造读取；无锁 / 无原子 / 无可见性信号（发现 #2）。锁粒度维度：本模块无锁，「去锁」无从谈起；不建议为此引入锁，优先用一次性发布 + 已设置标志。 |
| §13 文档与代码一致性 | 2 | 发现 #1（README 指认的 `fboot version` / `cangjie.sh` 改写路径对 `Version` 不生效）、发现 #3（示例版本与三段式口径过期）。其余段落核对一致：`AppStarts` 的求值时机与 `FountainVersion.cj:20` 相符；「未调用 `set` 时返回空字符串」与 `AppVersion.cj:19-21` 的初值相符；`%app` / `%appver` 的取值说明与 `f_log` 实现相符。两版 README 无译漏或结论相反。 |
| §14 功能完备性与 README 覆盖 | 1 | README 覆盖全部 4 个 `public` 符号（`Version` / `FountainVersion` / `AppVersion`（含 `set` 与 3 个属性）/ `AppStarts`），无未文档化的公开 API，根 `README.md:395-400` 已登记本模块；代码侧无半成品、无接线缺失。唯一「承诺未兑现」是发现 #1 的发布行为。`fountain::fountain.version` 门面（`src/version/version.cj:16-18`）由根 README 统一说明，模块 README 未重复，不作为缺口。 |
| 文件覆盖 | 4/4 | 4 个文件（2 `.cj` + 2 `.md`）全部读完，无遗漏、无跳过。 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 1 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 3 条（2 一般 + 1 轻微），是否纳入修复待用户决定。

## 总评

代码本体干净：`AppVersion.cj` 43 行、`FountainVersion.cj` 22 行，版权头与 `package` 顺序合规，没有死代码、重复实现、空实现、递归、容器增长或锁，`Version` → `FountainVersion` 的派生写法也比两份字面量更不容易漂移。README 结构完整、中英逐段对齐，4 个 public 符号全部有说明，属于本仓文档质量较好的一档。

风险集中在「单一真相」两处，都不在运行时计算逻辑里：

1. **发布链路（发现 #1，建议排期）**：README 把 `Version` 的写入归给 `fboot version` 与 `cangjie.sh`，但这两个工具只替换 `fountain(x.y.z)` 字面量，而源码早已改成拼接形式；下次按文档发版会得到「cjpm.toml 已升级、f_version 版本未变」的漂移，进而让 `fountain_lookup.py` 按旧版本解析依赖。这是本模块唯一会实际咬人的问题，修法很小（改一句正则或改文档口径）。
2. **状态发布（发现 #2，建议与 f_log 一起改）**：`AppVersion` 是三个无同步的静态可变字段，`set` 不校验重复调用，读取方（`f_log` 的 `LogPart`）在构造时快照；正常启动下 `%app` 是否有值取决于包初始化顺序，且运行期二次 `set` 会静默只生效一半。用「一次性不可变快照 + 已设置标志」即可收口，代价极低。

示例版本号过期（发现 #3）属文档维护，随手改即可。综合看：无阻塞级缺陷，代码质量良好；建议下次发版前先修 #1，避免版本漂移进入发布提交。
