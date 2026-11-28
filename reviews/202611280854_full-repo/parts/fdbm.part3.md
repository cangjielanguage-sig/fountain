# fdbm 模块审查报告（第 3/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fdbm/src/config`、`fdbm/src/exception`、`fdbm/src/execute`（本部分清单 12 个文件，全部 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题记「存量」
- **审查重点**：多数据源与连接生命周期、启动期装配、并发安全、死代码、重复逻辑（本部分实际落在「配置解析 / boot.sh 落盘 / 启动自检」上）
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `fdbm_v2.md`）

## 发现

### [严重][存量] EXPORT 的键空间无上限：`pending` 与 boot.sh 无界增长，且每次 `flush` 全量重写（O(N²)）

- **位置**：`fdbm/src/config/BootScriptWriter.cj:91`（`set` 累积 `pending`）、`fdbm/src/config/BootScriptWriter.cj:109`（`flushLocked` 全量读→全量写）、`fdbm/src/config/BootScriptWriter.cj:485`（`isWritableKey` 前缀白名单）
- **来源**：存量（快照模式无基线；`git blame` 显示 `set`/`pending` 写于 `c81e5dcc2a`(2026-10-18) 与 `81084fb094`(2026-10-21)，早于本次快照 `120fd2542`）
- **判据**：review-checklist §5（无界容器 / 按不可信输入增长）、§14.1（无配额、无拒绝路径）
- **证据**：静态确定 —— `isWritableKey` 只做前缀匹配（`fdbm_db_driver_` / `fdbm_db_database_` / `fdbm_db_username_` / `fdbm_db_password_` / `fdbm_db_logicalDatabase_` / `fdbm_databasePool*` / `fdbm_loadbalance_weight_` / `fdbm_partition__` / `fdbm_partition_substr__` / `fdbm_global__`），后缀是任意长度任意内容；`pending[key] = value`（:98）之后再无删除路径（`flush` 只合并不清理）；`ExportExecutor`（`fdbm/src/execute/executors.cj:1231`）对每条 EXPORT 都执行 `set` + `flush`，全链路无 key 数量、文件大小或频率限制。
- **描述**：`EXPORT` 是协议可达的普通 SQL（设计 §8.1 表格第 `EXPORT <key>=<value>` 行），任何能发 SQL 的客户端都能用不同后缀无限追加键。每追加一个键：① 进程内 `pending` 永久多一条；② boot.sh 多两行；③ 下一次 `flush` 重新读入整个文件、重建整个块、回写整个文件。N 次 EXPORT 的累计 I/O 与 CPU 为 O(N²)，文件与内存随 N 线性增长，没有任何拒绝路径（到 OOM / 磁盘满才终止）。这与「配置项数量由部署决定」的实际语义不符——白名单只是前缀，不是有限集合。
- **建议**：把可写键收敛为「有限集合 + 已配置实体」：`fdbm_db_*_<node>` 的 `<node>` 必须出现在 `fdbm_db` 里、`fdbm_partition__<table>` / `fdbm_global__<table>` 必须是已存在的表名、`fdbm_databasePool` 只接受 §3.4 列出的 12 个后缀；同时对 `pending` 条数与 boot.sh 大小设上限（超额抛 `CONFIG`）。

### [一般][存量] EXPORT 只校验键名不校验值：非法值会持久化，下次启动直接 CONFIG 失败

- **位置**：`fdbm/src/config/BootScriptWriter.cj:91`（仅 `isWritableKey(key)`，值原样 `shellQuote` 落盘）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（半接线：写入侧有校验、读取侧才有语义校验）、§11（契约与实现不符）
- **证据**：静态确定 —— `set` 只判键名；`ExportStatement.value` 来自单个 token（`fdbm/src/sql/SqlParser.cj:584`，`Text`/`Ident`/`Number` 三选一，原样取 `token.text`），可自由携带 `'a,bogus,c'`、`'abc'`、`'garbage'`；`FdbmSettings.load` 在下次启动会经 `FdbmConfig.get*` 重新解析并抛 `FdbmException(CONFIG)`（如 `fdbm_partition__x` 算法名非法 → `PARTITION_CONFIG`，`fdbm_port=abc` → `CONFIG`）。
- **描述**：运行期 `EXPORT fdbm_partition__t 'a,bogus,c'` 会成功返回（`Config.set` 立即生效、脚本已改），但这条规则不会参与本轮启动的路由构建，只会在**下一次启动**让进程起不来。运维视角是「昨天成功的一条 SQL 让今天服务无法启动」，且错误位置离操作现场很远。
- **建议**：落盘前用「键 → 解析器」映射做一次试解析（可用 `MapConfigSource` 构造单键源后调对应 `FdbmConfig.get*` / `validate*`），非法值直接回 `CONFIG`，与读取侧共用同一套校验，避免写入侧与读取侧规则漂移。

### [一般][存量] `normalize()` 的缩进判定与设计不符：tab 缩进的顶层 export 会被迁出函数，无区块时插入点可能落在函数体内

- **位置**：`fdbm/src/config/BootScriptWriter.cj:377`（只判 `!lines[i].startsWith(' ')`）、`fdbm/src/config/BootScriptWriter.cj:421`（无区块时按 `startsWith('export fdbm_')` 找插入点，完全不判缩进）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§13（`doc/详细设计.md:295`「只整理脚本中已有的顶层（行首无缩进）`export fdbm_*` 行……缩进在其他函数/条件里的 `export` 原样保留」）
- **证据**：静态确定 —— ①`'\texport fdbm_port=1'` 的 `startsWith(' ')` 为 false，会被当成顶层行迁走并从原位置删除，函数体里少一条 export；②无 managed 区块时，插入点只搜 `outside[i].startsWith('export fdbm_')`（:424），若第一条这类行是 `    export fdbm_port=1`（缩进在函数内，仓库自带的 `fdbm/boot.sh:127` 就有这种形态的 `export LD_LIBRARY_PATH`），新区块会被整段插进函数体。
- **描述**：`normalize()` 在每次 `FdbmServer.start()` 都会跑（`fdbm/src/server/FdbmServer.cj:230`），失败不阻塞启动、也不报错，所以脚本结构被改坏是静默的。判据两处用了两套缩进口径（一处只排空格、一处完全不判），同一份脚本可能同时踩到「迁多了」和「插错位置」。
- **建议**：抽一个 `isTopLevel(line)` 判定（`line` 首字符不是空格 / tab 且不以 `#` 开头），迁移与插入点搜索共用；插入点搜索只认 `isTopLevel && startsWith('export fdbm_')`，找不到就追加到文件末尾。

### [一般][存量] `parseBlock` 把任意 `export ` 行当作块内容：END 标记缺失时，块后无关 export 被静默删除

- **位置**：`fdbm/src/config/BootScriptWriter.cj:330`（`if (trimmed.startsWith('export ')) { if (let Some(...) = parseExport(...)) {...}; end += 1; continue }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 数据丢失）、§3（失败路径当成功）
- **证据**：静态确定 —— 循环只在命中 `END_MARKER`（:322）或遇到既非空行、非注释、非 `export ` 的行（:337）时结束；`parseExport` 对非 `fdbm_` 键返回 `None` 后**仍然** `end += 1` 把它们吞进块区间。`flushLocked`（:133）与 `normalizeText`（:401）随后用 `[start, end)` 整段替换 ⇒ 这些行被丢弃。
- **描述**：正常形态下块内有 END 标记，行为符合「区块由 fdbm 独占」。但一旦 END 标记缺失（手工编辑、旧格式只带起始标记、写入被截断），块区间会一路吃掉紧随其后的 `export logger_appender_console=...`、`export protocol_hostId=...`（仓库自带 `fdbm/boot.sh:98/108` 就是这种紧邻形态）这类**非 fdbm 的 export**，直到第一条非 export 语句为止。这些行既不在 managed 块内、也不属于 fdbm，删除前只字未提（无 WARN）。
- **建议**：`export ` 分支里先判 `key.startsWith('fdbm_')`，非 fdbm 行直接 `break`（保留在原地）；END 标记缺失时额外记一条 WARN 说明「块未闭合，按首个非 fdbm export 截断」，避免静默吞行。

### [一般][存量] 重写 boot.sh 只复制可执行位：原始权限位丢失，内含明文 `fdbm_db_password_*` 的脚本可能被放宽为组/其他可读

- **位置**：`fdbm/src/config/BootScriptWriter.cj:460`（`writeAtomically`，仅 :466 `canExecute()` + :467 `setExecutable(true)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（安全性 / 资源不对称）、§13（`doc/详细设计.md:287` 仍写「复制原文件权限位」，代码注释 :456 却称「已在详细设计登记」，设计里查不到该偏差）
- **证据**：静态确定（只搬可执行位，代码注释与设计文本自认）；最终 mode 待确认 —— 缺 `std.fs` 的默认创建权限与 umask 实测数据，无法断言具体数值。
- **描述**：临时文件由 `File.writeTo` 新建后仅 `setExecutable(true)`，再 `rename` 覆盖原文件。原脚本若是 `0600` / `0640`（部署时保护 `fdbm_db_password_name0` 的常见做法），重写后变成「默认创建权限 + 可执行位」，通常即 `0755`/`0644`，等于把明文凭据从「仅属主可读」放宽到「同机其他用户可读」。触发点有两条：启动期 `normalize()`（每次启动都跑）与任意一次 `EXPORT`。测试 `flushKeepsExecutableBit`（`BootScriptWriter_test.cj:219`）只断言可执行位，覆盖不到这条。
- **建议**：`rename` 前把原文件的完整权限位补到临时文件（`std.fs` 若无等价 API，至少显式 `setReadable/ setWritable` 到「属主读写、其他不读」并记一条 WARN）；同时把设计 §3.5 第 6 条改成实际行为，或按设计补齐实现。测试补一条「原文件 0600，flush 后仍不可被其他用户读」。

### [一般][存量] 连接池参数缺少下界校验：负数直接传给 `f_pool`，与同文件其它数值项的校验口径不一致

- **位置**：`fdbm/src/config/FdbmConfig.cj:97`（`getPool` 的 12 个参数全部走 `intOf`）、`fdbm/src/config/FdbmConfig.cj:658`（`maxWaitingOf` 把 `<= 0` 一律当无限等待）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺少边界校验）、§10（错误处理）
- **证据**：静态确定（无任何范围检查）；后果待确认 —— `f_pool` 的 `Pool` 构造（`f_pool/src/Pool.cj:141`）也未校验 `minSize/maxSize`，负 `maxSize` 具体表现（永久借不到连接 / 立即抛错 / 静默死锁）需实测。
- **描述**：`fdbm_partition_step`（:140）与 `fdbm_cache_size`（:286）都做了正值/非负校验，但池参数完全没有：`fdbm_databasePoolMaxSize=-1`、`InitSize=-5`、`ConnectTimeout=-1` 都会被接受并传入连接池；`MaxWaiting=-1` 又被 `maxWaitingOf` 静默当成「无限等待」，把一处配置笔误变成「池耗尽即永久阻塞」。
- **建议**：在 `getPool` 里补一组校验（`InitSize/MinSize/MaxSize >= 0`、`MinSize <= MaxSize`、`ConnectTimeout > 0`、`MaxWaiting >= 0` 且 `-1` 不接受），失败抛 `CONFIG` 并带键名与原值；`maxWaitingOf` 只对 `0` 特判为无限。

### [轻微][存量] 死代码：`FdbmConfig.getLogicalDatabases` 全仓无引用

- **位置**：`fdbm/src/config/FdbmConfig.cj:149`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`internal`/默认可见性符号，本包及子包内无调用者）
- **证据**：静态确定 —— 排除 `.worktrees` 后全仓 `grep -F "getLogicalDatabases"` 仅命中定义行；`FdbmSettings` 的 `logicalDatabases` 字段实际由 `catalog.toMap()` 填充（`fdbm/src/config/settings.cj:63`），设计 §3.2 的 `FdbmConfig` 成员表也没有它。
- **描述**：遗留的便捷封装，已被 `settings.cj` 的写法取代；保留会让人误以为存在第二条装载路径（它会用空 `partitions` 重建 catalog，语义与 `load()` 不同）。
- **建议**：删除；若要保留，改成 `catalog.toMap()` 的直通并在设计 §3.2 登记。

### [轻微][存量] 恒假/不可达分支三处

- **位置**：`fdbm/src/config/FdbmConfig.cj:631`（`durationOf` 的 `seconds: false` 分支）、`fdbm/src/config/FdbmConfig.cj:225`（`getIdMaker` 的 `parts.size == 0`）、`fdbm/src/config/FdbmConfig.cj:469`（`!catalog.contains(rule.database)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒真恒假分支）
- **证据**：静态确定 —— ①`durationOf` 的 3 个调用点（:306/:310/:318）全部传 `seconds: true`，毫秒分支永不执行；②`String.split` 至少返回 1 个元素，`parts.size == 0` 不可能成立；③`LogicalCatalog.of` 在 :75 对每条规则执行 `ensure(mapping, rule.database, all)`，而 `confs.catalog` 就是由同一份 `confs.partitions` 构建的（`settings.cj:82`），故该 `contains` 对 `load()` 产出的 settings 恒为 true（`FdbmSettings` 构造器是 `private`，没有第二条构造路径）。
- **描述**：三处都不会被触发，但都保留了「有分支」的假象：`seconds` 参数实际是常量、`catalog.contains` 看起来在校验分库规则的库名而实际不校验（未知库名被隐式展开为全部物理库，这是设计 §3.1 的既定行为，不是缺陷）。
- **建议**：`durationOf` 去掉 `seconds` 参数（或补一个真正使用毫秒的调用点/用例）；`getIdMaker` 简化为 `let kind = parts[0].trimAscii().toLower()`；`validatePartitions` 删掉这条永假校验并在注释里写明「分库规则的库名为隐式展开」。

### [轻微][存量] 未使用的 import：`fountain::f_data.DataParsable`

- **位置**：`fdbm/src/config/FdbmConfig.cj:21`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 该文件对 `DataParsable` 的命中只有 import 行本身（`grep -n DataParsable` 仅 1 行）；`tryParse` 由 `std.convert.*` 提供。
- **描述**：多余的编译期依赖，会让 `f_data` 的变更无谓牵动本文件。
- **建议**：删除该 import。

### [轻微][存量] 重复逻辑：同语义的解析/去重/包含/排序/默认值各写两份

- **位置**：
  - `FdbmConfig.splitNonEmpty`（`fdbm/src/config/FdbmConfig.cj:808`）≡ `LogicalCatalog.splitValue`（`fdbm/src/config/catalog.cj:138`）：都是「按 `,` 切、trim、丢空、全空则抛」，错误文案逐字相同
  - `FdbmConfig.containsName`（`FdbmConfig.cj:558`）≡ `FdbmConfig.isSubstrHash`（`FdbmConfig.cj:799`）：同样的线性查找，且都在重复 `Array.contains`
  - `BootScriptWriter.sortedByKey`（`BootScriptWriter.cj:530`）≡ `LogicalCatalog.sortInPlace`（`catalog.cj:184`）：逐行对齐的插入排序，只差元素类型
  - `LogicalCatalog.dedup`（`catalog.cj:152`）与 `sortedPhysicals`（`catalog.cj:163`）内联的 `seen.add` 去重环：同一去重语义两份
  - `FdbmConfig.getPool` 的 12 个默认值（`FdbmConfig.cj:99`）≡ `PoolConfig` 构造器默认值（`fdbm/src/config/models.cj:69`）：同一张字面量表两份
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：只改类型名 / 字面量复制）
- **证据**：静态确定（逐函数体摘要比对：输入→输出→副作用一致，无语义差异）
- **描述**：目前两两行为一致，但任何一次单边修改都会造成漂移：例如改了 `splitNonEmpty` 的错误文案，`splitValue` 不会跟；改了池默认值，`getPool` 与 `PoolConfig()` 会给出两个「默认值」。
- **建议**：`splitValue` 收敛到 `FdbmConfig.splitNonEmpty`（catalog 依赖 config 会形成环，正确落点是把该工具提到 `config` 包内的一个 `internal func`，两处共用）；`containsName`/`isSubstrHash` 直接用 `Array.contains`；两处插入排序换成 `std.sort`（见「优化可行性方案」）；池默认值只保留 `PoolConfig` 一份，`getPool` 用 `PoolConfig()` 取值作 fallback。

### [轻微][存量] 近似重复＋行为漂移：`durationOf` 与 `durationValue` 对裸数字的态度不同

- **位置**：`fdbm/src/config/FdbmConfig.cj:619`（`durationOf`，接受裸数字，`seconds` 决定单位）vs `fdbm/src/config/FdbmConfig.cj:643`（`durationValue`，只接受 `Duration` 文本）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复，其中一块少了分支 —— 往往同时是缺陷）
- **证据**：静态确定 —— `fdbm_cache_expire=3600` 走 `durationValue` → `CONFIG('not a Duration')`；同样写法的 `fdbm_checkDuration=3600`、`fdbm_sessionSweepInterval=3600`、`fdbm_shutdownTimeout=3600` 都被 `durationOf` 当秒接受。README 只对 `fdbm_cache_expire` 标注了「`Duration`，如 `30s`」，所以文档没错，是同一模块内两套时长口径。
- **描述**：使用者很容易按「裸数字＝秒」的惯例配置缓存过期时间，得到一条启动失败；换个键同样的写法又能用。
- **建议**：两者合并为一个 `durationOf(source, key, fallback, unit!)`，`fdbm_cache_expire` 也接受裸数字（`0` 表示不过期或保持「空＝永久」），或反过来在文档与错误信息里明确「本键必须带单位」。

### [轻微][存量] `BootScriptWriter` 内同一份「键族」被三张平行表重复描述

- **位置**：`fdbm/src/config/BootScriptWriter.cj:485`（`isWritableKey`）、`fdbm/src/config/BootScriptWriter.cj:193`（`groupOf`）、`fdbm/src/config/BootScriptWriter.cj:256`（`commentOf`），另有 `FIXED_COMMENTS`（:40）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制：同一组字段名/前缀散落多处）
- **证据**：静态确定 —— 新增一个配置键要同步改 4 处：不写 `isWritableKey` → EXPORT 被拒；写了但不写 `groupOf` → 落到「9. 其他」；不写 `commentOf` → 注释退化为「未归类」；不写 `FIXED_COMMENTS` → 分组/注释/白名单全丢。
- **描述**：不是当前缺陷（现有键四处一致），但漏改一处不会编译失败、也不会报错，只会在 boot.sh 里静默降级。
- **建议**：合并成一张 `Array<(prefix, group, commentTemplate)>` 表，`isWritableKey`/`groupOf`/`commentOf` 都从它派生；新增键只需加一行。

### [轻微][存量] 直接下标取首元素三处，未处理空集合

- **位置**：`fdbm/src/config/catalog.cj:79`（`all[0]`）、`fdbm/src/config/FdbmConfig.cj:355`（`catalog.allPhysicals()[0]`）、`fdbm/src/config/FdbmConfig.cj:361`（`smallest` 的 `physicals[0]`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空集合未处理）
- **证据**：静态确定（下标无保护）；实际可达性待确认 —— 生产路径由 `getNodes`（requery + `splitNonEmpty` 保证每节点至少一个库、至少一个节点）保证非空，但 `LogicalCatalog.of` 是 `protected` 类型的 `public` 成员，传空节点数组即 panic。
- **描述**：当前靠上游不变量兜底，属于「隐式契约」。一旦有人给 `LogicalCatalog.of` 传空 `nodes`（测试或后续新增调用点），得到的是 `IndexOutOfBounds` 而不是带键名的 `CONFIG` 错误。
- **建议**：在 `LogicalCatalog.of` 开头判 `all.isEmpty()` → `FdbmException(CONFIG, 'no physical database is configured')`；`smallest` 改 `physicals.fold` 或先判空，`getSequenceDatabase` 的兜底分支随之简化。

### [轻微][存量] `flush` 复用进程生命周期内的全部历史 `pending`，与设计「本次 set 的键值」不符

- **位置**：`fdbm/src/config/BootScriptWriter.cj:120`（合并 `pending`）、`fdbm/src/config/BootScriptWriter.cj:98`（只增不删）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与设计/注释不符）
- **证据**：静态确定 —— `flushLocked` 用整个 `pending` 覆盖块内同名键；设计 `doc/详细设计.md:283` 写的是「用**本次** `set` 的键值覆盖/追加」。
- **描述**：`EXPORT a` 之后管理员手工把块里的 `a` 改成别的值（虽不推荐，但块是纯文本），再 `EXPORT b` 会把 `a` 改回旧值且不提示。反过来说，`pending` 与运行期 `Config` 保持一致是合理语义，所以影响有限；问题是「不清理」既让语义偏离设计，也让上面的无界增长无法通过重启外的任何手段回收。
- **建议**：`flush` 成功后清空 `pending`（本次 set 的语义），或保留现状但把设计 §3.5 第 2 条改成「本进程内 set 过的全部键值」，二者取一。

### [轻微][存量] 权重键的「后缀不能以 `_` 结尾」校验会误伤以 `_` 结尾的合法节点名

- **位置**：`fdbm/src/config/FdbmConfig.cj:127`（`suffix.endsWith('_')` → `CONFIG`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界校验口径不一致）
- **证据**：静态确定（校验口径不一致）；`fdbm_db` 的节点名只要求非空（`FdbmConfig.cj:75`），`name_` 是合法节点名，但 `fdbm_loadbalance_weight_name_` 会被当成「缺节点名」直接拒绝；是否需要支持下划线结尾的节点名属部署约定，待确认。
- **描述**：这条校验本意是拦住 `fdbm_loadbalance_weight__` 这类只有分隔符的键，却顺带否掉了以 `_` 结尾的节点名；这类节点无法配置节点级权重，只能退化为默认 1/1。数据库级键 `node__db` 的后缀以库名结尾，永远不会命中该判断，所以它只对节点级键生效。
- **建议**：改成「按 `__` 切开后 node 段必须非空」的结构化判断（与 `validateWeights` :428 的切分逻辑共用），不再用 `endsWith('_')` 这种字符启发式。

### [轻微][存量] README「其他公开 API」未收录 `ConfigSource` / `EnvConfigSource` / `MapConfigSource`

- **位置**：`fdbm/README.md:257`（「其他公开 API」清单）、`fdbm/README_en.md:295`；对应声明 `fdbm/src/config/source.cj:27` / `:33` / `:44`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— 两版 README 对三个符号的检索命中数为 0，而同一清单收录了 `PoolConfig` / `NodeWeight` 等更细碎的成员（含 `canRead` / `canWrite`）。
- **描述**：README 首段声明「fdbm 是常驻服务，不提供库级 API」，因此这三处缺失的实际影响很小（外部无从使用）；但清单既然按「模块级 / 类型」穷举，漏三个 `public class` 会让读者以为配置源是内部实现。
- **建议**：在 `其他公开 API` 的类型分组里补三行（或说明「仅供测试/内部装配」），两版同步。

> 信息（按硬原则一不算死代码，仅记录）：`NodeWeight.canWrite` / `canRead`（`models.cj:99/103`）与 `FdbmException(code, caused)` 构造器（`FdbmException.cj:39`）在仓内只被测试引用——前者是 `protected` 类的 `public` 成员，路由侧实际直接用 `weight.write/read`（`fdbm/src/resources/DatabaseResources.cj:102`），可考虑作为「可见性建议」收窄或在路由侧改用 `canWrite/canRead`；后者是设计 §4 登记的对外构造形式，保留即可。

## 优化可行性方案

### [CPU] 用 `std.sort` 替换两处手写插入排序

- **现状**：`BootScriptWriter.sortedByKey`（`fdbm/src/config/BootScriptWriter.cj:530`）与 `LogicalCatalog.sortInPlace`（`fdbm/src/config/catalog.cj:184`）各 15 行插入排序；作用规模是「managed 块内键数」（当前 `fdbm/boot.sh` 为 30 项左右）与「物理库数」（个位数）
- **方案**：`import std.sort.*` 后 `sort(entries) {a, b => a[0] < b[0]}` / `values.sort()`，`sortedByKey` 的 `let copy = entries` 一并去掉（`Array` 是引用类型，`copy` 并未复制，命名有误导）
- **预期**：n≤50 时收益在噪声内（n²/4 ≈ 600 次比较），只有配置项上千时才可能看见；同时消掉一份重复实现
- **代价**：需确认 `std.sort` 的稳定排序语义不改变「同键」顺序（键唯一，无影响）；改动集中、可等价性验证
- **验证**：`cjpm bench -O2`，输入 10 / 1000 个键，各 5 轮取中位数；对照 `boot.sh` 字节输出一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU/IO] EXPORT 改为增量写：只重写受影响的块

- **现状**：每次 `flush` 完整读入 → 重建全部块 → 回写全文件（`BootScriptWriter.cj:109`），成本 O(文件大小)；N 次 EXPORT 累计 O(N²)
- **方案**：保留现有的 `parseBlock` 定位能力，但只为「本次 key 所在的块」重新渲染并替换对应行区间，其余块与块外内容原样拼接；块内仍保持 key 排序
- **预期**：单次 `flush` 的 I/O 从「整个文件」降到「一个块」，N 次 EXPORT 的总 I/O 从 O(N²) 降到 O(N·块)；在 30 个键的现状下差异 <1ms
- **代价**：需要处理「跨块移动键」（同一个 key 换了分组前缀时旧块要删行）、幂等性与 `normalize()` 的全量规范化路径要分开；实现复杂度明显上升
- **验证**：构造 10k 次 EXPORT（交替 5 个键）的压测，比较端到端 P50/P99 与写入字节数；同时断言 10k 次后文件内容等于一次性全量渲染结果
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 去掉 `flush` 路径上的多份文本副本

- **现状**：一次 `flush` 同时存活 `lines: Array<String>`（读入）、`merged: ArrayList<String>`、`block: Array<String>`、`joinLines` 的 `StringBuilder`，峰值约为文件字节数的 4–5 倍
- **方案**：`writeAtomically` 接受一个「逐行产出」的闭包/迭代器，边生成边写临时文件；`merged` 改为直接追加到 `StringBuilder`
- **预期**：峰值降到约 1 倍文件大小；当前 boot.sh 约 2–3 KB，收益在 10 KB 量级，可忽略
- **代价**：写出不再是「先拼完整串再原子写」，需保证异常路径仍能清理临时文件；代码可读性下降
- **验证**：`getAllocatedHeapSize()` 前后对照 + 10k 次 flush 的峰值；只在 boot.sh 增长到 MB 级时才有意义
- **证据状态**：`无基线（待验证，不进 tasks）`；按当前规模不建议实施

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 高频 EXPORT 下 `flush` 的全量重写成为请求延迟热点 | `fdbm/src/config/BootScriptWriter.cj:109` | 单次 flush 耗时随文件行数的曲线、EXPORT 在真实负载中的 QPS | 用 1k/10k/100k 行 boot.sh 各跑 1000 次 `flush`，`cjprof record` 取 `flushLocked` 自耗时占比 |
| 2 | 配置项很多时启动期多次全量遍历 `source.all()` 有可见开销 | `FdbmConfig.cj:122/155/162/203`、`catalog.cj:55` | `Config.getAll()` 是否每次复制整个 map、单次耗时 | 构造 1000 个配置键，分段计时 `FdbmSettings.load`；先查 `f_config` 文档确认 `getAll` 返回语义 |
| 3 | `sortedByKey` 的插入排序在键数增长后成为可见成本 | `BootScriptWriter.cj:530` | n=1k 时的绝对耗时 | `cjpm bench -O2` 对照 `std.sort`，同输入 5 轮中位数 |
| 4 | `File.writeTo` + `rename` 未 fsync，掉电后可能出现空/截断的 boot.sh | `BootScriptWriter.cj:460` | 平台文件系统语义、是否需要断电一致性 | 查 `std.fs` 文档确认 `writeTo` 是否 fsync；需要一致性时再补 `fsync` 目录/文件 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fdbm/src/config/BootScriptWriter.cj` | .cj | ✅ | boot.sh managed 区块读写；见「EXPORT 键空间无上限」「normalize 缩进」「parseBlock 吞行」「权限位丢失」「三张 key 表」「pending 全量复用」 |
| 2 | `fdbm/src/config/BootScriptWriter_test.cj` | .cj | ✅ | 覆盖分块/幂等/转义/并发；`flushKeepsExecutableBit` 只验可执行位（见「权限位丢失」的测试缺口） |
| 3 | `fdbm/src/config/FdbmConfig.cj` | .cj | ✅ | 配置解析与启动自检；见「EXPORT 值不校验」「池参数下界」「getLogicalDatabases 死代码」「恒假分支」「未使用 import」「重复逻辑」「时长口径漂移」「空集合下标」「权重键后缀」 |
| 4 | `fdbm/src/config/FdbmConfig_test.cj` | .cj | ✅ | 解析/默认值/自检负例；与实现一致，未发现断言与实现矛盾 |
| 5 | `fdbm/src/config/catalog.cj` | .cj | ✅ | 逻辑库命名空间；隐式展开、排序去重与 README「逻辑库」口径一致；见「重复逻辑」「空集合下标」 |
| 6 | `fdbm/src/config/models.cj` | .cj | ✅ | 配置模型 + `percentEncode`；URL 编码只放行 unreserved 字符，与注释一致 |
| 7 | `fdbm/src/config/settings.cj` | .cj | ✅ | 聚合根；`load()` 只解析不校验跨项，与类注释一致 |
| 8 | `fdbm/src/config/source.cj` | .cj | ✅ | `ConfigSource` 抽象；三类型未进 README（见「README 未收录」） |
| 9 | `fdbm/src/exception/FdbmException.cj` | .cj | ✅ | 与设计 §4 签名一致；三构造器齐全 |
| 10 | `fdbm/src/exception/FdbmException_test.cj` | .cj | ✅ | 错误码/消息/cause 保真，覆盖到位 |
| 11 | `fdbm/src/execute/Cursor_test.cj` | .cj | ✅ | G28 游标恢复用例；测试替身 `FlakyQueryResult` 实现完整 |
| 12 | `fdbm/src/execute/Dispatcher_test.cj` | .cj | ✅ | 分发器/执行器核心路径；断言与设计 §9 口径一致（G24/D03/D04/D05/G25 等） |

合计：`.cj` 12 个 / `.md` 0 个 / 共 12 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：「normalize 缩进」「parseBlock 吞行」「恒假分支」「空集合下标」；安全性：「权限位丢失」；设计合理性：「重复逻辑」「三张 key 表」。语言特性方面：`Array` 是引用类型（`sortedByKey` 的 `copy` 未复制）、`if (let Some(x) <- ...)` 惯用法使用正确；`Option` 未被静默丢弃，唯一例外是 `parseExport` 返回 `None` 时该行被当作「块内非 fdbm 行」跳过（已在「parseBlock 吞行」说明） |
| §1 死代码 | 3 | 逐个 private/internal/protected 符号搜过引用：`BootScriptWriter` 全部 private 方法与常量均有调用者；`FdbmConfig` 除 `getLogicalDatabases`（见「getLogicalDatabases 死代码」）外全部有调用；`catalog`/`models`/`settings` 的 private 符号均有调用；`return/throw/break` 后无同层语句；未使用 import 1 处（见「未使用 import」）；恒假分支 3 处（见「恒假分支」）；`public` 且对外可达的声明（`ConfigSource`、`EnvConfigSource`、`MapConfigSource`、`FdbmException`）按硬原则一不判 |
| §2 重复逻辑 | 3 | 已把 12 个文件的函数体压成「输入→输出→副作用」两两比对：5 对同语义实现（见「重复逻辑」）、1 对近似重复且漂移（见「时长口径漂移」）、1 组三张平行 key 表（见「三张 key 表」）；跨文件搜过错误文案/前缀表/默认值字面量，其余（如 `parseWeight` 与 `validateWeights`）语义不同，不合并 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`；两处 `catch` 均有日志或显式重抛（`normalize` 吞异常是设计 §3.5 明确要求，且记 ERROR）；`EnvConfigSource`/`MapConfigSource` 为真实实现 |
| §4 栈溢出 | 0 | 本部分无递归：`parseBlock`/`normalizeText`/`flushLocked` 都是单层循环，无自引用结构遍历、无递归拷贝 |
| §5 OOM | 1 | 唯一无界增长点是 EXPORT 键空间（见「EXPORT 键空间无上限」）；`boot.sh` 全量读入的内存与文件大小成正比，文件由部署方提供、非不可信长度，未单列（见「优化可行性方案」末条） |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 profile / bench 数据；`flush` 的全量重写、`sortedByKey`、`source.all()` 多次遍历都只有线索，已全部降级为「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | `BootScriptWriter.lock` 的临界区确实包含文件读写，但它保护的就是「文件内容 + `pending` + 临时文件名」这个不变量（设计 G11），无更细粒度可切；EXPORT 属运维低频操作，没有竞争证据，不作为发现 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`、无单消费者队列；`concurrentExportsAreSerialized` 与 `concurrentRequestsDoNotSerialize` 两个用例分别验证了「写脚本串行」与「执行器不串行」 |
| §6.4 低效算法 | 0 | 插入排序（n 很小）与 `source.all()` 多次遍历属线索，不构成复杂度缺陷；无 `remove(at: 0)`、无热点 `contains`、无循环内字符串拼接 |
| §7 降堆内存方案 | 1 | `flush` 路径 4–5 份文本副本（末条方案）；当前规模收益可忽略，标「无基线」 |
| §8 降 CPU 方案 | 2 | `std.sort` 替换手写插入排序、EXPORT 增量写；两条均标「无基线（待验证）」 |
| §9 local mode 可行性 | 0 | 本部分是启动期一次性解析与低频落盘，临时对象生命周期短但峰值极小（KB 级），没有可用峰值内存对照证明收益；且 `BootScriptWriter` 的状态跨函数存活，逃逸检查不通过 |
| §11 现有代码的 BUG（存量） | 6 | 「EXPORT 值不校验」（下次启动失败）、「normalize 缩进」、「parseBlock 吞行」、「权限位丢失」、「池参数下界」、「空集合下标」；本轮读到的 12 个文件里 `getNodes`/`parseAddress`/`parsePort`/`parseWeight`/`parseSubstring` 的边界（空串、缺 `@`、缺端口、IPv6 方括号、权重分隔符）逐一核对，未发现新问题 |
| §12 并发安全与锁粒度 | 0 | 唯一共享可变状态是 `BootScriptWriter` 的 `pending`/`serial`，读写在 `Mutex` 内；`Config.set` 在同一临界区；全模块无第二处跨线程状态；`FdbmConfig`/`LogicalCatalog` 都是不可变构造（`let` 字段），构造后只读。锁粒度评述见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 1 | 承诺源逐项核对：设计 §3.5 的 `normalize` 缩进契约（见「normalize 缩进」）、设计「复制原文件权限位」（见「权限位丢失」，实现缺失）、README「其他公开 API」（见「README 未收录」，遗漏 3 个 public 类型）；`BootScriptWriter.normalize` 已在 `FdbmServer.cj:230` 接线，`ExportExecutor` 已接入 `set/flush`，无「承诺但未接线」项 |
| 文件覆盖（§13 等） | 12/12 | 12 个文件全部读完；`.md` 文件不在本部分清单内（由第 1/2 部分覆盖），本报告涉及的文档位置只用于提供判据 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量 16 条，是否纳入修复待用户决定（本部分无「本次改动」来源的问题：快照基线无 diff）。

## 总评

本部分的代码质量整体偏上：配置解析几乎每条 `get*` 都做到「键缺失取默认、键存在但非法立刻抛带键名与原值的 `CONFIG`」，`validate` 把跨项引用（驱动唯一性、权重/分片/全局表/ID 生成器）放在启动期一次收口，比运行期才炸好得多；`BootScriptWriter` 用「临时文件 + rename + 单一 Mutex」把并发写脚本这条容易出错的路收敛得比较干净，测试也覆盖了幂等、转义、旧标记迁移与并发 EXPORT。

真正的阻塞项只有一个：**EXPORT 的键空间没有边界**，任意客户端都能用无限后缀的键让 `pending` 和 boot.sh 持续增长，且每次落盘全量重写造成 O(N²) 的 I/O——这与「配置项由部署决定」的语义不匹配，建议优先把它收敛成「有限键集合 + 已配置实体校验」，顺带解决同一处「只校验键名不校验值」导致的下次启动失败问题。

其余四项「一般」都属于运维可感知但非阻塞：`normalize` 的缩进判定与设计不一致（tab 缩进/插入点，改坏脚本是静默的）、`parseBlock` 在 END 标记缺失时会吞掉块后的非 fdbm export、重写 boot.sh 只搬可执行位（内含明文库密码，权限可能被放宽），以及连接池参数完全没有下界校验。这四条都建议排期，其中权限位那条与设计文档存在一对矛盾表述，修实现或改文档必须选一个。

十条「轻微」以死代码、重复逻辑和文档遗漏为主：`getLogicalDatabases` 无人调用、三处恒假分支、一个多余 import、五对同语义工具函数（含一份重复的池默认值表）、三张平行的 key 表、三处裸下标取首元素、`durationOf`/`durationValue` 的时长口径漂移、`pending` 全量复用与设计表述不符、权重键 `endsWith('_')` 误伤合法节点名，以及 README 漏收三个 `public` 配置源类型。它们不影响当前行为，但都会让下一次「加一个配置键」变成多处同步修改，属于可以顺手清掉的技术债。性能方面的结论全部没有基线，已按要求放进「优化可行性方案（无基线）」与「待验证假设」，不进修复清单。
