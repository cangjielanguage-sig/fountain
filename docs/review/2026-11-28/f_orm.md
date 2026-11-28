# f_orm 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（122 个文件：111 个 .cj + 11 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 8 个分部分报告合并：`parts/f_orm.part1..8.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] #1 事务闭包返回 `false` 在配置了 `rollbackFor` 时会被**提交**，与本文件 516 行的承诺相反

- **位置**：`f_orm/README.md:516`（"闭包返回 `false` 时抛的是无消息的 `ORMException()`，走「一般异常」路径并回滚"）；实现 `f_orm/src/base/SqlExecutor.cj:1053-1055`（`else { throw ORMException() }`）、`1078-1091`（`rollbackFor` 已配置但异常不匹配 ⇒ 走 `beforeCommit` + `noRollbackFor(e)` 提交后重抛）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现相反」、§11「契约与实现不符」「错误处理缺失或静默」；严重度按 §「数据丢失 / 错误」定
- **证据**：静态确定 —— `execute<T>(executor: (SqlExecutor) -> (T, Bool))` 在 `commit == false` 时抛 `ORMException()`（`1053-1055`）。该异常进入 `catch` 后依次判定：命中 `noRollbackFor` → 提交；否则若 `rollbackFor` 非空（默认来自 `orm_transactionRollbackFor`，见 `1058-1091`）→ 遍历 `rollbackFor` 集合不匹配时落到 `1087-1091` 的 `beforeCommit` + `noRollbackFor(e)`，即**提交**。只有 `rollbackFor` 未配置时才落到 `1092-1098` 的 `rollback()`。因此 README 的"返回 false ⇒ 回滚"仅在 `orm_transactionRollbackFor` 缺省时成立。
- **描述**：调用方用第二个返回值表达"不要提交"是这层 API 的核心契约（README §5.4、§14.2 都这么写）。一旦应用按 README §14.2 的示例配置了 `rollbackFor`，任何 `(result, false)` 都会被**静默提交**，并且只重抛异常、不留日志说明已提交——这是"用户明确要求回滚、框架却提交"的数据错误。同文件 `514` 行的表格把这一行为描述为"配置了 `rollbackFor` 但异常不匹配 ⇒ 提交后重抛"，与 `516` 行自相矛盾：两段对同一路径给出相反结论，使用者按哪段写代码都可能踩空。
- **建议**：`commit == false` 不应走"异常分类"通道。引入独立分支（如先 `beforeRollback` → `rollback()` → `afterRollback` → `afterComplete(Rollback)` 后抛专门的 `ORMException('transaction rolled back because executor returned false')`），使其不受 `noRollbackFor` / `rollbackFor` 影响；同时把 `514` / `516` 两段合并成一张"只有 `rollbackFor` 命中才回滚"的准确表，并写明 `false` 恒回滚。另建议补一条用例：`rollbackFor` 非空 + 闭包返回 `false`，断言 `afterComplete(Rollback)`。

### [一般][存量] #2 `isReadOnly` 是**粘滞**标志，README 却说"无置 true 的分支，故恒为 false"

- **位置**：`f_orm/README.md:379`（"当前实现只在非 select 时置 false，无置 true 的分支，故恒为 false"）、`README.md:517`（"当前实现恒为 `false`"）；实现 `f_orm/src/base/SqlExecutor.cj:84-87`（`if (isSelectStatement(normalized)) { readOnly = true }`）、`107-111`（`isReadOnly` 直接返回该字段）、`97-106` / `153-174`（`clearSql()` 与 `close()` 均不复位该字段）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现相反」、§11「语义与命名 / 注释不符」；触发点 `SqlExecutor.cj:1048`、`1071`、`1087` 的 `beforeCommit(this.isReadOnly)`
- **证据**：静态确定 —— 在 `SqlExecutor` 内 `readOnly` 只有三处出现：`47` 行初值 `false`、`85` 行置 `true`、`109` 行读取；模块内其余同名标识符都是事务钩子的入参或 `TransactionAccessMode` 的枚举 case，不写这个字段。即：**没有置 `false` 的分支**，但**有置 `true` 的分支**，且 `clearSql()` / `close()` 都不复位。
- **描述**：README 的结论（恒 false）与实现（一旦执行过任意 SELECT 就永久 true）正好相反。真实语义是：同一线程上的 `SqlExecutor` 执行过任意一条 `select ...` 之后，后续**所有** `beforeCommit(readOnly)` 回调都会收到 `true`，哪怕是纯写事务；反之在首次 SELECT 之前恒为 `false`。事务钩子若据此做读写分离、只读副本路由或审计，会在"先查后写"的同一事务里得到错误标记。README 两处都写错，等于把这个字段的可信度问题藏了起来。
- **建议**：实现侧在 `clearSql()`（或 `close()`）里复位 `readOnly = false`，让语义回到"本次 SQL 是否只读"；文档侧改为"每次 `setSql` 时按前缀重算，执行收尾后复位"，并在 §5.4 注明 `beforeCommit(readOnly)` 的口径。若短期内不改实现，文档必须写明"粘滞、不随 SQL 清空复位"。

### [一般][存量] #3 "运行期不读内嵌敏感信息"的结论与 `Config.getString` 的回落链相反

- **位置**：`f_orm/README.md:2111`（"`ORMConfig.getConf` / `getUrl` / `getUsername` / `getPassword` 只读取 `Config`（即环境变量），**不读取 `sensitiveMap`**"）、`README.md:2143`（同结论重复）；实现 `f_config/src/Config.cj:186-198`（`getString` 依次查 `ARGS[key]` → `ARGS['fountain_'+key]` → `sensitiveMap[key]` → `sensitiveMap['fountain_'+key]`，命中即 `sensitive2Str` 解密）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 承诺与实现相反」、§14「承诺了但没实现（反方向：实现了却声明没有）」
- **证据**：静态确定 —— `ORMConfig.getConf`（`wrap/ORMConfig.cj:134-140`）最终调 `Config.getString(key)`；`Config.getString` 第 191-194 行明确从 `sensitiveMap` 取并解密。因此编译期内嵌的 `<driver>_orm_connectionUrl` / `orm_option_username` / `orm_option_password` **会在运行期被自动使用**，只要同名环境变量缺失。
- **描述**：README 在 §18 开头与 §18.2 末尾两次断言"内嵌值不会被自动使用，`getSensitive` 已删除"，并据此要求"编译环境没配置就必须在运行环境配置"。这与实现相反：`getSensitive` 确实删了，但取值逻辑合并进了 `Config.getString`。运维按文档会在运行环境重复下发口令（扩大泄露面），或反过来怀疑"内嵌没生效"而去排查不存在的 bug。该结论还和同节 2140-2142 行"会把敏感信息嵌入编译产物"的用途说明冲突——嵌入了却声明不用，等于否定该特性。
- **建议**：改写 §18 与 §18.2 的这两段：说明优先级为"环境变量 → `fountain_` 前缀 → `sensitiveMap`（SM4 解密）"，并给一条验证步骤（清空运行环境变量后 `getUrl` 仍能拿到内嵌值）。若产品决策是"不让内嵌值生效"，则要在 `ORMConfig.getConf` 侧显式绕过 `sensitiveMap`，不能只改文档。

### [一般][存量] #4 SM4 章节的配置项名、常量清单与内嵌规则三处与实现不符

- **位置**：
  - `f_orm/README.md:2119-2123`：`orm_sm4Operation` / `orm_sm4Padding` / `orm_sm4Aad` / `orm_sm4TagSize`（同段却把 `sm4Key` / `sm4Iv` 写成无前缀，文档内部已自相矛盾）；
  - `f_orm/README.md:252`：声称 `ORMConfig` 有"与各环境变量同名的 public static const … `sm4*`"；
  - `f_orm/README.md:2138`：规则位置写 `macros/EmbedSensitive.cj`；`README.md:2141`："全局名不会被原样内嵌"。
- **实现取证**：`f_config/src/Config.cj:51-56` 的常量是 `sm4Operation` / `sm4Padding` / `sm4Key` / `sm4Iv` / `sm4Aad` / `sm4TagSize`（无 `orm_` 前缀）；`Config.getString`（`186-198`）只识别 `key` 与 `fountain_key`，**不认识 `orm_` 前缀**，故 `orm_sm4Operation` 等 4 个名字设置后不会被读取。`f_orm/src/wrap/ORMConfig.cj` 全文 0 处 `sm4`（`grep -c sm4` = 0），即不存在 `sm4*` 常量。内嵌规则实际在 `f_config/src/macros/EmbedSensitive.cj:22-49`，而 `f_orm/src/ProtectedMacros/EmbedSensitive.cj:29-41` 把**全局三项**（`orm_connectionUrl`、`orm_option_username`、`orm_option_password`）与各驱动的三项一起交给 `@EmbedSensitive`，`f_config` 侧按 token 原名 `Config.registerSensitive($k, …)` 注册（`EmbedSensitive.cj:25-36`），因此**全局名会被原样内嵌**。
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「链接 / 路径失效」、§14.2「公开 API 未文档化（反向：文档列了不存在的 API）」
- **证据**：静态确定 —— 上述符号在 `f_orm/src` 与 `f_config/src` 的检索结果与文档逐条对不上；`orm_sm4*` 在 `Config.getString` 的可达键集合之外。
- **描述**：三类后果：① 按 §18.1 设置 `orm_sm4Operation=GCM` 等加密参数会**完全无效**（键名不被读取），SM4 会按默认 CBC/PKCS7 走，使用者以为换了模式而实际没换；② §3.5 的常量清单把不存在的 `sm4*` 当成公开契约，编译期引用会直接失败；③ "全局名不会被原样内嵌"与宏实际传入的键集合相反，会让安全评审误判"产物里只有驱动前缀键"。
- **建议**：把 §18.1 的环境变量名统一改为无前缀的 `sm4Operation` / `sm4Padding` / `sm4Key` / `sm4Iv` / `sm4Aad` / `sm4TagSize`（或改代码让 `SM4Conf` 也接受 `orm_` / `fountain_` 前缀，二者取一并写清）；删掉 §3.5 中 `sm4*`；把"内嵌规则"的位置改为 `f_config/src/macros/EmbedSensitive.cj` + `f_orm/src/ProtectedMacros/EmbedSensitive.cj`，并补一句"全局三项与 `<driver>_` 三项都会以原名注册"。

### [一般][存量] #5 README §8.1 宣称的 `:{a.b.c}` 数据路径绑定不可用：路径扫描用了过期的 `token`

- **位置**：`f_orm/README.md:822-827`（`:{a.b.c}` 绑定数据路径、`:{user.name}` / `:{$.user.name}` 可用）；实现 `f_orm/src/base/SqlDSL.cj:63-88`，关键在 `71` 行 `while(i < tokens.size && token.kind != RCURL)`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「示例代码不能用 / 承诺与实现不符」、§11「边界差一 / 越界」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `case LCURL` 分支里 `token` 是第 64 行绑定的 `LCURL` 记号（`let token = tokens[i]`），循环条件却拿它和 `RCURL` 比较，**永远为真**，循环只由 `i < tokens.size` 结束。于是：
  - DSL 以 `:{...}` 结尾时（如 `':{user.name}'`），`path` 会连 `RCURL` 一起吞下（`path.size == 4`，末位是 `}`），既不等于 1 个 IDENTIFIER，也不以 `$` 开头，走 `82-87` 的 `DataPath.solid('$.user.name}')` —— 路径非法；
  - DSL 在 `}` 之后还有内容时（如 `'... :{user.name} and x = 1'`），循环会把 `and x = 1` 一并吞入，随后 `75` 行 `tokens[tokens.size-1].kind != RCURL` 成立，抛 `IllegalArgumentException('not completely data path ...')`。
  两条路径都拿不到可用 SQL。
- **描述**：README 把 `:{...}` 作为"模板 SQL 的两大写法之一"（§8.1 表格第 2、3 行）对外承诺，PO 场景的嵌套字段绑定（`setSqlFromObject` + `:{user.name}`）实际不可用；`ArgSqlDSLPart`（`:name`）路径正常，所以问题只在文档主推的"数据路径"写法上，且失败形态是"要么抛解析异常、要么把整段 SQL 当路径"，很难定位。
- **建议**：循环条件改为 `tokens[i].kind != RCURL`（并去掉 64 行那次无关绑定），补三条用例：`':{user.name}'`、`'... :{user.name} where x = 1'`、`':{$.user.name}'`。修好前 README §8.1 应把 `:{...}` 标为"暂不可用"，避免使用者照抄。

### [一般][存量] #6 README §8.1 宣称 `Iterable<Data>` 展开为多个 `?`：实现每个元素产出两个占位符

- **位置**：`f_orm/README.md:828`（"`Iterable<Data>` → 展开为逗号分隔的多个 `?`（便于 `IN` 使用）"）；实现 `f_orm/src/base/SqlDSL.cj:103-126`，重复点在 `112-122`
- **来源**：存量（快照模式，无目录基线可比）
- **判据**：review-checklist §13「示例 / 承诺与实现不符」、§11「逻辑错误」
- **证据**：静态确定 —— `convert()` 的标量分支在 `125` 行统一 `sqlgen.append(' ? ')`；`Iterable<Data>` 分支对每个元素先递归 `convert(...)`（已追加一个 `?`），随后 `118` 行再 `sqlgen.append('?')`，即**每个元素两个占位符**。n 个元素 ⇒ 2n 个 `?`，而 `exe.arg` 只绑定了 n 个参数 ⇒ 占位符数 ≠ 参数数，语句在 `prepareStatement` / 执行阶段报错（不同驱动报错文案不同）。
- **描述**：这使 `setSqlFromMap('... id in (:ids)', map)` 这类"集合展开"用法必然失败，而 README 恰好把它作为 DSL 的便利特性列出。`Array<Byte>` 走 `110` 行的 `DataCollection<Array<Byte>, Byte>` 分支不受影响，所以常规 BLOB 绑定掩盖了该缺陷。
- **建议**：`Iterable` 分支改为"先 `convert` 再按需补逗号、不再追加 `?`"（把分隔符放在元素之间，占位符只由标量分支产出），或让标量分支不追加、由调用方统一追加。补一条用例：3 元素集合 → 断言生成的 `?` 个数为 3 且 equals 绑定参数个数。

### [一般][存量] #7 两个已接线、控制超时的公开配置项完全未进 README（`orm_connectingTimeout`、`orm_databasePoolMaxWaiting`）

- **位置**：`f_orm/README.md:175-186`（§3.1 驱动与连接表）、`218-230`（§3.3 连接池表）、`245-317`（§3.5 `ORMConfig` 静态 API 清单）——三处均无这两个键；实现 `f_orm/src/wrap/ORMConfig.cj:28`（`connectingTimeout = 'orm_connectingTimeout'`）、`51`（`databasePoolMaxWaiting = 'orm_databasePoolMaxWaiting'`）、`237-239`（`getConnectingTimeout`，默认 5000ms）、`247-254`（`getPoolMaxWaiting`，默认 30000ms，`<=0` 表示无限等待）；使用点 `f_orm/src/base/SqlExecutor.cj:402`、`f_orm/src/wrap/NamedDatasource.cj:101`
- **来源**：存量（快照模式，无基线可比；README 全文对这两个名字 0 命中）
- **判据**：review-checklist §14.2「公开 API 未文档化 / 缺关键段落（配置项表）」、§13「关键段落缺失」
- **证据**：静态确定 —— `grep -c` 在 README 中对 `connectingTimeout` / `getConnectingTimeout` / `databasePoolMaxWaiting` / `getPoolMaxWaiting` 均为 0；而两者都是 `public static` 且已接到执行路径（连接 `Connecting` 等待上限、池耗尽等待上限）。
- **描述**：README 自称"第 3 节所有环境变量的解析实现"（§3.5 对 `ORMConfig` 的定义），漏掉的两项恰好是**故障场景下的唯一止损开关**：驱动把连接停在 `Connecting` 时，`SqlExecutor.waitConnecting()` 靠 `orm_connectingTimeout` 才会抛 `ConnectionException`（默认 5s）；池耗尽时 `DatabasePool` 靠 `orm_databasePoolMaxWaiting`（默认 30s，`0` 才是真无限）。运维遇到"请求长时间挂住"时按 README 找不到可调项，只能改代码或重启。注释里还写了两者单位不同（都按毫秒），文档缺失会放大"按秒配"的误用。
- **建议**：§3.1 增两行（键名 / 默认值 / 单位毫秒 / 语义与 `0` 的含义），§3.3 补 `orm_databasePoolMaxWaiting`，§3.5 的 getter 清单补 `getConnectingTimeout()` / `getPoolMaxWaiting()` 与同名 const。

### [一般][存量] #8 `Nested` 传播行为的描述与实现不符：无外层事务时实现会**开启真实事务**

- **位置**：`f_orm/README.md:1566`（"`Nested` // 外层有事务则开内嵌事务；否则也不使用事务"）；实现 `f_orm/src/base/SqlExecutor.cj:260-270`（`case Nested =>` 无条件 `connection.createTransaction()`，成功即 `hasRealTx = true; this.tx = tx`，代码内注释自述"behave like REQUIRED otherwise"）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现相反」、§11「契约与实现不符」
- **证据**：静态确定 —— `Nested` 分支没有任何 `hasRealTx` 判断，也没有 savepoint 调用；与外层有无事务无关，一律在当前连接上 `createTransaction()` 并把 `hasRealTx` 置真。对比 `Required`（`202-216`）与 `Supports`（`217-218`，走 dummy）可见语义差异被抹平。
- **描述**：两处误导：① 无外层事务时 README 说"不用事务"，实现却开了真事务并提交/回滚——使用者以为"嵌套写法在无事务上下文里是裸执行"，实际会被包进事务（对 DDL、长事务、`autocommit` 依赖型驱动都有影响）；② README 说"外层有事务则开内嵌事务"，实现是在同一连接上**又开一个事务包装**而非 savepoint（真正的嵌套应走 `save(name)`），`Nested` 与 `RequiresNew` 的差别只剩"是否新取连接"。这属于事务语义类文档，写错会直接导致提交/回滚边界与预期不同。
- **建议**：先定语义：若要 Spring 式 `Nested`，实现应改为"有外层事务 → `tx.save(name)` + 记录 savepoint，结束 `release`；无外层 → 同 `Required`"；若保持现状，README §14.1 必须改为"Nested 当前等价于 Required（不建 savepoint）"，并在 §14.2 给一条对照用例。二者不要停在"文档写 A、代码做 B"。

### [一般][存量] #9 `Pagination` 未声明 `size > 0` 约束，实现直接 `rows / size`，`size = 0` 除零崩溃

- **位置**：`f_orm/README.md:1326-1346`（§12 签名与说明，未提约束）；实现 `f_orm/src/base/Pagination.cj:34-43`（`this.pages = rows / size + …`），入口 `f_orm/src/base/TableClause.cj:361-374`（`page` / `singlePage` 把调用方 `size` 原样透传）、`f_orm/src/base/SqlPartial.cj` 的 `page` / `singlePage`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空集合 / 除零未处理」、§13「关键限制未写」、§14.2「缺关键段落（限制与注意事项）」
- **证据**：静态确定 —— 主构造函数对 `size` 无任何校验，`rows / size` 在 `size == 0` 时触发整数除零异常（仓颉算术非法运算抛异常，不是返回 0）；`page: 0` 时偏移量 `(page - 1) * size` 为负，同样没有校验，最终由驱动报 SQL 错。README §12 只说"当前页码（从 1 开始）"和"每页大小"，没有"必须 > 0"的约束，也没有"`page < 1` 的行为"。
- **描述**：分页参数来自前端是很常见的场景（`?page=0&size=0`、`size` 缺省为 0 的 DTO 默认值）。当前表现是"抛除零异常"或"把负 offset 交给驱动"，前者在 `count` 查询之后才炸（已经白跑一次 count），后者依赖方言行为。文档层面没有任何提示，使用者会以为框架已做边界处理。
- **建议**：`Pagination` 主构造函数对 `size <= 0` 抛带明确消息的 `IllegalArgumentException`（或把 `pages` 归 0 并在文档写明），`page <= 0` 归一为 1；README §12 增加"限制：`size` 必须 > 0，`page` 从 1 开始"两行。补用例：`size = 0`、`page = 0`、`rows = 0 && size = 0`。

### [轻微] #10 §19.2 仍把已删除的 `SqlArgs.clone()` / `clear()` 列为 protected 成员

- **位置**：`f_orm/README.md:2190`（"protected：`clone()`、`set(statement)`、`clear()`、`add(all!: SqlArgs)`"）；实现 `f_orm/src/wrap/SqlArgs.cj:18-123` 只有 `set(statement)`（`26-30`）、`add(all!: SqlArgs)`（`101-104`），无 `clone`、无 `clear`；`f_orm/src/base/SqlExecutor.cj:100-105` 的注释明确写了"clone() 已删除，改成换新实例"
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期」、§1「兼容残留」
- **证据**：静态确定 —— `SqlArgs` 文件中不存在这两个名字；`SqlExecutor.clearSql` 的实现注释说明 `clone()` 被移除、`clear()` 语义改为 `this.args = SqlArgs()`。
- **描述**：文档列出的内部 API 与源码不一致，继承 `SqlArgs` 的扩展方按文档调 `clone()` 会编译失败；也让人误以为"参数集合可以原地清空复用"——而这正是被移除的旧行为（会污染 `SqlCacheKey`，见 `SqlExecutor.cj:100-103`）。
- **建议**：§19.2 删掉 `clone()` / `clear()`，改为"参数清空由 `SqlExecutor.clearSql()` 换新实例完成（`SqlArgs` 本身不提供清空）"。

### [轻微] #11 §6.1 "`InputStream` 与 `Data` 两种重载是 `arg` 独有（`add` 无）"与实现不符

- **位置**：`f_orm/README.md:567`；实现 `f_orm/src/base/SqlExecutor.cj:815-824`（`public func add(arg: InputStream)` / `add(arg: ?InputStream)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API 与源码不符」
- **证据**：静态确定 —— `add` 有 `InputStream` 与 `?InputStream` 两个重载；只有 `arg(value: Data)`（`RootDAO.cj:239`）是 `arg` 独有。
- **描述**：措辞把 `InputStream` 也算成 `arg` 独有，会让使用者以为 BLOB 只能通过 `arg(...)` 绑定，或在 `setSql` 之外找不到 `add(stream)` 而绕路。
- **建议**：改为"`Data` 是 `arg` 独有；`InputStream` 两者都有（`add` 侧为 `add(arg: InputStream)` / `add(arg: ?InputStream)`）"。

### [轻微] #12 §7.2 的 `UPDATE` 示例注释把 WHERE 列写成 `username`

- **位置**：`f_orm/README.md:731-732`（`map[UserPO.tableColumns().id] = 1` → `executor.UPDATE<UserPO>(map)  // where username = ?`）；实现 `f_orm/src/base/SqlPartial.cj:144-181`（`isId` 的 mapper 被 `continue` 跳过 SET，主键列单独拼 `WHERE`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「示例与实现不符」、§11「语义与注释不符」
- **证据**：静态确定 —— `UPDATE<T>(Map<String, Any>)` 以 `m.isId` 的列作为 `WHERE`（`168-181`），与同节 713 行"主键作为 WHERE 条件"一致；示例里主键是 `id`。
- **描述**：读者照注释理解会以为 WHERE 用的是 username（进而以为主键被忽略），与上一段文字直接冲突；这类示例注释是最容易被复制到业务代码里的部分。
- **建议**：注释改为 `// where id = ?`，并补一句"`map` 中的主键键值对只用于 WHERE，不参与 SET"。

<!-- 第 2 部分 -->

### [轻微][存量] #1 `ArgBindCount_test` 把进程级 `MOCKDB.execution` 换掉后不还原，给后续用例留下外来夹具

- **位置**：`f_orm/src/base/ArgBindCount_test.cj:41-54`（设置 `MOCKDB.execution`）、`40`（只调 `MOCKDB.clear()`）、`61-65`（用完直接 `ex.clearSql()` 结束，无 `finally` 还原）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「资源不对称 / 副作用未回滚」、§12.1「共享可变状态」、§14「测试隔离」
- **证据**：静态确定（结构）—— `MOCKDB.clear()` 明确**不**重置 `execution`（`f_mockdb/src/mockdb.cj:71` 的注释与 `77-90` 的实现都写明「不动 execution 与 toThrowOn* 标志」），唯一能还原的 `clearExecution()` 是包内可见的 `static func`（`mockdb.cj:92-95`），`f_orm` 的用例调不到；而 `MOCKDB.execution` 是 `AtomicOptionReference` 的进程级单例（`mockdb.cj:57`、`105-112`），`cjpm test` 同进程内所有用例共享。这个夹具会给**每一次** SQL 执行追加一列 `n`（`SqlBigInt`）和一行 `[1]`（`52-53`）。
- **描述**：今天尚未造成红——本模块 11 处设置 `MOCKDB.execution` 的用例都在各自开头覆盖了它（`ArgInSql_test` / `SqlResultCache*_test` / `SqlPartialColumnKey_test` / `SqlExecutorArgBranches_test` / `SqlExecutorStatement_test` / `QueryResultIterator_test` 等），其余不执行 SQL 的用例（`ArgSqlText_test` / `QueryResultWrap_test` / `migro_test` / `f_mockdb_po_test` 等）不会走到 `execution`；唯一会执行 SQL 却未设夹具的 `SqlExecutorConnectingTimeout_test.cj:104-108` 在建连阶段就抛超时，也到不了夹具。风险是**潜伏**的：下一个「执行 SQL 但忘了设夹具」的用例会静默继承本夹具（多一列一行、`first` 返回非 `None`），且失败与否取决于执行顺序。
- **建议**：① `f_mockdb` 把 `clearExecution()` 提升为 `public`（或提供 `reset()`），让用例能对称还原；② 本用例改成 `try { ... } finally { MOCKDB.clearExecution() }`；③ 更好的做法是把 `execution` 做成可嵌套的「夹具作用域」helper（设置→返回捕获对象→`finally` 还原），供全模块 11 处赋值点统一使用（其余 10 处见「范围外提示」）。

### [一般][存量] #2 README 关于 `SqlExecutor.isReadOnly` 「恒为 false」的说明与实现相反，且实现侧的粘滞语义未被文档化

- **位置**：文档 `f_orm/README_en.md:406`、`561`；实现 `f_orm/src/base/SqlExecutor.cj:83-86`（`isSelectStatement(normalized)` 成立时 `readOnly = true`）、`47`（`private var readOnly = false` 初始化）、`107-111`（getter）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「API / 行为与源码不符」、§11「语义与注释不符」
- **证据**：静态确定 —— README 写「the current implementation only sets false for non-select and has no branch setting true, so it is **always false**」「`beforeCommit(readOnly)` … which is **always `false`** in the current implementation」；实际 `sql` 的 setter 在语句以 `select` 开头时把 `readOnly` 置 `true`，全文件只有 `47`（初值）、`85`（置 true）、`109`（读）三处，`close()`（`153-174`）与 `clearSql()`（`97-105`）都**不复位**。
- **描述**：两层后果。① 文档层面：使用者会以为 `isReadOnly` 是永远 false 的死开关，从而不校验它；② 行为层面：同一个 executor 实例内先跑过任何 `select` 之后，再跑 `update`，`readOnly` 仍为 `true`，`beforeCommit(readOnly)`（`SqlExecutor.cj:1048/1071/1087`）与 `isReadOnly` 都会向事务钩子报「只读」——写事务被当成只读事务处理。
- **建议**：文档改成「select 置 `true`，当前实现不复位（粘滞），因此只应作为『本实例曾执行过 select』的弱提示」；实现上应在 `setSql`/`clearSql` 里成对复位（`readOnly = isSelectStatement(normalized)`），或在 `close()` 里复位——这部分属 `base/SqlExecutor.cj`（其他部分），本部分只负责把文档口径改对。

### [一般][存量] #3 README 第 18 章「敏感信息」的三条断言与代码不符（运行期不读 `sensitiveMap` / 全局名不嵌入 / 宏文件路径）

- **位置**：文档 `f_orm/README_en.md:2288-2291`（「只读 `Config`（环境变量），**不读** `sensitiveMap`，嵌入值在运行期不会被自动使用」）、`2326-2327`（同义重复）、`2318`（`Embedding rules (macros/EmbedSensitive.cj)`）、`2320-2323`（「只嵌入带驱动名前缀的键；全局名不会原样嵌入」）；实现 `f_orm/src/ProtectedMacros/EmbedSensitive.cj:29-41`、`f_config/src/Config.cj:186-198`、`163-168`、`297-301`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档与代码相反」、§14「承诺与实现不一致」、§10「安全性描述」
- **证据**：静态确定，三条逐条取证：
  1. **运行期确实读 `sensitiveMap`**：`ORMConfig.getConf` → `Config.getString(key)`；`Config.getString` 的四段回退是 `ARGS[key]` → `ARGS['orm_'+key]` → **`sensitiveMap[key]`** → **`sensitiveMap['orm_'+key]`**（`f_config/src/Config.cj:186-198`，解码走 `sensitive2Str`），`Config.getAll` 也会把 `sensitiveMap` 合并进结果（`163-168`）。因此「嵌入值运行期不会被使用」是错的——它是环境变量缺失时的兜底来源，`getUrl` / `getUsername` / `getPassword` 都吃这条路径。
  2. **全局名会原样嵌入**：本部分宏先把 `ORMConfig.connectionUrl` / `username` / `password` 三个**全局键**放进 `keys`（`ProtectedMacros/EmbedSensitive.cj:29-33`），再逐个驱动追加 `genKey(d, …)` 前缀键（`35-41`），最后整体交给 `@EmbedSensitive`；`@EmbedSensitive` 对每个**值非空**的键调 `Config.registerSensitive(k, …)`（`f_config/src/macros/EmbedSensitive.cj:24-38`）。故 `orm_connectionUrl` / `orm_option_username` / `orm_option_password` 也会被嵌入，与「全局名不会原样嵌入」相反。
  3. **路径不存在**：`f_orm/src/macros/` 下只有 `DAO.cj` / `ORMField.cj` / `QueryMappersGenerator.cj` / `TransactionalService.cj`（`macro package fountain::f_orm.macros`），没有 `EmbedSensitive.cj`；真正干这件事的是 `f_orm/src/ProtectedMacros/EmbedSensitive.cj`（`protected macro package fountain::f_orm.ProtectedMacros`，在 `src/base/imports.cj:38` 以 `@ORMEmbedSensitive()` 触发）。
- **描述**：这一段是使用者的「凭据从哪来」说明，三条同时错会直接把排查带偏：按文档会认为「编译期嵌入是白做的、运行期必须配环境变量」，而实际上是「环境变量优先、嵌入值兜底」；同时「全局名不嵌入」会让多数据源排查时漏掉全局兜底这一层。附带两处未说明的风险：① SM4 的 key/iv/aad 与密文**同批嵌入**（`f_config/src/macros/EmbedSensitive.cj:40-48`，解密在 `Config.cj:174-182`），拿到二进制即可解密，SM4 保护的实际强度只是「产物里不出现明文字符串」；② 嵌入发生在 **`f_orm` 自身**的编译单元（`base/imports.cj:38`），下游以预编译 `dynamic` 库依赖时，嵌入值来自 `f_orm` 的构建机而非应用构建机，文档只写「构建环境」未点明这一层（`cjpm.toml:28` `output-type = "dynamic"`）。
- **建议**：重写 18 章开头与「Embedding rules」段：键集合写成「3 个全局键 + 每个 `orm_drivers` 驱动的 3 个前缀键」、路径改成 `src/ProtectedMacros/EmbedSensitive.cj`、取值优先级写成「环境变量 > 嵌入值（`Config.getString` 的 `sensitiveMap` 回退）」；补一句「SM4 密钥与密文同在原产物内」与「嵌入发生在 f_orm 编译期」。

### [一般][存量] #4 README 完全没有记录两个公开的「保护性上限」配置：`orm_connectingTimeout` 与 `orm_databasePoolMaxWaiting`

- **位置**：文档 `f_orm/README_en.md:185-201`（§3.1 表）、`231-243`（§3.3 表）、`256-329`（§3.5 公开 API 块）均无；源码 `f_orm/src/wrap/ORMConfig.cj:28`（常量）、`237-240`（`getConnectingTimeout`，默认 5000ms）、`51`（常量）、`244-252`（`getPoolMaxWaiting`，默认 30000ms，`<=0` 表示无限等待）；使用点 `f_orm/src/base/SqlExecutor.cj:402-404`、`f_orm/src/wrap/NamedDatasource.cj:101`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14.2「公开 API / 配置未文档化」、§13
- **证据**：静态确定 —— 两版 README（`README_en.md` / `README.md`）对 `connectingTimeout` / `maxWaiting` 的检索命中数为 0；`ORMConfig` 的 §3.5 清单里 `getConnectTimeout` / `getPoolCheckSql` 都在，唯独缺这两个 getter，§3.3 的 11 个池参数里也缺 `orm_databasePoolMaxWaiting`。
- **描述**：这两个键恰好是**唯一能终止两类挂死**的旋钮：驱动把连接停在 `Connecting` 空转（源码注释写明「原来这个等待没有上限、且是纯空转」，默认 5s 后抛 `ConnectionException`），以及池耗尽时 `get(timeout: Duration.Max)` 的等待上限（默认 30s 后返回 `None`）。文档缺项的直接后果是运维只能改代码或读源码才发现它们，线上卡死时无从调参。
- **建议**：`orm_connectingTimeout`（毫秒，默认 5000）补进 §3.1 表并在 §3.5 加 `getConnectingTimeout`；`orm_databasePoolMaxWaiting`（毫秒，默认 30000，`<=0`=无限）补进 §3.3 表与 §3.5。中文 `README.md` 同缺（属其他部分范围，建议同批改）。

### [轻微][存量] #5 6 个未使用的 `import`（宏 5 个 + 用例 1 个）

- **位置**：`f_orm/src/ProtectedMacros/EmbedSensitive.cj:19`（`std.database.sql.SqlOption`）、`20`（`stdx.crypto.crypto.*`）、`21`（`fountain::f_config.*`）、`22`（`fountain::f_macros.*`）、`24`（`fountain::f_base.UnsafeBytes`）；`f_orm/src/base/ArgAnyBinding_test.cj:20`（`std.collection.ArrayList`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `EmbedSensitive.cj` 全文只用到 `std.ast.*`（`Tokens` / `quote`，`28-42`）、`ORMConfig`（`23` 导入、`30-39` 使用）与 `EmbedSensitive`（`26` 导入、`42` 使用）；`SqlOption` / `crypto` / `f_config.*` / `f_macros.*` / `UnsafeBytes` 在 18-43 行内零出现（`f_config.*` 的那次 `public import` 走的是 `f_config.macros` 子包，与本条 `21` 无关）。`ArgAnyBinding_test.cj` 的 `cases` 用的是 `Array<(String, Any)>`（`45`），全文无 `ArrayList`。
- **描述**：编译期残留，产生 unused 警告，也让「这个宏依赖了 crypto」的误读成立（实际 SM4 在 `f_config` 侧）。
- **建议**：删这 6 行；`EmbedSensitive.cj` 只保留 `std.ast.*`、`fountain::f_orm.wrap.ORMConfig` 与那条 `public import fountain::f_config.macros.EmbedSensitive`。

### [轻微][存量] #6 `testEverySupportedTypeStillBinds` 的「全类型」护栏漏掉 4 个标量族与几乎所有 `?T` 变体

- **位置**：`f_orm/src/base/ArgAnyBinding_test.cj:45-67`（21 条 `cases`）；对照 `f_orm/src/base/RootDAO.cj:252-306`（`arg(Any)` 的分支表）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14「测试覆盖与承诺不符」、§11
- **证据**：静态确定 —— 用例文档注释（`27-33`）声称「每个受支持类型（含 `Data` 包装值）都必须命中具体分支」，但 `cases` 里没有 `Float16`、`BigInt`、`Decimal`、`InputStream`（这 4 个都在 `arg(Any)` 的标量段：`RootDAO.cj:263`、`273`、`274`、`278`），`?T` 只有 `nbool` / `nint64` / `nnull` 三个，`Data` 只有 `DataString` / `DataReal`（缺 `DataBool` / `DataDuration` / `DataDateTime` / `DataCollection` / `DataAny` / `DataNone`）。
- **描述**：删掉 `arg(Any)` 里 `Float16` / `BigInt` / `Decimal` 分支，或用例所谓的「`Data` 可达性护栏」被破坏时，这条用例仍然全绿——它实际覆盖 16/20 个标量分支、2/20 个 `?T` 分支、2/8 个 `Data` 子类，`?Any` 也未覆盖。
- **建议**：把 `RootDAO.cj:258-306` 的分支表逐条镜像成 `cases`（`?T` 用 `Some`/`None` 各一），或用宏/反射按类名驱动；至少补齐 `Float16` / `BigInt` / `Decimal` / `InputStream` 与 `DataBool` / `DataNone`。

### [轻微][存量] #7 该护栏只看返回值 `'?'`，无法发现「返回 `'?'` 但没有绑定参数」的回归

- **位置**：`f_orm/src/base/ArgAnyBinding_test.cj:70-76`（只断言 `sql != '?'`）；`f_orm/src/base/SqlExecutor.cj:48`（`private var args` 外部不可读）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14「护栏强度不足」、§11
- **证据**：静态确定 —— 用例名与注释都写「StillBinds」（`28-31`：「`arg(x)` 内部调 `executor.add`」），但断言只比较 `arg` 的返回值；`SqlExecutor.args` 是 `private`（`SqlExecutor.cj:48`）、`SqlArgs` 也没有公开 `size`，用例**没有办法**观察绑定数。同一个仓库里的 `ArgBindCount_test.cj:41-54` 已经演示了可行做法（用 `MOCKDB.execution` 的 `args` 参数数数）。
- **描述**：把某个分支从 `arg(x)` 改成字面 `'?'`（漏 `add`）时，文本仍为 `?`、用例仍绿，运行期表现为「SQL 里 1 个占位符、0 个参数」，驱动报参数个数不符或绑定错位——正是这条护栏声称要防的形态。
- **建议**：给 `SqlExecutor` 加只读的 `prop argCount: Int64`（或包内可见的测试钩子），或改用 `MOCKDB.execution` 捕获 `args`，断言「占位符数 == 绑定数 == 1」。

### [轻微][存量] #8 计时型用例单次采样 + 墙钟阈值，共享 CI 机上可能误报

- **位置**：`f_orm/src/base/ArgAnyBinding_test.cj:84-107`（`91-101` 两段 1000 次循环各只跑一遍，`103` 断言 `anyNs <= typed * 10 + 1000`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §6.1「基准口径」（单次最快值 / 无重复轮次不可作为结论）、§11「测试可靠性」
- **证据**：待确认 —— 结构上确定：无预热、无多轮取中位数、无离散度，阈值是相对倍数 + 1µs 绝对容差；是否会翻红取决于 CI 机器的 GC/调度抖动（`typed` 约 45ns/元素时阈值约 1.45µs/元素，一次 1.4ms 的停顿摊到 1000 次就会击穿）。
- **描述**：这是模块里唯一把**性能比值**写成硬断言的用例；在共享构建机上它是「偶发红」的常见来源，而偶发红通常被当成噪声忽略，最终等于失去护栏。
- **建议**：改成「先跑 3 轮预热，再取 5 轮中位数」，并把阈值放宽到注释里实测值（≈1.5×）的 3~5 倍；或把它降级为 `@Bench` / 打印而不 `@Assert`，真正的回归门槛放到 `cjpm bench` 对照。

### [轻微][存量] #9 README 的 `UPDATE<UserPO>(map)` 示例注释写错 WHERE 列

- **位置**：文档 `f_orm/README_en.md:790-792`（`map[...id] = 1` 后 `executor.UPDATE<UserPO>(map) // where username = ?`）；实现 `f_orm/src/base/SqlPartial.cj:148-179`（`idField`/`idColumn` 取自 `m.isId`，`174` 用主键列拼 `WHERE`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「示例与实现不符」
- **证据**：静态确定 —— `UPDATE<T>(values: Map<String, Any>)` 遍历 mapper 时把 `isId` 的列记为 `idColumn` 并在 `continue` 前跳过（`155-159`），末尾 `sql.append(' WHERE ').append(involve(idColumn))`（`174`），故 `map` 里带 `id=1` 时生成的是 `where id = ?`（`username` 只进 `SET`）。
- **描述**：「无 id 版 UPDATE 用主键做 WHERE」正是这一节要讲的重点（`768-772` 的正文写对了），只有示例行内注释写反，读示例的人会以为可以在 `SET` 里改主键或 WHERE 用的是别的列。
- **建议**：改成 `// where id = ?`。

### [轻微][存量] #10 README 头部元信息与 `cjpm.toml` 不一致（版本号、依赖清单）

- **位置**：`f_orm/README_en.md:3`（`version 1.3.6`）、`5-6`（依赖清单）；`f_orm/cjpm.toml:31`（`version = "1.3.2021"`）、`1-17`（含 `fountain::f_dbpool`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档与工程元数据不符」
- **证据**：静态确定 —— 版本号两处不同；依赖清单漏 `fountain::f_dbpool`（正文 §3.3 又说 `DatabasePool` 已迁到该模块，前后不一致），另漏 `test-dependencies` 的 `fountain::f_mockdb`（`cjpm.toml:19-20`，属测试依赖，可不写）。
- **描述**：使用者按头部清单做依赖预检时会漏装 `f_dbpool`；版本号不一致则让「本文档对应哪个产物」无法判断（`1.3.2021` 本身也像是 `1.3.6` 之类的笔误）。
- **建议**：以 `cjpm.toml` 为准刷新头部；`f_dbpool` 补进清单；顺便确认 `1.3.2021` 是否是预期的版本号。

### [轻微][存量] #11 `doc/优化方案.md` 的「待修复」与用例计数已过期

- **位置**：`f_orm/doc/优化方案.md:46-49`（`[P4] SchemaFinder.cj 残留注释块 … SchemaFinder.cj:21-38 … 待修复`）、`61-63` / `74-78`（`migro_test.cj (12 测试用例)`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期」（行号 / 结论漂移）
- **证据**：静态确定 —— `f_orm/src/migro/SchemaFinder.cj:20` 起直接是 `public interface SchemaFinder {`，21-38 行是接口方法声明，**没有**被注释的字段块，该「待修复」项已不存在；`f_orm/src/migro/migro_test.cj` 现有 15 个 `@TestCase`，不是 12 个。
- **描述**：审计文档的剩余待办里混着一条已完成项，会让下一轮审查重复排查；用例计数偏差会让「覆盖是否减少」无法判断。
- **建议**：删掉 `SchemaFinder.cj:21-38` 那条（或标「已随 xx 清理」），用例计数改成当前值；行号引用统一改成「符号名」而非行号，避免每次重构后失效。

<!-- 第 3 部分 -->

### [严重][存量] #1 `ParenExpr.toString()` 对内层表达式求值两次：参数被重复绑定，占位符与参数数量失配

- **位置**：`f_orm/src/base/LogicalExpr.cj:252-258`（`253` 行 `let s = expr.toString()`、`257` 行 `return '(${expr})'`）；构造入口 `f_orm/src/base/RootDAO.cj:509-510`、`515-516`、`521-522`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`，`253-256` 为 `e494170cc4 2026-09-15` 追加）
- **判据**：review-checklist §11「逻辑错误」、§10「正确性」、§2「近似重复导致的行为漂移」（`ParenExpr` 用 `isEmpty()`、其它处用 `emptyLogicalExpr`，见 #17 说明）
- **证据**：静态确定 —— `CmpExpr.toString()`（`125-155`）在 `136` / `144` 行调用 `exec.arg(...)`，而 `arg` 的实现是「`executor.add(x)` + 返回 `?`」（`RootDAO.cj:330-332` 的注释原文：`arg(x)` 内部是 `executor.add(x)` 并返回 `'?'`），即 **`toString()` 不是纯函数**。`ParenExpr.toString()` 先 `expr.toString()` 取一次用于判空，再在 `257` 行用插值 `${expr}` 取第二次 ⇒ 内层每个比较值被 `add` 两次。`RelationExpr.toString()`（`227-249`）内部也是逐子表达式 `toString()` 一次，所以 `ParenExpr(RelationExpr(...))` 会把整棵子树的参数全部绑定两遍。
- **描述**：`RootDAO.AND(exprs: () -> Array<LogicalExpr>)` / `OR` / `NOT` 三个 lambda 变体（`509-522`）都包了一层 `ParenExpr`，这层包装是 DAO DSL 的对外能力（`RootDAO` 是 `public interface`，仓内 `grep 'AND {'` 零命中，说明这条路径交给下游使用、没有回归用例）；只要 DAO 方法里写了 `AND { [user.age.gt(18), user.name.eq('x')] }`，最终 SQL 得到 `( age > ? AND name = ? )` 两个占位符，而 `args` 里是 4 个值（18、'x'、18、'x'），第一次执行就会因参数个数不匹配报驱动错误；若驱动按位置宽松绑定，则第 3、4 个参数会与后续谓词的占位符错位，**静默查错数据**。同一根因还让该 DSL 无法缓存/重放 SQL 文本（每次 `toString` 都在改参数表）。
- **建议**：`ParenExpr.toString()` 只求值一次：`let s = expr.toString(); if (emptyLogicalExpr(s)) { '' } else { '(${s})' }`（同时把空判断口径统一成 `emptyLogicalExpr`，与 `RelationExpr:239` 一致）。更彻底的做法是把表达式求值改成「一次遍历产出 (sqlText, args)」的纯函数、由执行器统一绑定，`toString()` 只读缓存结果；短期至少要给出「表达式对象只允许 `toString()` 一次」的约束并加用例（`AND { [col.gt(1)] }` 断言 `args.size == 1`）。

### [严重][存量] #2 `BETWEEN` 的一侧是 `Column`、另一侧是值时，`Column` 被当作**字符串值**绑进参数

- **位置**：`f_orm/src/base/LogicalExpr.cj:130-139`（`133-136` 行只区分了「两边都是 `Column`」与「其它」）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误 / 契约与实现不符」、§10「正确性」
- **证据**：静态确定 —— `CmpExpr.toString()` 的 BETWEEN 分支只写了两个 case：`case (x: Column, y: Column)` 走「裸列名」，其余全部落到 `case _ => ' ${column} ${op} ${exec.arg(x[0])} AND ${exec.arg(x[1])} '`（`136` 行）。而 `Column <: SqlExpr & ToString`（`Columns.cj:100`），`SqlExecutor.add(arg: Any)` 对 `ToString` 走 `add<ToString>(x)` → 最终 `case x => add(x.toString())`（`SqlExecutor.cj:610-653`、`859-866`），即把 `Column.toString()` 的结果（形如 ` "price" `，带引号的列名文本）当成**绑定值**加进 `args`。
- **描述**：`SqlExpr.BETWEEN(one: Any, two: Any)`（`Columns.cj:87-89`）的签名允许任意组合，且实现专门为「两边都是列」留了分支，说明「列参与 BETWEEN」是设计意图；于是 `price.BETWEEN(cost, 100)` 这种最自然的写法（上界常量、下界来自另一列）不会被编译器拦住，却生成 `price BETWEEN ? AND ?` 并绑定 `'"cost"'` 字符串，语义从「与另一列比较」变成「与字符串 `"cost"` 比较」——多数数据库会直接报类型错，宽松类型（SQLite）则静默返回错误结果集。仓内 `grep '\.BETWEEN('` 只命中文档注释（`macros/DAO.cj:67`），这条路径同样无回归用例。
- **建议**：把 BETWEEN 的两个操作数都按 `SqlExpr` 分流（`case x: SqlExpr => '${x}'`，否则 `exec.arg`），与 `CmpExpr` 的 `case _ => match(value) { case x: SqlExpr => ... }`（`141-145`）保持同一套规则；或直接提供 `BETWEEN(one: SqlExpr, two: Any)` / `BETWEEN(one: Any, two: SqlExpr)` 重载让类型系统兜住。补两条用例：`(Column, Int64)` 与 `(Int64, Column)`。

### [严重][存量] #3 `DirtyTag.beforeDirty` 是**进程级共享**布尔、脏字段表却是线程私有的，`clearAll()` 只清当前线程：并发读+关闭会丢更新，导致 `UPDATE ... dirty` 静默漏写

- **位置**：`f_orm/src/base/DirtyTag.cj:23`（`DIRTY_TAGS` 全进程共享）、`26`（`dirtyFields` 是 `ThreadLocal`）、`50-58`（`setBeforeDirty` 读旧值再整体替换）、`72-79`（`clear<T>` / `clearAll`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入」、§11「并发正确性」
- **证据**：静态确定 —— 三条互相印证的事实：
  1. `beforeDirty` 是 `DirtyTag` 的普通 `let` 字段（`25`），`DirtyTag` 以 `TypeInfo` 为键存进 `ConcurrentHashMap`（`23`），所有线程读写同一个条目；
  2. `setBeforeDirty<T>()`（`50-58`）是「`get` → 读 `tag.beforeDirty` → 构造新 `DirtyTag` → `DIRTY_TAGS[typeInfo] = 新值`」的**非原子读改写**；`clear(typeInfo)`（`66-71`）结构相同（写入 `beforeDirty: false`）；
  3. 两者唯一的调用点是按线程执行的 `SqlExecutor`：`setBeforeDirty` 在 `first<T>` / `list<T>` 的 `finally`（`SqlExecutor.cj:537`、`562`），`clearAll` 在 `close()`（`SqlExecutor.cj:172`）——每个线程在请求结束各自 close 一次。
- **描述**：`SqlExecutor` 是线程封闭的（`currents` / `current` 都是 `ThreadLocal`，`SqlExecutor.cj:44-45`），但 `DirtyTag` 的「是否已开启脏跟踪」开关是全局的。两种坏交错都有实际后果：(a) 线程 A `close()` 的 `clearAll` 与线程 B 读完结果集后的 `setBeforeDirty<T>` 并发，B 的写入可能被 A 的替换覆盖 ⇒ B 后续对该类型对象的 setter 不再记录脏字段，`UPDATE<T>(..., dirty: true)` 读到空集合直接 `return 0`（`SqlPartial.cj:226-231`）——**对象改了、SQL 一条没发**；(b) 反向丢失 `clear` ⇒ 跟踪开关永久开着，且 `clear` 只执行 `tag.dirtyFields.set(None)`（`68`），**只清调用线程的 `ThreadLocal`**，其它线程的旧脏字段集合原样保留，下一次「读 → 改两个字段 → UPDATE dirty」会把上一轮残留的字段一起写回。`ThreadLocal` 与共享布尔混用使这套状态无法用单把锁简单修好。
- **建议**：把 `beforeDirty` 也收进 `ThreadLocal<Bool>`（与 `dirtyFields` 同生命周期，语义变成「本线程是否已为 T 开启跟踪」），`clearAll` 只清本线程；若必须保持「类型级一次性开关」，则改用 `ConcurrentHashMap.compute` / CAS 做原子替换，并把 `dirtyFields` 的 `set(None)` 改成「按线程注册表遍历清理」或直接换成 `ThreadLocal.withInitial`+显式 `remove`。补用例：两线程各自 `first<T>()` 后各自改字段，再各自 `UPDATE dirty:true`，断言两次更新的列集合互不含对方字段。

### [一般][存量] #4 `ChooseCondition` 在非 `argInSql` 路径**无条件**绑定参数：片段型 `partial` 多出 `"()"` 参数与悬空 `?`，未设 `otherwise` 时多出 `? `

- **位置**：`f_orm/src/base/ChooseCondition.cj:80-105`（`91-93` 与 `102-104` 两个 `else` 分支）、默认兜底 `22`、`54-59`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误 / 空值未处理」、§3「契约与实现不符」
- **证据**：静态确定 —— `gen()` 的四个分支里，只有 `_argInSql == true` 且 `arg` 是 `ToString` / `Unit` 时才「不绑定、只拼片段」；`_argInSql == false` 时无论 `arg` 是什么都执行 `executor.add(arg)` 并输出一个 `?`。两条具体路径：
  - `partial(partial: () -> String)` 经 `callee`（`57-59`）包装成 `('片段', ())`，`arg` 是 `Unit`；`Unit` 实现 `ToString`（`cangjie-doc/md/doc/core.md:29`），于是 `add(())` 落到 `SqlExecutor.cj:652` 的 `case x => add(x.toString())`，把字面量 `"()"` 绑进参数；
  - `otherwise` 未设置时取 `emptyPartial = {=> ('', '')}`（`22`），`frag` 为空、`arg` 为 `''`，走 `102-104` 行 ⇒ 输出 ` ? `（无左侧列名）并把空串绑进参数。
- **描述**：`partial(() -> String)` 与 `otherwise(() -> String)` 两个重载是公开 API，语义只能是「只提供 SQL 片段、不带值」；但在默认（参数化）模式下它们必然多生成一个占位符，例如 `choose.condition{...}.partial{'1 = 1'}.done()` 产出 `1 = 1 ?`、参数多一个 `"()"`，语句直接失败；忘记写 `otherwise` 时产出 `and ?`（绑定空串），要么语法错，要么被当成恒真/恒假谓词改变过滤结果。测试 `ArgInSql_test.cj:161-183` 只覆盖了 `argInSql` 打开的情况，等于把这个失败路径排除在回归之外。
- **建议**：`gen()` 里按「片段是否自带值」分支，而不是按 `argInSql` 分支：`arg` 为 `Unit` 时只 `' ${frag} ${delimiter} '`、不 `add`；`frag.isEmpty() && arg 为空串` 时整体返回 `''`（而不是 `' ? '`）。补两条用例：不带 `argInSql` 的 `partial{'1 = 1'}` 与不设 `otherwise` 的 `choose`，断言 SQL 无多余 `?` 且 `args.size == 0`。

### [一般][存量] #5 `LoopCondition` 传给 `condition` / `partial` 的 `Int64` 是「已接受元素个数」，不是元素下标

- **位置**：`f_orm/src/base/LoopCondition.cj:88-112`（`90` 行 `var i = 0`、`91` 行 `for (v in values where _condition(v, i))`、`111` 行 `i++`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「语义与命名不符 / 边界」、§10「正确性」
- **证据**：静态确定 —— `where` 子句在每次迭代**先于**循环体求值，而 `i++` 在循环体末尾（`111`），被 `where` 过滤掉的元素不会让 `i` 前进。因此 `_condition(v, i)` 收到的 `i` 等于「此前通过条件的元素个数」，而不是「当前元素在 `values` 中的位置」；`_partial(v, i)`（`95`）同理。
- **描述**：参数名是 `i`、类型是 `Int64`，任何按「下标」使用的写法都会得到错误结果，而且是**静默**的：`condition {v, i => i >= 2}`（想跳过前两条）永远在 `i == 0` 上判定，一条也进不来 ⇒ 生成的 `WHERE` 少了整段条件，查询范围变大；`partial {v, i => ('c${i} = ?', v)}`（按下标取列）在有任何元素被过滤后会错位到别的列上。`ArgSqlText_test.cj:54` 的 `anyPartial = {v, i => i}` 正是把它当下标用（该用例全靠所有元素都通过才成立）。
- **建议**：把计数与下标分开：`for ((idx, v) in values.iterator().enumerate())` 或手工 `while` + `let cur = i; i++` 放在 `where` 判定**之前**；若确实想保留「已接受个数」语义，就把形参改名 `acceptedCount` 并在 README 写清。补用例：`[1,2,3,4]` + `condition {v, i => i != 0}`，断言只输出第 2–4 个元素且 `partial` 收到的是 1、2、3。

### [一般][存量] #6 `IN` / `loop` 两端都没处理：0 个元素生成 `in ()`（语法错误），N 个元素没有上限（占位符串与参数表随输入线性膨胀）

- **位置**：`f_orm/src/base/MeetCondition.cj:72-111`（`74`/`94` 行先写 `' in ('`，循环体内无「空则整体返回空」），`f_orm/src/base/LoopCondition.cj:85-116`（`115` 行无条件拼 `wrapLeft`/`wrapRight`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`、`e494170cc4 2026-09-15`）
- **判据**：review-checklist §11「空集合未处理」、§5「OOM：无界容器 / 无拒绝路径」
- **证据**：静态确定 —— `MeetCondition.IN(空集合)`：`i` 恒为 0，`builder` 得到 `' in ('` + `')'` = `' in () '`，`frag()` 再拼成 `'<partial>  in ()  '`。`LoopCondition(空集合).wrap('(', ')').done()`：`sqlFrag` 经 `Condition.trim('','')` 变成单个空格（`ConditionTrim_test.cj:61` 断言 `trim('') == ' '`），再被 `115` 行拼成 ` (   ) `。两者都不是合法 SQL，而且**没有**像 `RootDAO.IN`（`RootDAO.cj:447-453`）那样在空集合时返回 `''`。上限方面：元素逐个 `executor.add` + 逐个 append `?`（或 `StringBuilder`），全流程无计数、无阈值、无分批。
- **描述**：`ex.meet(cond, 'id').IN(ids)` / `ex.loop(ids)....done()` 是公开写法，`ids` 常来自上游查询结果（可能为空，也可能上万）。空集合时 SQL 变成 `id in ()`，语句失败；元素很多时，一条语句的占位符文本与 `SqlArgs` 同步线性增长，既可能撞数据库的参数个数上限（PostgreSQL 65535、SQLite 999 之类），也会在驱动侧一次性物化全部绑定值——没有任何「拒绝/分批」路径。仓内 `IN(empty)` 有用例（`ArgSqlText_test.cj:65` 断言 `ex.arg(empty) == ''`），但 `MeetCondition.IN` / `LoopCondition` 这两条路径没有用例。
- **建议**：空集合统一返回 `''`（与 `RootDAO.IN` 对齐，交给外层 `Condition.trim` 裁掉）；给出可配置的分批阈值（如 `ORMConfig.maxInSize`，超过则拆成多个 `OR id in (...)` 或临时表），并在超限时抛明确异常而不是拼一条超长 SQL。补空集合与 10k 元素两条用例。

### [一般][存量] #7 `NullableGroupedQueryMapper.populate` 的 `prevSize == list.size` 恒为假：`ignoreNone: false` 承诺的 `None` 元素永远不会写入

- **位置**：`f_orm/src/base/GroupedQueryMapper.cj:90-104`（`92` 行取 `prevSize`、`95` 行无条件 `list.add(groupedValue)`、`100` 行判 `prevSize == list.size`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §1「恒真恒假分支」、§11「逻辑错误」、§3「契约与实现不符」
- **证据**：静态确定 —— `add` 在 `95` 行先执行，判定在 `100` 行，此时 `list.size` 必然等于 `prevSize + 1`，条件恒假；`ignoreNone` 只影响这个死分支，`let ignoreNone!` 事实上没有可观察效果。宏侧确实按 `ignoreNone: false` 生成这个映射器（`f_orm/src/macros/QueryMappersGenerator.cj:294-299`，可空实体列表且无转换器时）。
- **描述**：可空的分组关联（`ArrayList<?Entity>`）在左连接结果全为 NULL 时，期望得到 `[None]`（这正是 `ignoreNone: false` 的字面语义），实际得到「一个所有字段都为 `None` 的空实体」并被无条件追加。调用方据此判断「有没有关联记录」会永远得到「有」，属于静默的语义错误；而 `ignoreNone: true` 时则应当丢弃整组，当前实现同样做不到（只是恰好没写 `None`）。
- **建议**：按「本组是否有任一列非 NULL」判定：先把 `mappers` 的取值结果收集起来（`mapper.dataType.get(result)`），全为 `None` 时 `if (ignoreNone) return o else list.add(None)`，否则才 `creator()` + 逐字段写。补用例：驱动返回一行全 NULL 的左连接结果，断言 `ignoreNone=false` 得到 `[None]`、`=true` 得到 `[]`。

### [一般][存量] #8 `InExpr` / `In2Expr` 用 `Column.name` 直出，绕过标识符引用与表别名

- **位置**：`f_orm/src/base/LogicalExpr.cj:175-181`（`178` 行 `' ${x.name} ${op} ...'`）、`190-196`（`193` 行同）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「语义与命名不符 / 与同族实现漂移」、§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— 同文件的 `CmpExpr`（`135-144`）用 `${column}`（走 `Column.toString()`，内部 `exe.involve(...)` 加引号并带 `tableAlias_`，`Columns.cj:120-143`），而 `InExpr` / `In2Expr` 专门 `match` 出 `Column` 后取 `x.name` 原始字段名；`case x =>` 分支才用 `${x}`。
- **描述**：`user.name.IN(list)` 生成 ` name IN (?,?) `：没有方言引号（MySQL 下 `order`、`key` 这类列名直接语法错），也没有表别名（多表 join 时列名歧义 → 报错或解析到另一张表）。同一文件里两种取列方式并存，说明这是遗漏而非设计。
- **建议**：两个 `match` 分支合并为 `' ${x} ${op} ${exec.arg<...>(value)} '`（`Column.toString()` 已处理 `*`、别名、排序与引用）；若要保留「不带排序/别名」的语义，应显式调 `executor.involve(x.name)` 而不是裸 `name`。补用例：`Column('order').IN([1,2])` 断言输出含方言引号。

### [一般][存量] #9 executor 生命周期耦合：`toString()` 阶段就从**线程内 current executor** 取连接并绑定参数，跨线程构造 SQL 或跨语句复用构建器会静默绑错

- **位置**：`f_orm/src/base/Columns.cj:102-106`（`Column.executor` → `SqlExecutor.getCurrent()`）、`120-143`（`toString` 内 `exe.involve`）、`f_orm/src/base/LogicalExpr.cj:129`/`144`/`148`（`ExprSqlExec()` + `exec.arg` + `getCurrent()`）、`f_orm/src/base/ExtendString.cj:26-31`（`getCurrent().partials`）
- **来源**：存量（快照无基线；`git blame`：`9fe28abd50 2026-09-13` / `e494170cc4 2026-09-15`）
- **判据**：review-checklist §11「契约与实现不符」、§10「设计合理性 / 仓颉语言特性」、`fountain-baseline.md` §2「不跨语句复用 `SqlExecutor`」
- **证据**：静态确定（机制）+ 待确认（是否有跨线程构造 SQL 的调用方）—— `SqlExecutor` 按线程隔离（`SqlExecutor.cj:44-45` 的 `currents` / `current` 都是 `ThreadLocal`，`133-135` 的 `getCurrent()` 取不到就 `getOrThrow` 抛 `NoneValueException`）；而 `Column.toString()` / `CmpExpr.toString()` / `String.AND|OR|NOT` 三个入口都在**字符串化时**读取 current 并往它的 `args` / `partials` 写入。
- **描述**：两条现实风险：(a) 在 A 线程拼好 SQL 文本、在 B 线程 `setSql(...).list()` 执行——参数落在 A 的 executor 上（A 若无 current 则直接抛 `NoneValueException`），B 执行时占位符无值；(b) 先 `ORM.executor()` 拿到 `ex`、`ex.close()` 归还连接后，再让 `Column` / `ExtendString` 参与字符串拼接，`add` 会写进已关闭实例的 `args`（`close()` 只清 `current` 与 `currents` 映射、`cache`，不清 `args`，见 `SqlExecutor.cj:153-174`），下一个 `executor()` 是**新实例**，参数丢失。本模块自己也把「单条语句执行后 current 会被清空、每次操作重新 `executor()`」写进基线，说明这条约束客观存在，但构造层没有把它显式化（参数藏在 `toString()` 里，调用方看不出来）。
- **建议**：把「求值」与「绑定」拆开：表达式树只产出 `(sql, Array<Any>)`，由执行器在 `setSql` 后统一 `add`；短期至少在 `getCurrent()` 失败时抛带上下文的 `ORMException('SQL 片段必须在持有 executor 的线程内构造')`，并在 README 写明「片段构造与执行必须同线程、同一语句生命周期」。

### [一般][存量] #10 executor 的 `partials` 缓冲在字符串拼接路径上**只增不清**：长事务内随语句数累积

- **位置**：`f_orm/src/base/MeetCondition.cj:41-49`（`47` 行 `executor.partials.append(sql)`）、`f_orm/src/base/ChooseCondition.cj:113-115`（`114` 行同）、`f_orm/src/base/ExtendString.cj:29-31`；对照「唯一的清理点」`f_orm/src/base/TableClause.cj:136-146`、`191-199`、`208-217`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §5「长期持有 / 无界容器」、§7「缩短生命周期」
- **证据**：静态确定 —— `Partials` 内部是一个 `StringGenerator`（`Partials.cj:19`），`clear()` 只在 `TableClause.condition` / `PAREN` 的 `try/finally` 里调用；`SqlExecutor.clearSql()`（`97-106`）只重置 `sql_` 与 `args`，**不动 `partials`**；`close()`（`153-174`）同样不清（且事务中 `close()` 直接 `return`，`154` 行的守卫）。三个 `append` 点（`MeetCondition.frag`、`ChooseCondition.done`、`String.AND/OR/NOT`）都发生在普通 `setSql` 拼接路径上。
- **描述**：每次 `meet(...).done()` / `choose...done()` / `'x' AND 'y'` 都会把一段 SQL 追加进该线程 executor 的 `StringGenerator`，而这条路径没有对应的释放点。非事务语句结束时实例被 `close()` 摘出 `currents`，随 GC 回收（只是白留一份）；**事务内** `close()` 被 `tx.isNone()` 挡住，同一个 executor 贯穿整个事务，于是「事务里跑了 N 条语句」就留下 N 段永不使用的片段文本——批量任务里是可观且无界的增长，直到事务结束。另有一个正确性隐患：这些残留片段若被后续某个 `TableClause.condition{}` 在 `clear()` 之前读到（当前实现先 `clear()` 再执行，所以暂不成立），会拼进别人的 WHERE。
- **建议**：`clearSql()` 里同步 `partials.clear()`（或让 `MeetCondition`/`ChooseCondition` 不再往共享缓冲追加、只返回字符串）；`close()` 的早退分支至少也应 `partials.clear()`。补用例：同一事务内连做 1000 次 `meet(...).done()`，断言 `partials` 内部长度不随次数增长（需要暴露只读长度或在 `Partials` 上加计数）。

### [一般][存量] #11 `Condition.SET` / `WHERE` 把 `delimiter` 无条件复位成 `''`：嵌套调用会清掉外层的分隔符

- **位置**：`f_orm/src/base/Condition.cj:40-52`（`42` 设 `','`、`50` 复位 `''`）、`54-69`（`59` 设、`67` 复位）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误（状态未保存/恢复）」、§12.1「共享可变状态」
- **证据**：静态确定（机制）+ 待确认（嵌套调用是否存在）—— `delimiter` 是 `ThreadLocal<String>`（`22-30`），`SET` / `WHERE` 用 `try/finally` 把它设为本次分隔符并在 `finally` 里写 `''`，而不是恢复进入前的值。`ChooseCondition.gen`（`85-104`）与 `MeetCondition.frag`（`43`）都依赖这个值拼分隔符。
- **描述**：只要在外层 `WHERE { ... }` / `SET { ... }` 的片段构造过程中再调用一次 `Condition.WHERE(...)` 或 `SET(...)`（典型场景是用 `MeetCondition.EXISTS { ... }` 里再写一个子查询的 WHERE，或手工拼嵌套 `SET`），内层返回后 `delimiter` 变成 `''`，外层后续片段全部丢失 `and` / `,` 分隔符 ⇒ 生成 `a = ? b = ?` 这类语法错误的 SQL。线程隔离本身是对的（不会跨线程串扰），问题只在「保存/恢复」缺失。
- **建议**：`finally { delimiter = previous }`（进入时先 `let previous = Condition.delimiter`），或把分隔符改成随 `WHERE` / `SET` 作用域传递的参数（`LoopCondition` / `MeetCondition` 已在构造时持有 executor，同样可以持有 delimiter），彻底去掉这个线程内隐式状态。补用例：嵌套两层 `WHERE`，断言外层分隔符仍为 `and`。

### [一般][存量] #12 `SqlDialect.involvedIdentifier`：「已带引号即直通」+「只拆第一个 `.`」，前者是注入面、后者让三段式标识符引用错位

- **位置**：`f_orm/src/base/Dialect.cj:44-52`（`45-46` 行直通、`47-48` 行按第一个 `.` 切分）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §10「安全性：注入」、§11「逻辑错误 / 边界」
- **证据**：静态确定 —— `if (identifier.startsWith(startInvolver)) { return identifier }`：只要字符串以引号字符开头就**原样返回**，不再做任何包装/转义。所有标识符最终都走这里（`SqlPartial.cj:95-100` 的 `involve` → `dialect.involvedIdentifier`），而标识符来源包括 `Column(name)`、`AS(alias)`、`Columns.tableAlias(alias)` 等调用方传参。
- **描述**：(a) 安全面：任何把外部输入当列名/别名/表别名传入的调用方（`AS(用户输入)`、按字段名动态拼接的查询构造器）都能用 `"` 开头绕过引用，后续 SQL 文本直接进入语句——`involvedIdentifier` 事实上是「引用函数」，使用者会默认它安全；(b) 正确性：`schema.table.column` 只在第一个 `.` 处切分，产出 `"schema"."table.column"`，引用错位（同名的 schema 限定查询直接失败）。
- **建议**：直通分支改为「已完整加引号」的严格校验（首尾都是 `endInvolver` 且中间不含引号字符），否则一律重新包装并对内嵌引号做转义（MySQL 用 ```` `` ````、其余用 `""`）；切分改用 `identifier.split('.')` 逐段引用。同时在 README 明确「标识符必须来自代码常量，不得传用户输入」。

### [一般][存量] #13 `Columns.tableAlias()` 写的是**单例**上的可变字段：别名跨查询粘滞、跨线程串扰

- **位置**：`f_orm/src/base/Columns.cj:28-32`（`protected var tableAlias_` + `tableAlias(alias)` 直接赋值）；单例来自 `f_orm/src/macros/QueryMappersGenerator.cj:486-489`（`static let instance = $columnsName()`，`tableColumns()` 返回该实例），读取点 `QueryMappersGenerator.cj:471`（每列 `.$columnName.tableAlias(super.tableAlias_)`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §12.1「共享可变状态无保护」、§11「契约与实现不符」
- **证据**：静态确定（机制）+ 待确认（仓内无调用点）—— `TableMetas`/`tableColumns()` 返回的是 `static let instance`，`tableAlias` 是 `public func` 直接在它身上赋值，没有副本、没有复位入口、没有同步；`toString()` 每次都读这个字段。
- **描述**：`Q.tableColumns().tableAlias('u')` 一次调用之后，该实体在所有线程、所有后续查询里的列前缀都变成 `u.`，直到有人显式 `tableAlias('')`；两个线程同时对同一实体设置不同别名会互相覆盖，产生「A 的查询用了 B 的别名」这类极难定位的错误。仓内目前没有调用点（grep `tableAlias(` 只命中定义与宏生成代码），属于给下游埋的坑。
- **建议**：改成不可变/返回值语义：`public func tableAlias(alias: String): C`（或返回 `Columns` 的浅拷贝，`tableAlias_` 用 `let` 并在构造时注入），让生成器的 `static let instance` 退化成「模板」；若必须保留原地修改，至少把别名做成 `ThreadLocal<String>` 并在 `SqlExecutor.close()` 里复位。

### [轻微][存量] #14 两套语义相同的三值枚举 `CondRelOp` / `RelationOp`（大小写与空格不同）

- **位置**：`f_orm/src/base/CondRelOp.cj:18-29`（`'and'` / `'or'` / `'not'`，小写无空格）与 `f_orm/src/base/LogicalExpr.cj:210-221`（`' AND '` / `' OR '` / `' NOT '`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」，差异点仅「大小写 + 前后空格」
- **证据**：静态确定 —— 两个枚举成员完全相同（AND / OR / NOT），`toString()` 输出只差格式；使用方各一处：`TableClause.PAREN(op: CondRelOp, ...)`（`TableClause.cj:208-222`，拼 `' ${op} ('`）与 `RelationExpr`（`LogicalExpr.cj:229-245`，用 `builder.append(op)` + 自己的空格）。
- **描述**：同一个概念两处定义，任何一边新增运算符（如 `XOR`）都要改两处；格式差异（大小写/空格）已经让「谁负责补空格」变得不一致（`PAREN` 依赖枚举自带空格，`RelationExpr` 自己再补）。
- **建议**：保留 `RelationOp`（表达式树用），`TableClause.PAREN` 改用它并统一在拼装处补空格；`CondRelOp` 删除（`PAREN` 是 `public` API，属破坏性变更，需用户确认下游依赖）。

### [轻微][存量] #15 `Condition.SET` 与 `WHERE` 是同一段模板复制两遍

- **位置**：`f_orm/src/base/Condition.cj:40-52` 与 `54-69`
- **来源**：存量（快照无基线）
- **判据**：review-checklist §2「换控制流 / 字面量复制」
- **证据**：静态确定 —— 两者结构逐行对齐：`try { 设 delimiter → trim(prefix, suffix) → 空则 '' 否则包关键字 } finally { delimiter = '' }`，差异只有 `delimiter`（`,` vs 传入值）、`trim` 的 prefix/suffix（`,`/`,` vs `and|or`/`and|or`）、关键字（`' SET ${p} '` vs `' WHERE ${p} '`）。`#11` 的缺陷正是这两份副本共有的。
- **描述**：模板复制导致的维护风险（修 #11 必须记得改两处），本身没有行为差异。
- **建议**：抽 `private static func wrap(keyword: String, delimiter: String, prefix: String, suffix: String, partial: () -> String): String`，`SET` / `WHERE` 各自一行转调；顺带把 #11 的「保存/恢复 delimiter」统一在模板里做。

### [轻微][存量] #16 复制粘贴的错误文案：两处都写「alias 与 alias 不能同时设置」

- **位置**：`f_orm/src/base/Columns.cj:121-123`（应说 alias 与 **sort**）、`f_orm/src/base/LogicalExpr.cj:126-128`（文案写的还是 `SqlFunc alias and SqlFunc alias`，且该类是 `CmpExpr`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §10「可读性 / 必要注释」、§11「语义与命名不符」
- **证据**：静态确定 —— 触发条件是 `alias_.size > 0 && sort.size > 0`（`Columns.cj:121`、`LogicalExpr.cj:126`），文案却重复了同一个词，`LogicalExpr` 那份还提到了不存在的 `SqlFunc` 类型（`SqlFunc` 在 `SqlFunc.cj`，本文件未定义）。
- **描述**：用户按异常文案排查时拿不到「到底哪两个属性冲突」，`SqlFunc` 更是误导。
- **建议**：改为 `'alias and sort cannot be set at the same time on <type>'`，两处共用同一个常量文案。

### [轻微][存量] #17 `Column('*')` 的别名被静默丢弃；空判断口径与 `RelationExpr` 不一致

- **位置**：`f_orm/src/base/Columns.cj:125-130`（`name == '*'` 分支只处理 `tableAlias_`，`alias_` 直接被忽略）；`f_orm/src/base/LogicalExpr.cj:254`（`isEmpty()`）与 `239`（`emptyLogicalExpr`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「契约与实现不符（静默丢失）」、§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— `Column('*').AS('cnt').toString()` 走 `125-130` 分支返回 `' * '`，`AS` 完全不生效；`ParenExpr` 只把「严格空串」当空，而 `RelationExpr` / `TableClause.appendPartial` 用 `emptyLogicalExpr`（空白与 `()` 也算空）。
- **描述**：`COUNT(*)` 这类写法若用 `Column('*')` 起手再加别名，得到的是无别名的 `*`（结果集列名变成 `*`，映射失败）；空白片段的判定口径不统一则让 `( )` 漏到 SQL 里。
- **建议**：`*` 分支同样处理 `alias_`（`' * AS ${exe.involve(alias_)} '`），或让 `AS` 对 `*` 直接抛 `SqlArgException`；`ParenExpr` 统一用 `emptyLogicalExpr`。

### [轻微][存量] #18 非 public 符号无调用者：`Columns.executor`、`GroupedQueryMapper` 三个 `newXxx`、`SqlDialectMediator` 的 3 个 `lastInsertId` 重载与 `limit`

- **位置**：`f_orm/src/base/Columns.cj:23-27`；`f_orm/src/base/GroupedQueryMapper.cj:27-32`、`52-57`、`78-84`；`f_orm/src/base/Dialect.cj:186-198`
- **来源**：存量（快照无基线；`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §1（`private` 全仓搜、默认 `internal` 在本包及子包搜）
- **证据**：静态确定 —— `Columns` 的 `private prop executor` 在本类内无任何读取（`Columns` 只有 `tableAlias`，列引用发生在子类 `Column` 自己的同名 prop，`102-106` 行是另一个声明）；`newGrouped` / `newGroupedSingle` / `newNullableGrouped` 全仓（排除 `.worktrees`）只有定义处命中，宏也不生成这三个名字（`QueryMappersGenerator.cj` 直接 `new` 构造器）；`SqlDialectMediator` 是 `struct`（非 public），其 `lastInsertId(dialect:id:)` / `(…: DataType)` / `(…: IdQueryMapper)` 与 `limit(dialect:size:offset:)` 全包无调用者（外部一律 `dialect.lastInsertId(...)` 直调，见 `TableClause.cj:489`/`539`）。
- **描述**：死代码占用维护面积，其中 `SqlDialectMediator.lastInsertId` 三个重载还暗示「方言解析应经中介者」，与实际的直调写法冲突，容易诱导后来者走错路径。
- **建议**：删除上述 7 个符号；若 `newXxx` 是给宏预留的扩展点，就在宏里接上或加注释说明「预留、当前无调用」。

### [轻微][存量] #19 测试文件残留：`DAO_test.cj` 整文件被注释，`DriverTest` / `DatasourceCreatorImpl` / `DatasourceTest` 组成的替身链已无使用者

- **位置**：`f_orm/src/base/DAO_test.cj:18-110`（全部为 `//` 注释，无任何声明）；`f_orm/src/base/Driver_test.cj:18-70`；`f_orm/src/base/Datasource_test.cj:18-40`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §1「兼容残留 / 无调用者」、§3「半成品」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）搜 `DatasourceCreatorImpl` 只有 `DAO_test.cj:24` 的注释行；`DriverTest` 只被 `DatasourceCreatorImpl` 使用（`Driver_test.cj:63`、`67`），`DatasourceTest` 只被 `DriverTest` 使用（`55`），`ConnectionTest` 只被 `DatasourceTest` 使用（`38`）——整条链的根（`DAO_test`）是注释，所以四个类在测试构建里都是死代码。文件里没有 `@Test`，`DAO_test.cj` 甚至编译不出任何符号。
- **描述**：`DAO_test.cj` 里注释掉的是一份「手写事务模板 + `@DAO` 示例」，包含 `@QueryMappersGenerator` / `@DAO` 的旧写法，长期不同步会误导读者（其中 `args.meet(!namePrefix.isEmpty(), "username like", "${namePrefix}%", prefix: "where")` 的 `prefix` 参数在当前 `MeetCondition` 上已不存在）。
- **建议**：删除 `DAO_test.cj`；`DriverTest` / `DatasourceCreatorImpl` / `DatasourceTest` / `ConnectionTest` 若没有实际用例驱动，一并删除（`ConnectionTest` 至少还被 `DatasourceTest` 引用，但根已死）；需要 driver/datasource 替身时统一用 `f_mockdb`。

### [轻微][存量] #20 测试替身的空实现没有注释，且 `close()` 与 `isClosed()` 互相矛盾

- **位置**：`f_orm/src/base/Datasource_test.cj:22-27`（`setOption` 空体、`isClosed` 恒 `false`、`close` 空体）、`f_orm/src/base/Connection_test.cj:35-38`（`close()` 空体、`isClosed()` 恒 `false`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §3「空实现」（Null Object 必须注释说明）、§11「契约与实现不符」
- **证据**：静态确定 —— `Connection.close()` 无任何状态变更，`isClosed()` 恒返回 `false`，即「关闭后仍报未关闭」；`Datasource.setOption` 丢弃全部入参。
- **描述**：作为测试替身这是可接受的简化，但没有一行注释说明「为什么可以空」；若将来有用例依赖 `isClosed()` 判断连接是否被正确归还，这个替身会永远给出「没关」，把资源释放缺陷掩盖掉。
- **建议**：加 `private var closed = false`，`close()` 置真、`isClosed()` 返回该值；`setOption` 加一句 `// 测试替身：忽略连接选项`。

### [轻微][存量] #21 `String` 的 `AND` / `OR` / `NOT` 扩展与 `Partials.AND/OR/NOT` 是同一件事的两套实现，且带隐式全局副作用

- **位置**：`f_orm/src/base/ExtendString.cj:18-56`（`append` `29-32` 往 `getCurrent().partials` 追加 `' and '` 等）；对照 `f_orm/src/base/Partials.cj:40-57`
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §2「换控制流 / 跨层复制」、§10「仓颉语言特性（扩展的可见性副作用）」
- **证据**：静态确定 —— `Partials.AND(sql)` 的语义就是「追加 `' and '` + 片段」，`ExtendString` 把同一动作挂到 `String` 的**属性读取**上（`'x'.AND`），两者都写同一个缓冲区；`extend String` 在 `f_orm.base` 包内对所有可见该包的类型生效，`'随便一个字符串'.AND` 就会去取 current executor。
- **描述**：`prop AND: String` 这个名字让「读属性」看起来是纯操作，实际是「往当前线程 executor 的缓冲区追加文本并在当前没有 executor 时抛 `NoneValueException`」。日志、断言、`toString` 里误用都会踩到；两套实现还让「哪个才是推荐写法」没有答案。
- **建议**：删除扩展（`Partials` 已覆盖同一能力），或把它改成显式函数 `sqlAnd(fragment: String)`；若保留，属性名改成动词形态（`asAndClause`）并在注释里写明「依赖线程内 executor」。

### [轻微][存量] #22 `ChooseCondition` 的三组同名重载对字面 lambda 有歧义，用户必须显式标注变量类型

- **位置**：`f_orm/src/base/ChooseCondition.cj:60-65`（`partial(() -> Any)` / `partial(() -> String)`）、`70-75`（`otherwise` 同）、`43-53`（`partial(() -> (String, Any))`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §10「可读性 / 契约」、§14「示例可用性」
- **证据**：静态确定，且有仓内自证 —— `ArgInSql_test.cj:163-165` 的注释原文：「partial / otherwise 的实参先落到带类型的变量上：直接写字面 lambda 会在 `() -> (String, Any)` / `() -> String` / `() -> Any` 三个重载之间产生歧义」，用例本身就是为了绕开这个歧义而多写了两行变量声明。
- **描述**：正常写法 `.partial({=> 'x = 1'})` 编译不过，用户只能写 `let p: () -> String = {=> 'x = 1'}`，文档示例若直接写 lambda 会不可用。
- **建议**：把三个重载合并为一个 `partial(partial: () -> (String, Any))` + 两个命名不同的便捷方法（`partialSql(...)` / `partialValue(...)`），消除重载歧义。

### [轻微][存量] #23 `Condition.trim` 把自定义 `prefix` / `suffix` 直接插进正则，未转义

- **位置**：`f_orm/src/base/Condition.cj:78-80`（`'^\\s*(${prefix})\\s*|\\s*(${suffix})\\s*$'.regex(...)`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §11「边界 / 错误处理」、§10「安全性（把数据当模式）」
- **证据**：静态确定 —— 三个内部组合被预编译成常量（`33-35`、`72-77`），其它取值一律走字符串插值；`prefix = '('` 会构造 `^\s*(()\s*|\s*()\s*$` 这类非法/语义错误的模式并抛正则编译异常，`prefix = '.'` 则退化成「匹配任意字符」。
- **描述**：`trim` 是 `public` API，参数名 `prefix` / `suffix` 读起来像字面量，实际要求是正则片段（只有读过实现才知道 `'and|or'` 是交替）。误用要么抛异常，要么静默裁掉不该裁的字符。
- **建议**：参数改名为 `prefixPattern` / `suffixPattern` 并在 README 写明是正则；或在内部 `Regex.escape(prefix)`（`f_regex` 若有对应能力）并对内部三组继续走常量，另加参数校验（拒绝含 `\` 与括号的取值）给出明确异常。

### [轻微][存量] #24 `SqlDialectMediator.getDialect`：懒填充是「检查-然后-写入」，且未注册方言直接抛 `KeyNotFoundException`

- **位置**：`f_orm/src/base/Dialect.cj:175-182`（`176` 行 `if (dialects.isEmpty())`、`181` 行 `dialects[dialect]`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`）
- **判据**：review-checklist §12.1「检查-然后-写入」、§11「错误处理缺失」
- **证据**：静态确定 —— `dialects` 是 `ConcurrentHashMap`（`184`），但「空则整体填充」不是原子操作：两个线程可同时看到 `isEmpty()` 为真并各自 `lookupList<SqlDialect>()` 全量写入（值相同、结果幂等，但多付一次启动期反射）；`dialects[dialect]` 对缺失键的行为是抛 `KeyNotFoundException`（`ConcurrentHashMap` 的 `[]` 非 `get`），而 `orm_drivers` 里出现未内置的方言名（如 `kingbase`）时，每个 SQL 调用点都会收到这个与业务无关的异常。
- **描述**：启动期多线程同时构造 `TableClause` 时可能重复填充（无害但无必要）；配置写错时错误信息不含「已注册的方言列表」，排查成本高。
- **建议**：用 `computeIfAbsent` 做单次初始化（`dialects.computeIfAbsent(dialect) { ... }` 或加一个 `AtomicBool` 门闩），缺失键改成抛 `ORMException('dialect ${dialect} is not registered, available: ${dialects.keys}')`。

<!-- 第 4 部分 -->

### [严重][存量] #1 `QueryMappers.create` 尾部元素取 `mappers[i]` 而不是 `mappers[i - oMappers.size]`：父类有映射器时必然下标越界

- **位置**：`f_orm/src/base/QueryMappers.cj:41-61`（关键 `53-60`，错在 `58` 行 `mappers[i]`）；调用源 `f_orm/src/macros/QueryMappersGenerator.cj:138-144`（`QueryMappers<$st>.create<$name>(creator, mappers)`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，`55` 行 `i => if (i < oMappers.size)`）
- **判据**：review-checklist §11「边界差一 / 越界」、§10「正确性」
- **证据**：静态确定 —— 数组长度写成 `oMappers.size + mappers.size`（记 `A`、`B`），初始化 lambda 对 `i ∈ [A, A+B-1]` 取 `mappers[i]`；`mappers` 的长度只有 `B`，而最大下标 `A+B-1 ≥ B`（只要 `A ≥ 1`）。宏侧传入的 `mappers` 只含**本类自己的**字段映射器（`QueryMappersGenerator.cj:126-131` 只拼 `generateMappers(name, props…)` 与实例变量），父类映射器由 `oMappers` 提供，因此这两个数组不重叠。
- **描述**：任何 `@QueryMappersGenerator` 标注的类，只要它有一个"有映射字段"的父类（`A ≥ 1`），`create` 在静态初始化 `_qUEry__mAppErs_` 时就会抛 `IndexOutOfBounds`/等价异常，或（若驱动/运行时对数组初始化惰性求值）把父类字段映射错位。当前仓库内没有继承式 POJO 的例子，所以这条路径没有被任何用例守住；一旦下游项目用继承复用基础字段（`create<T>` 的存在就是为这个场景），类加载即失败。附带：`42` 行的 `TypeInfo.of<O>().isSubtypeOf(TypeInfo.of<Object>())` 恒为真，属恒真条件。
- **建议**：改为 `mappers[i - oMappers.size]`，并把条件判空（`if (A == 0) { return None }` 或直接 `Array(…)` 用两次 `add` 拼装）；补一条用例：`open class Base { var id: Int64 }` + `class Sub <: Base { var name: String }`，断言 `Sub.queryMappers().mappers.size == 2` 且字段名分别是 `id` / `name`。

### [严重][存量] #2 `SqlDSL.convert` 的 `Iterable<Data>` 分支每元素**多输出一个 `?`**，且逗号插在占位符之后：占位符数 2N、绑定参数 N

- **位置**：`f_orm/src/base/SqlDSL.cj:112-122`（`115` 递归 `convert` 已写入一个占位符，`117-119` 又写 `','` + `'?'`）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误」、§10「正确性（参数绑定）」
- **证据**：静态确定 —— 两个被证实的点：
  1. `convert` 的标量分支末尾统一 `sqlgen.append(' ? ')`（`125`），所以递归调用 `convert<T>(exe, sqlgen, name, d)` **每个元素已经产出 1 个 `?` 并 `exe.arg(...)` 绑定 1 个参数**；`119` 行又 `append('?')` ⇒ 每个元素 2 个占位符；
  2. 逗号位置在 `if(c > 0)` 之后、`'?'` 之前（`116-119`），而内层文本已经先写进去了，输出形如 ` ? ? ? , ?`（两个元素 4 个占位符），不是 ` (?,?)`。
  可达性：`DataList <: Data & Collection<Data>`（`f_data/src/base/DataList.cj:18-33`，`Collection<Data>` 即 `Iterable<Data>`），它不匹配前面任何 `DataBool/DataString/DataReal/DataCollection<Array<Byte>,Byte>` 分支，必然落到本条分支。
- **描述**：把集合字段（`DataList`）经 `:{path}` 或 `setSqlFromObject` 绑定进 `in (...)` 时，生成 SQL 的占位符数是参数数的 2 倍且逗号错位。驱动要么报"参数个数不匹配"，要么按位置宽松绑定把后续谓词的值整体错位——静默查错数据。
- **建议**：删掉 `117-119` 的两行（占位符由内层 `convert` 负责），逗号改为在内层调用**之前**按 `c > 0` 输出，并对空集合返回 `''`（与 `RootDAO.arg<I,T>` 的 `n == 0 → ''` 口径一致）。补用例：`DataList` 两个元素，断言 SQL 文本为 ` (? , ? )`、`args.size == 2`。

### [严重][存量] #3 结果缓存直接返回**同一个可变实例**：事务内重复 `list` / `mapList` / `first` 拿到共享对象，调用方就地修改即污染后续结果

- **位置**：`f_orm/src/base/SqlExecutor.cj:905-919`（`916` 行 `cache[key] = v`；`908` 行 `case Some(v: T) => v` 原样返回）；受影响入口 `557-565`（`list`）、`573-581`（`mapList`）、`532-540`（`first`）
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`，`916` 行）
- **判据**：review-checklist §12.1「共享可变状态」、§11「逻辑错误（缓存别名）」
- **证据**：静态确定 —— `v` 是 `exec()` 的返回值，类型为 `ArrayList<T>` / `ArrayList<HashMap<String,Any>>` / `Option<T>`，以 `Any` 存进 `cache`；命中分支不做任何复制，直接把同一引用交回调用方。缓存的生命周期是"本次事务"：`close()`（`153-174`）只在非事务路径执行，事务内 `cache` 不被清空，所以同一事务里「同一 SQL + 同一参数」的第二次查询必然命中同一个对象。
- **描述**：最典型的形态是 `let rows = ex.setSql('select …').list<User>()`，业务在同一个事务里对 `rows` 做 `sortBy` / `remove` / 补字段，再查一次同一语句（分页复用、循环重查）时拿到的仍是上一次那个被改过的列表——**返回值与数据库不一致，且没有任何编译或运行期提示**。`first<T>` 共享 POJO 同理：改动对象字段后重查旧值，会让"读—改—写"路径基于脏副本。
- **建议**：命中缓存时返回防御性副本（`list` / `mapList` 复制容器；`first` 只缓存不可变快照或干脆不缓存非标量结果），或把缓存的语义收窄为"只缓存标量 / 只读数据"（`singleFirst` / `singleList` 之外的入口不建 key）。若确认下游不会就地修改，至少在 README 与 `list` 的注释里写明"事务内命中缓存时返回共享实例"。

### [一般][存量] #4 `SqlDSL.compile` 的 data-path 循环条件用了外层 `token`（恒为 `LCURL`）：`:{a.b}` 永远读到语句末尾

- **位置**：`f_orm/src/base/SqlDSL.cj:64-76`（`64` 行 `let token = tokens[i]` 遮蔽外层同名变量，`71` 行 `while(i < tokens.size && token.kind != RCURL)`）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §11「逻辑错误（变量遮蔽）」、§13/§14「文档承诺但不可用」
- **证据**：静态确定 —— `token` 在 `64` 行绑定的是 `:{` 之后那一个 token（即 `LCURL`），循环条件里 `token.kind` 因此恒等于 `LCURL`，`!= RCURL` 永真；循环只能靠 `i < tokens.size` 退出，于是 `} ` 及其之后的所有 token 都被塞进 `path`。随后 `75` 行的检查写成「当前 token 不是 `RCURL` **或** 整个 DSL 的最后一个 token 不是 `RCURL`」：只要 `:{…}` 后面还有其他文本（`… :{a.b} and x=1` 这种最常见写法），就抛 `IllegalArgumentException('not completely data path in …')`；只有路径恰好位于语句末尾时才放过，但 `path` 里仍含 `} `（`85` 行 `name` 取到 `'}'`），`DataPath.solid` 也拿不到合法路径。
- **描述**：`f_orm/README.md:822` 明确承诺 `| :{a.b.c} | 绑定数据路径（DataPath），取对象的嵌套值 |`，而代码里这条语法在正常写法下必然抛异常。全仓 `setSqlFromObject` / `setSqlFromMap` 零调用（只有 `SqlDSL.cj` 内的定义与 `SqlDSL` 接口声明），也没有任何 DSL 用例，所以缺陷未暴露。
- **建议**：条件改成 `tokens[i].kind != RCURL`；`75` 行改成只检查"循环是否因找到 `RCURL` 而退出"（`i >= tokens.size || tokens[i].kind != RCURL` ⇒ 抛错），并把 `}` 从 `path` 中排除；补三条用例：路径在语句中间、路径在末尾、缺 `}`。

### [一般][存量] #5 `readOnly` 一旦置真永不复位：`isReadOnly` 与 `beforeCommit(readOnly)` 在后续写语句/事务里继续报"只读"

- **位置**：`f_orm/src/base/SqlExecutor.cj:84-87`（唯一置位点）、`97-106`（`clearSql` 只清 `sql_` 与 `args`）、`107-111`（对外 `isReadOnly`）、`1048` / `1071` / `1087`（事务切面传给钩子）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，`85` 行）
- **判据**：review-checklist §11「状态未复位 / 契约与实现不符」、§12.1「共享可变状态」
- **证据**：静态确定 —— `grep readOnly f_orm/src` 只有三处：字段声明（`47`）、`85` 置 `true`、`109` 读取；没有任何 `= false` 或"按语句重算"的路径。`sql` 的 setter 对新语句只做 `isSelectStatement → true`，而 `clearSql()` 不复位。
- **描述**：同一线程的 executor 是跨语句复用的，只要执行过一次 `select`，`isReadOnly` 之后永远是 `true`。对外：调用方拿 `isReadOnly` 判断"能否走只读库/只读事务"会误判；对内：`ORM.hooks.beforeCommit(this.isReadOnly)` 把"先读后写"的事务也当成只读提交，读修复/审计类钩子据此做出的决策全错。当前仓内没有 `TransactionHook` 实现读这个参数，所以属"契约错但暂时无人受伤"。
- **建议**：把 `readOnly` 改成按语句计算（在 `clearSql()` 里置 `false`，或直接让 `isReadOnly` 返回 `isSelectStatement(sql_)`）；`beforeCommit` 的语义若指"整个事务只读"，应在事务开始时按首条语句定一次并显式命名（`txReadOnly`），与语句级只读分开。

### [一般][存量] #6 线程内 `current` 是单槽：`close()` 无条件清空、`getInstance` 无条件覆盖，跨驱动混用时 DSL 绑到错误 executor 或直接抛异常

- **位置**：`f_orm/src/base/SqlExecutor.cj:130`（`current.set(exe)`）、`153-174`（`155` 行 `current.set(None)` 不判断 `getCurrent() == this`）、`133-135`（`getCurrent` 取不到即抛 `NoneValueException`）；消费方 `f_orm/src/base/ExtendString.cj:26-27`、`SqlDSL` 之外的 `f_orm/src/base/RootDAO.cj:563-567`（`SqlFunc.toString`）、`f_orm/src/base/Columns.cj:25` / `104`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1「共享可变状态 / 可见性」、§11「契约与实现不符」
- **证据**：静态确定 —— `current` 是 `ThreadLocal<SqlExecutor>` 的单槽（`45`）：`getInstance(driverName)` 每调用一次就覆盖，`close()` 每结算一次就清空，两者都不校验"当前槽位是否就是本次操作的 executor"。而 `SqlFunc.toString()`、`Columns`、`ExtendString` 的 `AND/OR/NOT` 属性在**构建 SQL 文本时**用 `getCurrent()` 取 executor 做标识符引用（`fun`/`involve`）。
- **描述**：`let a = ORM.executor("a"); let b = ORM.executor("b")` 之后对 `a` 拼 SQL（`a.setSql('select ${COUNT(col)} …')`），`SqlFunc.toString` 取到的是 `b`，引用字符与方言按 `b` 的驱动生成；`a.close()` 之后更是把槽位清空，`b` 上继续拼 SQL 直接抛 `NoneValueException`。单驱动场景因为"每次操作都以 `getInstance` 开头"而不易暴露，多数据源（本项目 `f_orm` 明确支持多 driver）会踩。
- **建议**：`close()` 里改成 `if (current.get() == Some(this)) { current.set(None) }`（或用 `currents` 里的实例做身份比较）；更彻底的做法是取消"线程内隐藏当前 executor"，让 `SqlFunc` / `Columns` / `ExtendString` 显式接收 executor（它们都已经在 `TableClause` / `RootDAO` 的 `executor` 字段作用域内）。

### [一般][存量] #7 `QueryResultIterator.next()` 在映射抛异常时不关闭结果集：executor 的"活动结果集"标记永久为真，后续查询全部被拒

- **位置**：`f_orm/src/base/QueryResultIterator.cj:77-88`（`81` 行 `mappers.doMap(result)` 无 `try/finally`）；同样的形态 `101-115`（`SingleColumnIterator.next`）；状态位 `f_orm/src/base/SqlExecutor.cj:53`、`964-966`、`181-184`
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`，`81` 行；该类本身是 bug.md §1.5 修复时新增，已给 `close()` 做了兜底，但没覆盖 `next()` 的异常路径）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」、§12.1「异步/资源」
- **证据**：静态确定 —— `next()` 只在 `doMap` 返回 `None` 时调用 `close()`（`82-85`），异常路径直接向调用方抛出；`activeQueryResult` 由 `execute(closeBeforeReturning:false…)` 置真（`972`），只有 `mustClose` 分支（`1005-1007`）或 `AbstractQueryResultIterator.close()` → `releaseActiveQueryResult()`（`181-184`）才会复位。映射过程中的类型转换失败（`ORMConverter.convert` 抛错、列缺失、`getOrThrow`）完全可能发生。
- **描述**：一条查询只要有一行的字段转换失败，异常冒到业务层后：结果集未关、`Statement` 未关、executor 的 `activeQueryResult` 仍为 `true`，该线程后续任何 `setSql(...).first()` 都抛 `"cannot execute SQL while a previous query result is still active"`——**线程被自己的错误永久锁死**，只能靠显式 `it.close()` 或新建线程恢复（而 `it` 往往已经随异常栈丢失）。
- **建议**：把 `mappers.doMap` 包进 `try { … } catch (e) { close(); throw e }`（或 `finally` 里按"未取到值就关闭"的语义处理）；`SingleColumnIterator.next` 同理。补用例：mockdb 返回一列无法转成目标类型的值，断言迭代器抛错后 `ex.isClosed()` / 同一 executor 可以继续查询。

### [一般][存量] #8 事务内结果缓存**无容量上限、不随语句释放**：长事务里每条不同参数的 SELECT 全量留存结果集

- **位置**：`f_orm/src/base/SqlExecutor.cj:54-56`（`cache` 字段）、`62-67`（默认 `useCache = … ?? true`）、`915-917`（写缓存）、`923-926`（只在写语句后清）、`153-174`（`cache.clear()` 只在非事务 `close()` 里）
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`，`916` 行）
- **判据**：review-checklist §5「缓存键无界 / 无界容器」、§7「有界化」
- **证据**：静态确定 —— 事务中 `close()` 因 `tx.isSome()` 提前返回（`154`），`cache.clear()` 与 `clearSql()` 都不执行；缓存键是 `SqlCacheKey(sql, args)`（`25-39`），每次参数不同就是新键，既没有容量上限也没有 TTL/淘汰，写语句才整体清空一次。缓存值是完整结果集（`ArrayList<O>` / `ArrayList<HashMap>`），每行都是新对象。
- **描述**：批量任务在**一个事务**里按 id 循环 `select … where id = ?`（很常见的写法）时，N 次查询的 N 个结果集全部驻留到事务结束，峰值 ≈ 结果总量，且这部分对象在事务提交前不可能被回收。触发条件明确（同一事务 + 循环查询），但没有实测峰值，故不定为严重。
- **建议**：给 `cache` 设容量上限（如 128 条 / 按行数估算字节数）并在超限时整体清空；或把缓存语义限制为"同一语句在同一事务内的重复查询"——即 key 里带 executor 的语句序号，语句变化即失效。验证：mockdb 事务内跑 1k 次不同 id 的 `first<T>`，采 `getAllocatedHeapSize()` 与 RSS，确认稳态不随 N 增长。

### [一般][存量] #9 `Pagination` 未校验 `size` / `page`：`size == 0` 除零，`page < 1` 得到负 offset

- **位置**：`f_orm/src/base/Pagination.cj:30-41`（`36` 行 `rows / size`、`37` 行 `rows % size`）、`49-53`（`51` 行 `(page - 1) * size`）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`，`36` 行）
- **判据**：review-checklist §11「除零 / 边界差一」、§10「正确性」
- **证据**：静态确定 —— `size` 是公开构造参数（`public let size!: Int64`），两个 `init` 都直接参与除法与乘法，没有 `size > 0`、`page >= 1` 的断言。
- **描述**：分页参数来自 HTTP 查询串是常态：`pageSize=0` 时构造 `Pagination` 立即除零抛 `ArithmeticException`（不是 400，而是 500）；`page=0` 时 offset 为负，`LIMIT … OFFSET -n` 在 PostgreSQL/MySQL 上行为不同（报错或忽略），同一份业务代码在两种库上表现不一致。
- **建议**：构造时统一钳制：`size <= 0 → 抛 ORMException("page size must be positive")`（或取默认 20），`page < 1 → 1`、`rows < 0 → 0`；`pages` 用 `(rows + size - 1) / size` 一次算完，避免 `%` 分支。补用例：`size = 0`、`page = 0`、`rows = 0`。

### [一般][存量] #10 `RootDAO.arg<I,T>`（集合元素绑定）缺 `Data` / `?Any` 分支：与 `arg(Any)` 行为漂移，`IN` / `loop` 传 `Data` 元素直接抛错

- **位置**：`f_orm/src/base/RootDAO.cj:323-389`（分支表 `333-376`，`375` 行兜底 `throw ORMException('type does not support')`）；对照 `252-307`（`arg(Any)`，含 `case x: Data` 与 `case x: ?Any`）；第三份同表 `f_orm/src/base/SqlExecutor.cj:610-653`（`add<T>`）
- **来源**：存量（`git blame`：`9fe28abd50 2026-09-13`，`333` 行）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改载体）」、§11「契约与实现不符」
- **证据**：静态确定 —— 同一套 40+ 类型分支在本部分出现三份（`arg(Any)` 22 行 + 可空组、`arg<I,T>` 20 行 + 可空组、`add<T>` 20 行 + 可空组），三处的差异是**实质性的**：`arg(Any)` 有 `case x: Data => arg(x)`（把 `DataString/DataReal/DataNone…` 再分派一次），`arg<I,T>` 没有；`arg(Any)` 有 `case x: ?Any` 兜住"Option of 未列类型"，`arg<I,T>` 没有。代码注释（`327-332`）只要求"顺序保持一致"，未要求"分支集合一致"。
- **描述**：`IN(values)` / `loop(values)` 对 `Iterable<T>` 逐元素走 `arg<I,T>`。业务把 `Data` 当参数容器（`Map<String,Any>` 取出的值、`toData()` 结果）传进集合时，标量路径 `arg(Any)` 能绑、集合路径抛 `"type does not support"`；同一个值走 `BETWEEN` 可以、走 `IN` 不行。三份分支表各自漂移的风险还会随新增类型继续放大（本部分之外的 `RootDAO.arg(Any)` 就曾在重排时去掉过恒不可达分支）。
- **建议**：把三处合并为一处分派：`arg<I,T>` 直接复用 `arg(Any)`（`for (v in value) { arg(v) }` 后只拼占位符），或在 `arg<I,T>` 里补 `case x: Data => arg(x)` 与 `case x: ?Any`。若为性能刻意保留展开，加一个机械护栏：用反射/源码扫描断言三张表的 `case` 多重集一致（`SqlExecutorArgBranches_test.cj:47-49` 已用同样思路做过一次人工核对）。

### [一般][存量] #11 嵌套映射器的接线断了：`newNest` / `newNullableNest` 无人调用、`NullableNestQueryMapper` 的 `nestGetter` 没有任何实现路径、子类型映射走 `new<T>()` 丢嵌套

- **位置**：`f_orm/src/base/NestQueryMapper.cj:25-30`（`newNest`）、`46-52`（`newNullableNest`）、`53-57`（`populate` 无条件 `nestPutter`）；`f_orm/src/base/QueryMappers.cj:53-60`（`create` 调用 `oMappers[i].new<T>()`，即 `QueryMapper.new`，`f_orm/src/base/QueryMapper.cj:37-44`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，`25` / `46` 行）
- **判据**：review-checklist §1「无调用者」、§14「接线缺失 / 半成品」、§11「契约与实现不符」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）搜 `newNest` / `newNullableNest` 只命中定义本身；`nestGetter` 只在 `newNullableNest` 的包装闭包里被引用（`49` 行），而 `populate`（`53-57`）只读 `nested` 与 `nestPutter`。宏只构造这两个类的实例（`QueryMappersGenerator.cj:350-354`、`390-393`），从不调用 `newXxx`。
- **描述**：三条后果串在一起：(a) `NullableNestQueryMapper` 名为 nullable，`populate` 却总是 `nested.map(result)` 后无条件 `nestPutter(o, n)`——左连接没有匹配行时会构造一个"全空字段的对象"塞进字段，而不是留 `None`（`nestGetter` 本应在这里做"是否为空"的判断），而非空类型的嵌套字段在 NULL 列上还会在 `ORMConverter.convert` 里抛错；(b) 子类型继承映射（`QueryMappers.create`）用 `QueryMapper.new<T>()` 复制父类映射器，`NestQueryMapper` 没有覆写 `new`，父类的嵌套字段退化成 `putter: {o, v =>}`（`NestQueryMapper.cj:23` 的 no-op putter），**嵌套对象永远不被填充**；(c) 两个 `newXxx` 方法既没人调也不是 `new`，属死代码。
- **建议**：把 `newNest` / `newNullableNest` 改成 `override new<T>()`（或让 `QueryMapper.new` 用一个可覆写的 `rebind` 钩子），使 `create` 走同一条路；`NullableNestQueryMapper.populate` 用 `nestGetter` + "嵌套映射器的所有列是否都为空"决定是否 `None`。补两条用例：左连接空行 → 字段为 `None`；子类 `queryMappers()` 的父类嵌套字段能被填充。

### [一般][存量] #12 `commit` / `rollback` / `save` / `release` 在无事务时静默成功：`Option` 被丢弃，调用方无法知道保存点没生效

- **位置**：`f_orm/src/base/SqlExecutor.cj:298-306`（`commit` / `rollback`）、`307-342`（`finishTransaction` 在 `tx.isNone()` 时整段跳过）、`389-394`（`tx?.save` / `tx?.release`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「错误处理缺失或静默」、§3「`Option` 分支被吃掉」
- **证据**：静态确定 —— `finishTransaction` 只有 `if (let Some(tx) <- this.tx)` 一个分支，`None` 时既不打日志也不抛错；`save` / `release` 直接 `tx?.save(...)`，返回值（`Unit`）与"是否执行"都没有表达。
- **描述**：`newTxAndBegin(propagation: Supports)` / `NotSupported` / `Nested` 在无外层事务时用的是 `DummyTransaction`（`wrap/DummyTransaction.cj:66-70` 的 `commit` / `rollback` / `save` / `release` 全为空体），此时 `save("sp1")` 静默 no-op，随后 `rollback("sp1")` 也 no-op——业务以为回滚到了保存点，实际什么都没发生，**部分写入被提交**。这条与"dummy 事务就是设计"并不矛盾：问题在于**保存点语义没有降级提示**。
- **建议**：`save` / `release` 在 `tx.isNone()` 或 `tx.isDummy` 时抛 `SavepointNotSupportedException`（或返回 `Bool` 让调用方判断）；`commit()` 无事务时至少 `logger.warn`。补用例：`Supports` 传播下 `save` → 断言抛错/告警。

### [一般][存量] #13 `RequiresNew` / `NotSupported` 分支先取新连接再建事务：`createTransaction()` 返回 `None` 时这条连接无人关闭

- **位置**：`f_orm/src/base/SqlExecutor.cj:226-252`（`229-233` 与 `246-250` 取 `getConnection(driverName)`；`234` / `263` 只处理 `Some`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「资源不对称（打开未关）」、§12.1「跨线程资源」
- **证据**：待确认 —— 需要驱动的 `Connection.createTransaction()` 在"不支持事务"时返回 `None` 的行为（std 接口签名是 `?Transaction`，语义上允许 `None`）。代码侧确定：连接变量是局部 `let`，除 `TransactionWrap` 构造外没有其他引用，`if (let tx <- …)` 失败后既不 `close()` 也不保存。
- **描述**：一旦某驱动对嵌套/新事务返回 `None`，池里的这条连接就永久占用（直到进程退出），`hasRealTx` 仍为旧值，后续 `Required` 判断也会错。当前仓内驱动（postgres/mysql/mockdb）预计都返回 `Some`，所以是潜在缺陷。
- **建议**：`if (let tx <- …) { … } else { connection.close(); newDummyTx(mode: StartFailure, ex: ORMException("driver returned no transaction")) }`；`RequiresNew` 里新取的连接用 `try/finally` 兜底关闭。

### [一般][存量] #14 测试替身 `QueryResultTest.getOrNull` 的 `match(None<T>)` 恒不命中类型分支：任何取值都抛 `Exception("get error")`，且 `isClosed()` 恒 `false`

- **位置**：`f_orm/src/base/QueryResult_test.cj:71-89`（`75` 行 `match(None<T>)`、`87` 行兜底抛错）、`19-23`（`isClosed` 恒 `false`、`close` 空体）、`37-70`（`next(values)` 用 `i > 2`、`next()` 用 `row < 4`，两套行计数互不相关）
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13` 前后，bug.md 之前的替身）
- **判据**：review-checklist §11「逻辑错误」、§3「空实现（替身无注释）」
- **证据**：静态确定 —— `match (None<T>)` 匹配的是 `Option<T>` 的 `None` 实例，类型模式 `case _: Int64` / `String` / `Bool` / `DateTime` 判的是**值的运行时类型**，`None<Int64>` 的运行时类型是 `Option<Int64>`，四个分支都不可能命中 ⇒ 永远落到 `case _ => throw Exception("get error")`。同文件 `i`（`34`）只在 `next(values)` 里自增、`row`（`66`）只在 `next()` 里自增，两条 API 的行数口径也不一致。
- **描述**：这个替身仍被 `Statement_test.cj:25` / `37` 用作 `query()` 的返回值（`StatementTest` 本身已无调用者，属第 3 部分 #19 描述的旧替身链）；只要有人再用它跑"读一行"的用例，就会得到与被测逻辑无关的 `get error`，或永远读到 `isClosed() == false` 把资源释放问题掩盖掉。
- **建议**：直接删掉 `QueryResultTest` / `StatementTest`（mockdb 已覆盖同一场景），或按 `TypeInfo.of<T>()` 分派（`match (TypeInfo.of<T>()) { case t where t == TypeInfo.of<Int64>() => … }`）并给 `close()` 一个真实状态位。

### [一般][存量] #15 `SqlCacheKey` 持有**活的可变** `SqlArgs`：`clearArgsAfterExec: false` 时键构造后参数还会继续追加，`hashCode`（记忆值）与 `==`（内容比较）契约被破坏

- **位置**：`f_orm/src/base/SqlExecutor.cj:25-39`（`28` 行构造时算 `h`、`34` 行 `==` 比 `args`）；`97-106`（`clearArgsAfterExec == false` 时**不换** `args` 实例）；唯一使用点 `f_orm/src/base/SqlPartial.cj:295`（`setSql(countSql, clearArgsAfterExec: false)`）
- **来源**：存量（`git blame`：`f56b276758 2026-10-05`）
- **判据**：review-checklist §11「契约与实现不符（hash/equals 不变式）」、§5「长期持有」
- **证据**：待确认 —— 需要在事务内构造出"同一 `SqlArgs` 实例先做缓存键、随后又被 `add`"的时序（`count` 语句后紧接拼接语句）。代码侧确定：`SqlCacheKey.h` 只在构造时计算一次，`SqlArgs.add` 会把 `h` 复位为 0（`wrap/SqlArgs.cj:31-37`），但 `SqlCacheKey` 里的 `h` 不会重算，而 `==` 用的是 `args == other.args`（内容）——键放进 `HashMap` 后再变化，等于把条目放进了一个"用旧哈希、按新内容比较"的桶。
- **描述**：后果是缓存偶发不命中（性能）或条目不可达（内存滞留，因为 key 强引用了仍在增长的 `args`）；极端情况下同一个 key 的 `hashCode` 与 `equals` 自相矛盾，`HashMap` 的行为未定义。它不会直接产生错误结果（命中失败就重查），但会让 `orm_useCache` 的语义不可预测。
- **建议**：`SqlCacheKey` 构造时对 `args` 做**不可变快照**（复制列表，或存 `args.toString()` / 预先算好的参数摘要），使 key 一旦构造就不再变化；`clearArgsAfterExec: false` 的路径改用独立的"多段 SQL 绑定"缓存，不复用结果缓存 key。

### [轻微][存量] #16 `ORM.register` 六个重载重复同一段前置检查，且日志与行为不一致（其中一路完全不检查）

- **位置**：`f_orm/src/base/ORM.cj:88-132`（`89-92` 检查 + `warn`、`97-99` 检查但**静默** `return`、`104-107` / `111-115` 检查 + `warn`（后者缺 `debug`）、`121-132` 四个 `String` 重载**完全不检查**）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2「字面量/结构复制导致行为漂移」、§11「错误处理不一致」
- **证据**：静态确定 —— 五个 `Driver` 重载里 `96-102` 的重复分支只 `return`（没有 `log.warn`），`111-117` 少了 `log.debug`；`register(driver: String, …)` 系列（`121-132`）先 `NamedDatasource(getDriver(driver))` **急切建对象**，再交给 `register(datasource)`，重复时走 `datasources.addIfAbsent` 失败的 `datasource.close()`（`80`）——新建的 `NamedDatasource` 被静默关掉，既不告警也不告知调用方"这次注册被忽略，默认库也没改"。
- **描述**：基线约定"同名注册启动直接失败"（`fountain-baseline.md` §4），这里实现的是"先注册先赢 + 静默丢弃后者"，且两条注册路径的日志口径不同：走 `Driver` 重载能看到 `warn`，走 `String` 重载什么都没有。
- **建议**：抽一个 `private func alreadyRegistered(name: String, source: String): Bool`，统一 `warn` 文案；`String` 重载在创建 `NamedDatasource` **之前**做检查，避免白建连接；若按基线要"启动失败"，改成抛 `ORMException`。

### [轻微][存量] #17 `ORM.close()` 用 `e.printStackTrace()` 而非 `f_log`；`deregisterAndReplaceDefault` 不校验新默认库是否已注册

- **位置**：`f_orm/src/base/ORM.cj:46-54`（`51` 行）、`166-169`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：`fountain-baseline.md` §6「日志走 `f_log`，热点路径不 `println`」、review-checklist §11「边界校验」
- **证据**：静态确定 —— 同文件已有 `LoggerFactory.getLogger<ORM>()`（`37`）与 `log.error`（`153`），只有退出路径用 `printStackTrace`；`deregisterAndReplaceDefault` 直接 `default = newDefault`，不做 `datasources.contains` 检查。
- **描述**：退出阶段关闭失败只打到 stderr，容器/日志采集通常看不到；`deregisterAndReplaceDefault("typo")` 之后所有 `ORM.executor()` 都会在 `datasources[default]`（`187`）上抛底层容器异常（不是 `ORMException("default datasource is not specified")`）。
- **建议**：改为 `log.error('failed to close datasource', e)`；`deregisterAndReplaceDefault` 先 `if (!datasources.contains(newDefault)) { throw ORMException(...) }`。

### [轻微][存量] #18 `ORM_test` 是空用例（唯一一行被注释），且 `protected import …wrap.*` 已无使用者

- **位置**：`f_orm/src/base/ORM_test.cj:20-27`
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §3「空实现」、§1「未使用的 import」
- **证据**：静态确定 —— `@TestCase public func test()` 函数体只有注释 `// topTest()`；`wrap` 包的类型在文件内零引用。
- **描述**：这条用例永远是绿的，`ORM.register` / `deregister` / `executor` 这几条容易出错的路径没有任何回归保护（本部分 #6 / #16 的问题正因如此没被发现）。
- **建议**：补真实断言（注册重复驱动 → 断言只保留一份且 `default` 不变；`deregister` 后 `ORM.executor(name)` 抛明确异常），或删掉这条空用例与无用 import。

### [轻微][存量] #19 死代码：`ORM.driverNames`、`Partials` 的 8 个 `AND/OR/NOT/PAREN` 重载 + 2 个 `append` 重载、`NestQueryMapper.newNest` / `NullableNestQueryMapper.newNullableNest`

- **位置**：`f_orm/src/base/ORM.cj:55-59`；`f_orm/src/base/Partials.cj:28-35`（两个 `append`）、`40-71`（`AND/OR/NOT/PAREN` 各两个重载）；`f_orm/src/base/NestQueryMapper.cj:25-30`、`46-52`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02` / `ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §1「`protected` 除「`public open`/`public abstract` 非 `sealed` 类成员」外无引用即死代码；`internal` 在本包及子包无引用即死代码」
- **证据**：静态确定（全仓搜索，排除 `.worktrees`）——
  - `ORM.driverNames`：`ORM` 是 `public class`（非 `open`/`abstract`），成员是 `protected`，全仓零引用；
  - `Partials` 是 `protected class`（非 public），`grep 'partials\.'` 只命中 `append` / `clear` / `toString` 与 `operator()`（`ExtendString.cj:49` / `53` 两个重载都在用），`AND/OR/NOT/PAREN` 两个重载与 `append(op, sql)` / `append(op, () -> Unit)` 零引用（它们只互相调用）；
  - `newNest` / `newNullableNest`（默认 `internal`）全仓只命中定义，见 #11。
- **描述**：`Partials.AND/OR/NOT` 与 `ExtendString` 的 `'x'.AND` 是同一能力的第二套实现（第 3 部分 #21 已记），保留死分支会让人误以为 DSL 走的是 `Partials`。`ORM.driverNames` 与 `ORM.databasesNames`（`170-174`，返回 `DriverManager.drivers()`）名字相近但语义不同，也容易误用。
- **建议**：删除上述死成员；若 `ORM.driverNames` 是给下游子类的扩展点，请把 `ORM` 声明成 `open class` 并加注释说明用途（否则按基线判死代码）。

### [轻微][存量] #20 `@ORMColumn` 注解在本仓没有任何消费者：标注后不产生任何效果

- **位置**：`f_orm/src/base/ORMColumn.cj:18-21`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3「契约承诺有行为、实现为空」、§14「接线缺失」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）搜 `ORMColumn` 只命中定义本身；`QueryMappersGenerator` 读取的是 `@QueryMappersGenerator` 的属性（`QueryMappersGenerator.cj:240-260` 的 `meta` 来自宏属性），不读字段上的注解；也没有任何 `TypeInfo.getAnnotations` 之类调用。
- **描述**：注解声明了 `name` / `id` 两个参数（`id` 对应 `isId` 语义），看起来是"给字段指定列名 / 标主键"的入口；实际标注在任何属性/变量上都不会改变生成的 mapper（列名仍按 `CaseFormat.Pascal → lower_underscore` 推导）。这会诱导使用者写出"标了没生效"的代码。
- **建议**：要么在 `QueryMappersGenerator` 里读 `MemberProperty/MemberVariable` 的 `@ORMColumn`（`name` 覆盖列名、`id` 置 `isId`），要么删掉该注解。

### [轻微][存量] #21 `waitConnecting` 是无退让的自旋：连接推进慢时独占一个核直到超时

- **位置**：`f_orm/src/base/SqlExecutor.cj:400-408`（`403-407` 循环体只有 `MonoTime.now()` 与超时判断）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，bug-orm.md §3.2 ORM-L9 修复时加了超时，但没加让出）
- **判据**：review-checklist §6.4「低效实现（忙等）」、§8「降 CPU」
- **证据**：静态确定（形态）—— 循环内没有 `sleep` / `yield` / 条件变量，每轮只读 `state` 与时钟；上界由 `ORMConfig.getConnectingTimeout` 决定。**没有线程状态与 CPU 采样数据，故不声称占比**。
- **描述**：池化驱动把连接推进放到后台线程时，调用线程会在这段时间里 100% 占用一个核；并发 N 个请求同时 Connecting 就是 N 个核空转，且 `state` 的读取频率不受控。
- **建议**：循环里加 `sleep(Duration.millisecond * 1)`（或指数退避到 10ms），或改用驱动提供的连接完成回调/条件变量；顺带把 `MonoTime.now()` 改为每 N 轮取一次。

### [轻微][存量] #22 `SqlExecutor` 构造即建连：`ORM.executor(name)` 只取不用时，连接悬挂到线程内下一次 `getInstance` 或线程退出

- **位置**：`f_orm/src/base/SqlExecutor.cj:61-69`（`68` 行 `_connection_ = getConnection(driverName)`）、`113-132`（每线程一份，`close()` 才归还）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「资源生命周期」、§7「缩短生命周期」
- **证据**：静态确定（机制）—— 构造函数直接取连接；`close()` 只在语句执行完（`896-898`）、事务结束（`1101`）、迭代器关闭（`183`）时调用。`RootService.dao<T>()` / `ORM.executor()` 这类"只取实例"的入口不会触发 `close()`。
- **描述**：请求线程调用 `dao<X>()` 但本次没有执行任何 SQL（缓存命中、提前返回、只做校验）时，池里那条连接会一直被该线程持有；线程池长期存活时表现为"空闲连接数 = 线程数"，连接池较小时会挤掉真正要用的请求。是否是问题取决于 `f_dbpool` 的池大小与线程数配置（待确认）。
- **建议**：改为惰性连接（`statement` / `connection` 首次访问时再取），或在 `getInstance` 里对"上次使用时间超过 N 秒"的 executor 主动 `close()`。

<!-- 第 5 部分 -->

### [严重][存量] #1 `TransactionHook.inTx()` 永远不会被调用：接口与 README 都承诺了，框架侧既无调用点也没被 `TransactionHookWrap` 转发

- **位置**：`f_orm/src/base/TransactionHook.cj:19-20`（接口默认空实现）；`f_orm/src/base/TrsactionHooks.cj:21-51`（`TransactionHookWrap` 只转发 7 个方法，缺 `inTx`）；调用侧 `f_orm/src/base/SqlExecutor.cj:1039-1100`（只有 `beforeTx/beforeCommit/afterCommit/afterThrowing/beforeRollback/afterRollback/afterComplete`）
- **来源**：存量（`git blame`：`TransactionHook.cj:20` 与 `TrsactionHooks.cj:24-44` 均落在 `4be871f2fd 2026-10-02`；`git status` 无改动）
- **判据**：review-checklist §3「接口给了默认空实现 / 公开契约承诺有行为，实现为空」、§14.1「承诺了但没实现」、§1「注册了但永不触发」
- **证据**：静态确定 —— 全仓（排除 `.worktrees`）`grep -rn "inTx"` 的命中只有三处：`TransactionHook.cj:20` 的接口默认实现、`TrsactionHooks.cj` 内**没有**对应方法、以及 `f_orm/README.md:1626` 把 `func inTx(): Unit {}` 列进公开接口清单。`SqlExecutor.execute` 的钩子调用序列里没有任何 `inTx()`。`TransactionHookWrap`（`TrsactionHooks.cj:21`）虽然 `TransactionHook` 有默认实现，但它不转发，所以即使将来补上调用点，包裹层里的真实钩子也收不到。
- **描述**：`TransactionHook` 是公开扩展点，`inTx()` 的语义（"事务已开始、业务函数执行中"）在下游被用来绑定线程上下文（会话变量、审计、`SET LOCAL`）。当前它 100% 静默失效：用户在钩子里写的逻辑一行都不会跑，且没有任何编译告警或日志。`fdemo/boot/src/TransactionHookImpl.cj:29` 就实现了这个方法（只打日志），所以连"仓内无人实现"的兜底解释都不成立。
- **建议**：二选一，不要停在中间态：①在 `execute` 里 `newTxAndBegin(...)` 之后、`executor(this)` 之前调用 `ORM.hooks.inTx()`，并在 `TransactionHookWrap` 里补 `public func inTx(): Unit { hook.inTx() }`；②若语义未定型就先从接口删掉，README 同步删除——留着空实现的公开钩子比没有更危险。补一条用例：注册一个只置位 `Box<Bool>` 的 hook，`execute{}` 后断言置位。

### [一般][存量] #2 `UPDATE(Map<String, Any>)` 两个重载先把 `, ` 写进 SET 再判断该列是否在 map 里：缺列时留下孤立逗号，生成 `SET a=?, , b=?`

- **位置**：`f_orm/src/base/SqlPartial.cj:160-168`（`161` 行无条件 `sql.append(', ')`，`163-167` 才判断列是否存在）；同一缺陷复制到 `f_orm/src/base/SqlPartial.cj:203-211`
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`，`160-168` 整段同一次提交）
- **判据**：review-checklist §11「逻辑错误（生成非法 SQL）」、§2「字面量复制（同缺陷两处）」
- **证据**：静态确定 —— 逗号写在 `if(sql.size > sqlsize)` 里，只以"已经写过内容"为条件；紧随其后的 `if(let Some(v) <- values.get(field)) … else if … values.get(column)` 两个分支都可能**都不命中**（该列既不按字段名、也不按列名出现在 map 中），此时逗号已经落盘，列没有落盘。两种形态：①中间缺列 —— mapper 顺序 `name, age, nick`，map 只给 `name` 与 `nick` ⇒ `SET \`name\`=?, , \`nick\`=?`；②末尾缺列 —— 只给 `name` ⇒ `SET \`name\`=?,  WHERE \`id\`=?`（逗号紧贴 WHERE）。反过来，"map 里只有主键"时因为第一个非 id 列就没命中、逗号从未写入，`sql.size == sqlsize` 成立，`171-172` 的 `no column to update` 能正常抛出——说明该校验本身没问题，问题只在"部分命中"的形状。
- **描述**：部分字段更新的常见写法（只传脏字段）一旦字段顺序有"空洞"就必然报 SQL 语法错误；错误信息来自驱动（`You have an error in your SQL syntax near ','`），排查时看不出是 ORM 拼串问题。列全在、或缺失列都排在最后时不触发，所以单列/连续列的用例守不住。`f_orm/src/base/SqlPartial.cj:247-254`（`ObjectData` 路径）把逗号放在过滤分支**内部**，说明正确写法是已知的，这两处是漏改。
- **建议**：把逗号改成"追加列之前才判断"：先算出 `let val = values.get(field) ?? values.get(column)`，命中后再 `if(sql.size > sqlsize) { sql.append(', ') }` 然后 `append(involve(column)…arg(v))`；同时把两处重复的 SET 构建抽成一个私有函数（`值解析 + 逗号 + 绑定`），顺带修掉两处 `'no column to udpate'` 拼写。补用例：三列 mapper、map 只给第 1、3 列，断言 SQL 不含 `, ,` 且 `args.size == 2`。

### [一般][存量] #3 `ORDER_BY(Array<Column>)` / `GROUP_BY(Array<Column>)` 用**空格**而不是逗号分隔列，多列时生成 `order by a b`

- **位置**：`f_orm/src/base/TableClause.cj:162-171`（`166` 行 `columns.append(' ')`）、`f_orm/src/base/TableClause.cj:257-266`（`261` 行同样写法）
- **来源**：存量（`git blame`：`5f431b4c8f 2026-09-16`）
- **判据**：review-checklist §11「逻辑错误（生成非法 SQL）」、§2「近似重复（两处同错）」
- **证据**：静态确定 —— `Column.toString()`（`f_orm/src/base/Columns.cj:120-143`）本身就返回带首尾空格的 `' name '`，所以两段之间只会有空格，绝不出现 `,`；`appendPartial(' order by ', ',', …)` 的 trim 只裁首尾逗号，不会补中间分隔符。两列时文本为 `order by `id`  `name``，缺逗号；`GROUP_BY` 同理。
- **描述**：多列排序/分组是常规需求（`ORDER_BY([t.id.ASC(), t.name.DESC()])`），当前必然被数据库拒绝。仓内唯一活调用 `fdbm/test/e2e/orm_client/src/main.cj:177` 只传一个元素，README 的两个示例（`README.md:1155`、`1353`）也都是单元素，所以缺陷没被任何用例覆盖到。
- **建议**：两处 `append(' ')` 改成 `append(', ')`；顺手把这段"`Array<Column>` → 逗号串"提取为与 `columns2string(Array<SqlExpr>)`（`TableClause.cj:311-320`）同源的私有函数，避免第三份。补用例：两列 `ORDER_BY`，断言 SQL 含 `order by` 且逗号数 = 1。

### [一般][存量] #4 `appendPartial` 的 `and|or` 裁剪正则与 `Condition.TRIM_AND_OR` 语义不一致：首部 `' or …'`、尾部 `'… and '` 裁不掉

- **位置**：`f_orm/src/base/TableClause.cj:20`（`^(\s*and|or\s*)|(\s*and|or\s*)$`）对照 `f_orm/src/base/Condition.cj:33`（`^\s*(and|or)\s*|\s*(and|or)\s*$`）
- **来源**：存量（`git blame`：`245fecb0cb 2026-10-05`，注释自称"模式文本与原先每次插值出的完全一致"，即沿用了旧语义）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（同一归一化两份实现已漂移）」、§11「逻辑错误」
- **证据**：静态确定 —— 分支优先级决定语义：`^(\s*and|or\s*)` 的两个选择是「行首 + 空白* + `and`」与「`or` + 空白*（必须紧贴行首）」，因此行首带空白的 `or` 不匹配；对称地，`(\s*and|or\s*)$` 的 `\s*and$` 要求 `and` 紧贴行尾，行尾带空白的 `and` 不匹配。`Condition` 那份把 `\s*` 提到分组外，两种情形都覆盖。两处归一化的是同一种"首尾 `and|or`"条件串，只是分属两条路径：前者服务 `AND/OR/WHERE/HAVING` 的字符串重载（`TableClause.cj:153/177/183/189/271`），后者服务 `Condition.SET/WHERE` 的构建器。
- **描述**：`WHERE(' and x=1 ')` 能裁掉，`WHERE(' or x=1')` 留下来变成 `where  or x=1`（语法错误）；`AND('x=1 and ')` 留下尾部 `and`，同样语法错误。手写条件串是该 API 的公开用法（`AND(condition: String)`、`WHERE(condition: String)`），所以可达；`Partials`/`Condition` 生成的串已预先裁剪，日常链路不会踩。
- **建议**：直接复用 `Condition.TRIM_AND_OR` / `TRIM_COMMA`（把 `Condition` 的常量提到包级或给 `Condition` 加 `internal static func trimAndOr`），删掉 `TableClause.cj:20-21` 这一份；若要保留两份，至少把 `\s*` 提到分组外并对齐替换目标（`Condition` 替换为 `' '`、这里替换为 `''`，这是有意差异，应在注释里写明而不是写成"完全一致"）。

### [一般][存量] #5 `TransactionHookWrap` 不转发 `order`：`compare` 比较的是包裹层自己的默认值 `Int64.Max`，钩子顺序配置完全失效

- **位置**：`f_orm/src/base/TrsactionHooks.cj:45-50`（`46` 行 `this.order.compare(other.order)`）；`order` 的默认实现 `f_orm/src/base/TransactionHook.cj:30-34`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「契约与实现不符」、§13「文档与实现不一致」（`README.md:1638` 写明"先比 `order`，再比注册序号"）
- **证据**：静态确定 —— `TransactionHookWrap <: TransactionHook` 只重写了 7 个回调（`TrsactionHooks.cj:24-44`），没有重写 `order`，因此 `this.order` 与 `other.order` 都取接口默认的 `Int64.Max`，`compare` 必然走 `case EQ => count.compare(...)`。`register` 也没有把 `hook.order` 存进 wrap（`TrsactionHooks.cj:22` 只有 `hook` 与 `count` 两个字段）。
- **描述**：`prop order` 是唯一的排序手段，用户按 README 把"日志钩子 `order=1`、审计钩子 `order=100`"排好，实际执行顺序永远是注册顺序。若某个钩子依赖先后（例如先初始化会话再写审计），会得到错误的执行序列，且没有任何提示。顺序错误不会抛异常，属于"静默错序"。
- **建议**：`TransactionHookWrap` 增加 `public prop order: Int64 { get() { hook.order } }`（或把 `order` 在构造时快照成字段，避免运行期读钩子的可变属性）。补用例：注册两个 `order` 相反的 hook，断言 `beforeTx` 的调用序列。

### [一般][存量] #6 钩子注册非幂等且无同步：重复 `ORM.initialize()` 会让钩子成倍执行，注册与遍历并发时 `ArrayList` 无保护

- **位置**：`f_orm/src/base/TrsactionHooks.cj:55-58`（`list.add(...)` + `sort(list)`，无去重、无锁）；入口 `f_orm/src/base/ORM.cj:65-72`（`registerTransactionHooks` 无条件遍历注册）、`f_orm/src/base/ORM.cj:148-155`（`initialize()` 每次都调）
- **来源**：存量
- **判据**：review-checklist §5「无界容器 / 全局集合只增不减」、§12.1「检查-然后-写入 / 迭代与修改并发」
- **证据**：静态确定 —— `register` 只有 `add`，没有任何"已注册则跳过"的判断；`ORM.hooks` 是 `static let`（`ORM.cj:40`），生命周期等于进程。`ORM.initialize()` 在仓内被多次调用（`f_llm/src/service/LLMConfService_test.cj:60` 与 `:111` 各一次，`f_orm/src/base/ORMInitializer.cj:36` 一次），同一进程内每调一次就把 `lookupList<TransactionHook>()` 的结果整体追加一遍。`hooks` 的遍历（`TrsactionHooks.cj:59-93`）与 `register` 的 `add/sort` 之间没有同步手段，而 `ORM.registerTransactionHook<T>`（`ORM.cj:69-72`）是 public 的，可在运行期被调用。
- **描述**：①重复初始化 ⇒ `beforeTx/beforeCommit/afterCommit` 每个执行 N 次：审计重复落库、计数器翻倍、`SET LOCAL` 重复执行；并且 `list` 只增不减（内存随初始化次数线性增长，量级小但无界）。②运行期注册与事务遍历并发 ⇒ `ArrayList` 结构性修改，可能读到半成品排序结果或越界。
- **建议**：`TransactionHooks` 内维护一个 `HashSet<TypeInfo>` 记录已注册的钩子类型，重复注册直接跳过（`T` 参数正好用上，见 #14），或让 `ORM.initialize()` 幂等（首次注册后置标志）；注册路径加锁，或改成"拷贝-排序-原子替换 `let list`"的写时复制，让遍历读不可变快照。

### [一般][存量] #7 `TableMeta.new` 静默吞异常并静默丢列；`TableMetas.register` 只 warn 不抛：表元信息缺失后迁移会直接少建列

- **位置**：`f_orm/src/base/TableMeta.cj:43-60`（`49`/`55` 两处 `catch(_){}`，`57` 行 `filter{opt => opt.isSome()}`）；`f_orm/src/base/TableMetas.cj:26-32`（`29-31` 捕获全部异常只 `log.warn`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3「`catch (_: Exception) {}` 静默吞掉异常」、§14.1「半成品 / 接线缺失」
- **证据**：静态确定 —— 每个 mapper 依次尝试 `getInstanceProperty` 与 `getInstanceVariable`，任何反射异常都被空 `catch` 吞掉；两个 `if (let Some(schema) <- …)` 都不命中时返回 `None`，随后被 `filter` 丢弃。全过程无日志、无计数、无异常。`TableMetas.register` 把 `TableMeta.new` 的任何失败降级为一行 `warn`。
- **描述**：`@ColumnSchema` 少写一个、字段写成 `static`、反射 API 对某成员抛错——结果都是"这一列从 `TableMeta.columns` 里消失"。下游 `SchemaFinderMediator` 用它生成 `CREATE TABLE` / `ALTER TABLE`（`f_orm/src/migro/SchemaFinderMediator.cj:29`），于是建表少一列、或者对着已有表永远认为"该列不存在"，而构建与启动都成功。缺列的影响面是数据面，不是日志面。
- **建议**：空 `catch` 改为 `catch (e: Exception) { log.debug(...) }` 或直接不捕获（`getInstanceProperty` 找不到时本身返回 `None` 语义的 API 更合适）；两个分支都不命中时收集成列表，在 `TableMeta.new` 结束前统一抛 `TableMetaException('columns without @ColumnSchema: …')`。`TableMetas.register` 至少把 `warn` 提升为 `error` 并保留异常堆栈。

### [轻微][存量] #8 `UPDATE<T>(values: T, …, dirty: true)` 在"无列可更新"时提前 `return 0`，掩盖了主键缺失；紧随其后的 `else if` 恒不可达

- **位置**：`f_orm/src/base/SqlPartial.cj:256-263`（`256` 先 `return 0`，`259` 才判 `idColumn.isEmpty()`，`261` 的 `else if (sql.size == sqlsize)` 永假）；对照 `f_orm/src/base/SqlPartial.cj:169-172`
- **来源**：存量（`git blame`：`ae7aa2263c 2026-09-13`）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达语句」、§11「错误处理缺失（失败路径当成功）」
- **证据**：静态确定 —— 控制流上 `256` 行已把所有 `sql.size == sqlsize` 的情形 `return 0`，`261` 行的同一条件不可能再为真。触发 `sql.size == sqlsize` 的现实路径是"过滤条件把所有列都排掉"：`dirty: true` 时 `DirtyTag` 给出的字段名与实际列名不匹配（`includingColumns` 收不到任何 mapper），或 `includingColumns` 传的是列名而 mapper 的 `columnName` 与之不一致。
- **描述**：此时函数返回 `0`（"没有行被更新"），而不是像 Map 重载那样抛 `NoIdException`/`SqlArgException`；如果真实原因是"主键映射缺失"，业务侧看到的是一个合法的 0，永远查不出配置错误。无主键但**有**可更新列时仍会正常抛 `NoIdException`，所以这不是"无主键必静默"，而是"无列可更新时不再检查主键"。
- **建议**：把 `idColumn.isEmpty()` 的判断提到 `return 0` 之前（与 `169-172` 一致），删掉 `261` 的不可达分支；`sql.size == sqlsize` 时仍返回 0（这是合法语义），但要与"无主键"区分开、必要时 `log.debug` 记录被跳过的原因。

### [一般][存量] #9 `@ColumnSchema[comment: …]` 只被搬进 `ColumnMeta.comment`，全仓无任何消费：列注释永远不会出现在 DDL 里

- **位置**：`f_orm/src/base/TableSchema.cj:44-53`（`52` 行 `comment!`）、`f_orm/src/base/TableMeta.cj:72`（字段）/`81`（赋值）；生成侧 `f_orm/src/migro/MysqlSchema.cj:100-102`（`generateColumn` 只拼列名/类型/nullable/default/extra）、`f_orm/src/migro/PostgresSchema.cj` 同样无注释语句
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」、§1「读了不用（死配置字段）」
- **证据**：静态确定 —— 全仓 `grep -rn "\.comment\b" --include=*.cj`（排除 `.worktrees`）在 `f_orm` 内只有 `TableMeta.cj:81` 的赋值；`grep -rn "comment" f_orm/src/migro` 结果为空。`f_orm/src/migro/MysqlSchema.cj` 的 `generateColumn` 只拼列名/类型/nullable/default/extra。
- **描述**：注解参数对外可见（`public let comment!`），使用者按常规语义写 `@ColumnSchema[typeName: 'varchar(64)', comment: '用户昵称']`，期望 `CREATE TABLE`/`ALTER TABLE` 带上 `COMMENT '用户昵称'`；实际被丢弃。同类字段 `IndexMeta.def` 有人消费（`PostgresSchema.cj:119`），`comment` 则完全没有，说明不是"故意留给下游"。
- **建议**：要么在 `generateColumn`/`generateAlterSql` 里接上（MySQL `comment '…'`、Postgres `comment on column …`），要么把 `comment!` 从 `ColumnSchema` 与 `ColumnMeta` 删掉，避免给出不存在的承诺。注意 `ColumnMeta.hashCode/==` 也不含 `comment`（`TableMeta.cj:83-92`），接线时需一并纳入比较，否则"只改注释"不会被识别为变更。

### [一般][存量] #10 `page` / `singlePage` 不校验 `size`，`size == 0` 在 `Pagination` 构造里除零抛 `ArithmeticException`

- **位置**：`f_orm/src/base/SqlPartial.cj:304-309`（`size` 原样下传）、`f_orm/src/base/SqlPartial.cj:296-299`（`Pagination<R>(page: …, size: size)`）；除零点 `f_orm/src/base/Pagination.cj:36`（`this.pages = rows / size + …`）
- **来源**：存量
- **判据**：review-checklist §11「除零 / 缺少边界校验」、§10「正确性」
- **证据**：静态确定 —— `selectPage`、`page`、`singlePage` 对 `size` 没有任何 `> 0` 断言，`Pagination` 构造函数直接 `rows / size`。仓颉整数除零抛 `ArithmeticException`（官方文档 `cangjie_docs/docs/dev-guide/.../core_package_api/core_package_exceptions.md`，`ArithmeticException` 条目："算术错误（如除零）"）。
- **描述**：`size` 通常来自请求参数（`?size=`），传 0 或负数时：0 ⇒ 抛 `ArithmeticException`（栈顶在 `Pagination`，与"分页参数非法"毫无关联，容易被当成框架 bug）；负数 ⇒ `rows / -1` 得到负页数、`limit` 收到负值，SQL 行为依驱动而异。注意 `rows == 0` 也挡不住：`Pagination` 的次构造函数只把 `list()` 换成空列表，`pages` 的计算仍在主构造函数里执行（`Pagination.cj:30-48`），所以空表同样除零。
- **建议**：在 `selectPage` 入口统一校验 `size > 0`（`page >= 1`），不合法时抛 `SqlArgException` 并在消息里带上入参；`Pagination` 构造函数同样加保护（它是 public API，可被直接调用）。

### [一般][存量] #11 `FromClause.first/singleFirst/firstToMap` 靠"往 `sqlgen` 追加 LIMIT"实现，子句被复用后 `count()` / `list()` 会带着上一次的 `limit 1`

- **位置**：`f_orm/src/base/TableClause.cj:302-353`（`303`、`306`、`325`、`352` 行 `LIMIT(1)` 写进 `sqlgen`）、`f_orm/src/base/TableClause.cj:235-240`（`LIMIT` 追加到 `sqlgen`）、`f_orm/src/base/TableClause.cj:355-360`（`count()` 复用 `sqlgen`）
- **来源**：存量
- **判据**：review-checklist §11「状态副作用 / 语义与命名不符」、§2「近似重复（四个入口同一写法）」
- **证据**：静态确定 —— `LIMIT(...)` 的返回值是 `This`，被插值进字符串时走 `toString()` 得到"完整 sqlgen"；副作用是把 ` limit ? offset ?` 永久追加到 `sqlgen`，且 `executor.add(one).add(two)` 已绑定 2 个参数。`sqlgen` 是子句实例字段（`TableClause.cj:24`），生命周期 = 子句对象，四个入口都改它。
- **描述**：`let q = FROM<UserPO>().WHERE{…}` 之后先 `q.first<UserPO>()` 再 `q.count()`：count 的内层变成 `select 1 from user where … limit ? offset ?`，而上一句执行完 `clearSql()` 已把绑定参数清空 ⇒ 占位符 2 个、参数 0 个，驱动报参数个数不匹配（宽松绑定时 `limit NULL` 同样不合法）。同理 `q.list<UserPO>()` 会带着残留的 limit 一起执行。链式 API 的惯例是"子句用完即弃"，所以这是陷阱而非必然崩溃，但 `first`（语义是"只取一条"）不该改写对象状态。
- **建议**：`first/singleFirst/firstToMap` 改成不改 `sqlgen`：用局部副本拼 `select * ${sqlgen}${dialectLimitSql}`（把 `dialect.limit` 的 SQL 片段单独取出，参数仍旧 `add`），或干脆调用 `page(size: 1)` 的实现路径。子句若支持复用，应在 `count()` 里显式剥掉 LIMIT；若不支持，加注释并在 `toString()` 外部说明单次使用。

### [一般][存量] #12 `Transactional.getPropagation()` 等 4 个公共 getter 与 `TransactionAspect` 重复实现且已漂移：getter 说 `Required`，实际生效的是配置值

- **位置**：`f_orm/src/base/Transactional.cj:32-64`（`getPropagation` / `getIsoLevel` / `getAccessMode` / `getDeferrableMode`）对照 `f_orm/src/base/TransactionAspect.cj:45-71`（切面自己的 6 段 `if (x.isNone()) { …ORMConfig.get… }` 回落逻辑）
- **来源**：存量
- **判据**：review-checklist §2「跨层复制（同一回落规则两份实现）」「重复逻辑导致的行为漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `getPropagation()` 在注解未指定时硬编码 `Required`，而切面用的是 `ORMConfig.getTransactionPropagation(driverName:)`；`getIsoLevel/getAccessMode/getDeferrableMode` 三个 getter 虽然读了配置，但 `TransactionAspect` 完全不调用它们（全仓 `grep "getPropagation()\\|getIsoLevel()"` 只命中定义处）。也就是说同一个注解有两套"默认值解析"，其中一套没人用、且结论不同。
- **描述**：`transactional.getPropagation()` 是 public API（注解对象对外可见），下游若用它判断"这个函数会以什么传播行为执行"会得到 `Required`，而真实执行可能是配置里的 `RequiresNew`——诊断/自省场景直接误判。后续若有人给 `ORMConfig` 增加新的回落维度，必须记得改两处。
- **建议**：让切面调用注解自身的 getter（`x.getPropagation()` / `x.getIsoLevel()`…），把"注解优先、配置回落、最终默认"收敛到 `Transactional` 一处；`driverName` 需要在 getter 内部解析（`driverName.isEmpty()` ⇒ 默认驱动）后再查配置。

### [轻微][存量] #13 `appendPartial` 的"自定义 trim"分支在仓内不可达（14 处调用实参只有 `''` / `'and|or'` / `','`）

- **位置**：`f_orm/src/base/TableClause.cj:48-56`（`53-55` 的 `else` 分支）；调用点 `TableClause.cj:142/153/170/177/183/189/233/255/265/271/382/414/417/420`
- **来源**：存量（`git blame`：`245fecb0cb 2026-10-05`）
- **判据**：review-checklist §1「恒真恒假分支 / 无调用者的分支」
- **证据**：静态确定 —— `grep -n "appendPartial("` 的全部调用第三个实参（`trim`）都是字面量 `'and|or'`、`','`、`''`；`condition(...)` 转发时 `trim` 也只来自 `WHERE/AND/OR/NOT/HAVING` 的固定 `'and|or'`。`TableClause` 是 `abstract sealed`（`TableClause.cj:23`），子类只能在本包内，仓内只有 `FromClause` / `UpdateClause` / `IntoClause` 三个，都在同一文件。
- **描述**：该分支动态构造正则（`solid: true`，不转义 `trim`），无任何用例覆盖；它同时是 #4 那份"漂移正则"的来源。留着它使人以为支持自定义 trim，实际一旦传入含正则元字符的值（如 `'('`）就会在编译正则时抛错。
- **建议**：删掉该分支，`trim` 改成枚举/常量集合（`''`、`'and|or'`、`','`），非法值直接抛 `IllegalArgumentException`；若确实要保留扩展点，补一条自定义 trim 的用例并转义输入。

### [轻微][存量] #14 `TransactionHooks.register<T>` 的类型参数 `T` 在函数体内完全未使用

- **位置**：`f_orm/src/base/TrsactionHooks.cj:55`（`func register<T>(hook: TransactionHook): Unit where T <: TransactionHook`）；调用方 `f_orm/src/base/ORM.cj:71`（`hooks.register<T>(hook)`）
- **来源**：存量
- **判据**：review-checklist §1「死代码（死类型参数）」、§10「可读性」
- **证据**：静态确定 —— 形参表只有 `hook: TransactionHook`，函数体只有 `list.add(TransactionHookWrap(hook, list.size)); sort(list)`，`T` 不出现在任何位置，也不参与重载解析（`ORM.registerTransactionHook<T>` 已把 `hook: T` 上转成 `TransactionHook`）。
- **描述**：读者会以为注册按类型去重或按类型分组，实际没有；结合 #6，`T` 正是实现去重最自然的抓手。
- **建议**：要么用它做去重（以 `T` 为 key 记录已注册类型），要么删掉类型参数与调用处的 `<T>`。

### [轻微][存量] #15 三个测试替身（`StatementTest` / `UpdateResultTest` / `TransactionTest`）放在 `src/base/` 且是 `public`，随模块一起发布

- **位置**：`f_orm/src/base/Statement_test.cj:18`、`f_orm/src/base/UpdateResult_test.cj:18`、`f_orm/src/base/Transaction_test.cj:18`（另 `QueryResult_test.cj` 不在本部分）
- **来源**：存量
- **判据**：review-checklist §1「仅测试使用（可见性建议）」、§14.2「测试辅助不算公开 API，但不应出现在公开面」
- **证据**：静态确定 —— 三个类都是 `public class … <: std.database.sql 接口`，位于 `src/`（非 test 包），只被 `f_orm/src/base/Connection_test.cj:27/33` 与 `Statement_test.cj:25/29/34` 引用。`TransactionTest.begin/commit/rollback` 全是空实现（`Transaction_test.cj:43-48`），`StatementTest.set` 也是空实现（`Statement_test.cj:31`）。
- **描述**：它们对外可见：下游可以 `TransactionTest()` 拿到一个"commit 什么都不做"的事务对象，静默丢事务；也污染了模块的公开 API 面。作为测试替身本身没问题，位置与可见性不对。
- **建议**：移到 `f_orm/src/test/`（或 `internal`），需要跨包使用时用测试专用依赖；`TransactionTest` 至少让 `commit/rollback` 记录调用，避免"空实现即通过"。

### [轻微][存量] #16 `UpdateClause.SET` 为空时不校验，`execute()` 会发出 `update t` 这种半截语句

- **位置**：`f_orm/src/base/TableClause.cj:381-411`（`382` 行 `appendPartial('set', ',', set())`；`409-411` 行 `execute()` 直接 `setSql().update`）
- **来源**：存量
- **判据**：review-checklist §11「缺少边界校验」、§2「与 Map 路径不一致（`no column to update`）」
- **证据**：静态确定 —— `appendPartial` 在 `emptyLogicalExpr(sql)` 为真时**不追加** `set …`，`execute()` 没有任何"是否写过 set"的检查；`SqlPartial.UPDATE(Map)` 对同一情形抛 `SqlArgException`（`SqlPartial.cj:171-172`）。
- **描述**：`UPDATE<PO>().SET{ => '' }`（动态条件算出空串）或 `SET` 里全是空片段时，SQL 变成 `update \`t\``，驱动报语法错误；两条 UPDATE 入口对"无列可更新"的处理一个报清晰异常、一个把半截 SQL 丢给驱动。
- **建议**：`UpdateClause` 记录是否写入过 `set`（或在 `execute()` 里 `if (!sqlgen.contains(' set ')) throw SqlArgException('no column to update')`）；`VALUES` 同理校验列数（见 #17）。

### [轻微][存量] #17 `IntoClause.VALUES(values: Array<Any>)` 不校验元素个数与列数一致，绑定错位只能等驱动报错

- **位置**：`f_orm/src/base/TableClause.cj:479-492`（`481` 行按 `values.size` 生成占位符，从不与 `fields.size` 比较）
- **来源**：存量
- **判据**：review-checklist §11「缺少边界校验」、§10「正确性」
- **证据**：静态确定 —— 列清单由构造函数按 `ignore/include` 过滤后存入 `fields`（`TableClause.cj:425/446/474`），`VALUES<D>` 版本按 `fields.size` 逐个取值（`496`），而 `VALUES(Array<Any>)` 只按入参长度循环；两者长度不等时生成 `insert into t(a,b,c) values(?,?)`。
- **描述**：调用方少传/多传一个值时得到驱动层语法错误；`ignoreColumns` 改变列数后忘记同步数组长度是常见误用，错误信息里没有列清单，排查成本高。
- **建议**：`if (values.size != fields.size) throw SqlArgException('values size ${values.size} does not match columns ${fields.size}')`，消息里带上列名。

### [轻微][存量] #18 `findById` / `deleteById` 各 3 个重载、`UPDATE` 的 `Array<(Column,Any)>` 与 `Map<Column,Any>` 转换、`IntoClause` 两个构造函数：同一份逻辑复制 2–6 份

- **位置**：`f_orm/src/base/TableClause.cj:282-300`（6 个函数体两两逐行相同：`findById` ×3、`deleteById` ×3，只差 `Int64`/`UInt64`/`String`）、`f_orm/src/base/SqlPartial.cj:123-143` 与 `181-187`（`Column.name → String` 映射写 4 遍）、`f_orm/src/base/TableClause.cj:427-450` 与 `451-478`（`IntoClause` 两个构造函数的过滤逻辑，一个用 `where` 谓词、一个用 `continue`，已出现写法漂移）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名 / 跨层复制 / 近似重复」
- **证据**：静态确定 —— 三个 `findById` 与三个 `deleteById` 的 SQL 文本、参数顺序、错误路径完全一致；`UPDATE` 的 4 个转换块只有目标容器类型不同；`IntoClause` 两段过滤的判据表达式分别是 `!ignoresSet.contains(mapper.dataType.columnName) && (includesSet.isEmpty() || …)` 与 `if (ignoresSet.contains(column) || !(includesSet.isEmpty() || includesSet.contains(column))) { continue }`（德摩根等价，但阅读成本与改动风险不同）。
- **描述**：`findById` 的 `idName ?? 'id'` 回落规则改一次要改 3 处（`deleteById` 亦然），`IntoClause` 过滤规则改一次要改 2 处——#9 的 `comment` 漏接线就是这种复制结构的典型后果。差异点确实是类型（`Int64/UInt64/String` 与 `String/Column` 两套键），属于业务要求，所以不建议泛型化到"一个函数包打天下"。
- **建议**：类型重载保留签名、函数体收敛到 `private func findByIdRaw(id: Any): ?T` / `deleteByIdRaw(id: Any): ?T`；`Column` 键的 4 处映射抽成 `private func columnKeyed(values: Collection<(Column, Any)>): HashMap<String, Any>`；`IntoClause` 把过滤谓词抽成 `private func wanted(mapper: QueryMapper<T>, ignores: HashSet<String>, includes: HashSet<String>): Bool`。

### [轻微][存量] #19 钩子回调没有异常隔离：任一钩子抛错会跳过同阶段剩余钩子，并可能把提交路径变成回滚路径

- **位置**：`f_orm/src/base/TrsactionHooks.cj:59-93`（7 个 `for (h in list) { h.xxx() }` 均无 `try/catch`）
- **来源**：存量
- **判据**：review-checklist §10「正确性（异常路径）」、§12.1「契约 / 异常语义」、§3「接口默认行为与实际语义不符」
- **证据**：静态确定 —— 遍历体直接调用，异常向上冒泡。`beforeCommit` 的异常会被 `SqlExecutor.execute` 的 `catch (e: Exception)` 当成业务异常（`SqlExecutor.cj:1056-1058`），进入 `afterThrowing` + `rollback` 分支，而事务其实还没提交。
- **描述**：一个钩子（比如审计写日志失败）会把"应该提交"的事务变成"回滚"，且回滚原因对业务方显示为业务异常；同时排在它后面的钩子（包括 `afterComplete` 的清理逻辑）不执行，容易留下未清理的线程上下文。
- **建议**：明确策略并写进接口注释——要么"钩子异常只记录不影响事务"（每个回调 `try/catch` + `log.error`），要么"`beforeCommit` 异常中止提交但保留原异常"（`addSuppressed`）。`afterRollback/afterComplete` 这类清理阶段应强制隔离。

### [轻微][存量] #20 `singleList()` / `singlePage(size, page)` 把默认列硬编码成 `'id'`，与 `findById/count` 的 `idName ?? 'id'` 回退策略不一致

- **位置**：`f_orm/src/base/TableClause.cj:342-344`（`singleList()` → `'id'`）、`f_orm/src/base/TableClause.cj:361-363`（`singlePage(size, page)` → `'id'`）；对照 `f_orm/src/base/TableClause.cj:283/293`（`T.queryMappers().idName ?? 'id'`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符 / 契约不一致」
- **证据**：静态确定 —— 同文件内两种"默认主键列"来源并存：`findById`/`deleteById`/`count` 走 `idName`，`singleList`/`singlePage` 直接用字面量 `'id'`。`README.md:969` 只承诺了前者。
- **描述**：主键列不是 `id`（如 `user_id`）的 PO 调 `singleList()` 会 `select id …` 直接报"列不存在"；而 `findById` 同类调用是正常的。用户必须显式传列名才能用，默认值形同陷阱。
- **建议**：两处都改成 `T.queryMappers().idName ?? 'id'`；`singlePage` 已有泛型约束 `R <: DataFields<R>`，取不到 mapper 时保留 `'id'` 并注释说明。

### [轻微][存量] #21 用例改完全局状态不恢复：`Config` 键、`stuck` 驱动、`MOCKDB.execution` 会泄漏到后续用例

- **位置**：`f_orm/src/base/SqlExecutorConnectingTimeout_test.cj:102-103`（`Config.set([('stuck_orm_connectingTimeout','50')])` + `ORM.register(StuckDriver(), …)` 之后无清理）；同类形态 `f_orm/src/base/SqlResultCache_test.cj:43-50`、`f_orm/src/base/SqlResultCacheStream_test.cj:47-51`、`f_orm/src/base/SqlPartialColumnKey_test.cj:93-99`
- **来源**：存量
- **判据**：review-checklist §11「资源不对称（测试侧）」、§10「可测试性」
- **证据**：静态确定 —— 四个文件都在用例内改写下述之一：进程级 `Config`、`ORM` 的驱动注册表、`MOCKDB` 的全局 `execution` 闭包；`ex.close()` 只收尾 executor，不动这些。`SqlResultCache_test.cj:58-76` 的注释已经承认"executor 与缓存按线程复用，用例之间若共用 SQL 文本会互相污染"，靠"每个用例用不同 SQL 文本"绕开。
- **描述**：用例顺序或并行度一变就互相干扰（例如后续用例用 `mockdb` 默认驱动时被上一个用例的 `execution` 闭包接管）；`stuck_orm_connectingTimeout=50` 留在配置里，其他驱动若同名键会受影响。
- **建议**：`@AfterEach`/`@AfterAll` 里恢复：`Config` 还原原值、`ORM.deregister('stuck')`、`MOCKDB.clear()` + `MOCKDB.execution = 默认`；或把驱动名/SQL 文本改成带用例前缀的唯一值（已有部分用例这么做）。

### [轻微][存量] #22 文件名 `TrsactionHooks.cj` 拼写错误；`@ORMEmbedSensitive()` 落在文件末尾、目标不明确

- **位置**：`f_orm/src/base/TrsactionHooks.cj`（文件名，缺 `n`）；`f_orm/src/base/imports.cj:38`（注解）与其后 `:40` 的 `func emptyLogicalExpr`
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 可维护性」、§1「注解目标待确认」
- **证据**：待确认 —— 文件名拼写静态确定；注解部分：`ORMEmbedSensitive` 展开为 `private let _ = {=> … }`（`f_orm/src/ProtectedMacros/EmbedSensitive.cj:28-52`），是**声明**而不是修饰符，与 `imports.cj:38` 之后隔了一个空行的 `emptyLogicalExpr` 之间是否构成"注解 + 被注解声明"关系，仅靠读代码无法判定（仓内无第二处用法可对照，也没有编译产物可查）。
- **描述**：文件名拼错会让 `grep Trsaction`/按名跳转找不到定义。注解若绑定到 `emptyLogicalExpr`，该函数会被替换成 `private let _`，`TableClause.cj:58` 的调用将无法解析；若是独立宏调用，则它与"敏感配置注册"的语义和所在函数毫无关系，需要一行注释说明为什么放在这里。
- **建议**：文件重命名为 `TransactionHooks.cj`；把 `@ORMEmbedSensitive()` 放到明确的宿主声明上（或单独一个 `Sensitive.cj`），并加注释说明展开结果与放置原因。

### [轻微][存量] #23 `FromClause.deleteById` 返回 `?T`（实为对 DELETE 执行 `first<T>()`），调用方拿不到影响行数

- **位置**：`f_orm/src/base/TableClause.cj:292-300`
- **来源**：存量（`README.md:971` 已把该行为写成"注意事项"）
- **判据**：review-checklist §11「契约与实现不符（返回值语义）」、§10「设计合理性」
- **证据**：静态确定 —— 三个重载都是 `executor.setSql('delete …').first<T>()`，`first` 走查询通道；DELETE 不产生结果集，返回值恒为 `None`（或驱动直接报错），真实的行数被丢弃。同一文件的 `Delete()` 通道（`TableClause.cj:247-252`）返回 `Int64`，说明正确语义是行数。
- **描述**：`deleteById` 看起来"删完返回被删的对象"，实际永远 `None`；业务若用 `if (deleteById(id).isNone()) { 报未找到 }` 会 100% 走进"未找到"分支。README 已提示"日常建议用 `DELETE()`/`executor.delete`"，属于已知设计债。
- **建议**：改成 `Int64`（返回受影响行数），或保留签名但改为 `delete … ; select * …` 两步并在文档里写清；这是一次破坏性 API 变更，需要单列发布说明。

<!-- 第 6 部分 -->

### [严重][存量][S1] schema 查询 PO 的列集/类型与真实结果集不对齐，`listTables` / `findTableSchema` / `findIndexes` 必然抛异常

- **位置**：`f_orm/src/migro/MysqlSchema.cj:25-50`（两个 PO 定义）、`:59-68`（`listTables`）、`:69-79`（`findTableSchema`）、`:80-96`（`findIndexes`）；`f_orm/src/migro/PostgresSchema.cj:25-68`（两个 PO 定义）、`:76-86`（`listTables`）、`:87-106`（`findTableSchema`）
- **来源**：存量（快照模式，无 git 基线；`git log` 显示这两个文件由 `a77900c79 feat(f_orm): 实现数据库表元数据解析和迁移功能` 引入，后续 `53e453d54` / `84617aecf` 只修了 driverName / DROP TABLE / 转义，未触及本问题）
- **判据**：review-checklist §11（契约与实现不符）+ §10 正确性（`Option` 被静默丢弃 / 非空映射）
- **证据**：静态确定 —— 四处查询可逐列比对；映射链路为 `QueryMappers.map` 对每个 mapper 无条件 `populate`（`f_orm/src/base/QueryMappers.cj:77-83`）→ 非空简单类型字段的 putter 是 `x.getOrThrow{ORMException(...)}`（`f_orm/src/macros/QueryMappersGenerator.cj:370-378`），而缺列时 `QueryResultWrap.getOrNull(columnName)` 返回 `None`（`f_orm/src/wrap/QueryResultWrap.cj:988-993`）。`is_nullable` / `non_unique = 0 as is_unique` 的类型转换属**需实测**（取决于驱动上报类型），但缺列问题不依赖驱动。
- **描述**：一个 PO 被复用来承载两种不同的结果集，导致「PO 字段集」与「SELECT 列表」永远对不齐：
  1. `MysqlSchema.cj:59-68` 的 `select table_name` 只有 1 列，而 `MysqlTableSchemaPO` 有 6 个字段、其中 5 个非空（`column_name` / `column_type` / `is_nullable` / `extra` / `table_name`）→ 第一行映射就在 `column_name` 上 `getOrThrow` 抛 `ORMException`。
  2. `MysqlSchema.cj:69-79` 的 `findTableSchema` 不查 `table_name`，但 PO 有非空字段 `tableNameFromDb`（`MysqlSchema.cj:38-39`）→ 同样抛异常。
  3. `PostgresSchema.cj:76-86` 的 `select table_name` 同样缺 PO 的 4 个非空字段。
  4. `PostgresSchema.cj:87-106` 不查 `table_name`，但 PO 有非空 `tableNameFromDb`（`PostgresSchema.cj:39-40`）；且 `generation_expression`（`:34-35`）对普通列在 `information_schema.columns` 里是 NULL，非空 `String` 字段同样会在 `getOrThrow` 上抛异常。
  5. 类型侧：`is_nullable` 在 information_schema 里是字符串 `'YES'/'NO'`，而字段声明为 `Bool`（`MysqlSchema.cj:32-33`、`PostgresSchema.cj:32-33`）；`QueryResultWrap.convertFromString` 的 `match(None<T>)` 没有 `?Bool` 分支，落到 `case _ => throw ORMException('String YES cannot be parsed to ...')`（`f_orm/src/wrap/QueryResultWrap.cj:108-128`）。`non_unique = 0 as is_unique`（`MysqlSchema.cj:83`）在 MySQL 里是 BIGINT 0/1，映射到 `unique: Bool`（`MysqlSchema.cj:48-49`）同样走 `_ => throw`（`QueryResultWrap.cj:196-198` 同型分支）。
- **后果**：`dbmigro` 的取库现状环节整体不可用——要么抛异常中断，要么（若某驱动把缺列当空串）得到「库里没有这张表」的假象，进而对**已存在的表**生成 `create table`、并跳过 `drop table` 清理。README 承诺的「比对数据库现状生成 DDL」（`f_orm/README.md:1814`、`:2010-2016`）因此不成立。
- **建议**：拆 PO——`listTables` 用只含 `table_name` 的单字段 PO，`findTableSchema` 用不含 `table_name` 的 PO；`is_nullable` 用 `String` 字段（或 SQL 侧 `is_nullable = 'YES' as nullable` 转成布尔）；`unique` 改为 `non_unique = 0` 与 `Bool` 的显式转换（`CAST(... AS SIGNED) = 1` 或直接映射 `?Int64` 再自行比较）；`generation_expression` 改 `?String`。补一条连真库的集成测试（当前 `migro_test.cj` 只测 DDL 字符串，三个取库方法零覆盖）。

### [严重][存量][S2] `resource{}` 里交出懒加载迭代器，迭代器在语句/连接已关闭后消费

- **位置**：`f_orm/src/migro/MysqlSchema.cj:60-67`、`:70-78`、`:81-95`；`f_orm/src/migro/PostgresSchema.cj:77-85`、`:88-105`、`:108-122`
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（资源不对称 / 生命周期）+ 本模块 `SqlExecutor` 自身的移交契约
- **证据**：静态确定 —— `resource(res, fn)` 在 `finally` 无条件 `res.close()`（`f_base/src/resource.cj:18-24`）；`SqlExecutor.close()` 会关语句、关连接并把线程内 current executor 摘掉（`f_orm/src/base/SqlExecutor.cj:153-174`）；而 `iterator<T>()` 返回的 `QueryResultIterator` 是**懒**的，`next()` 时才 `mappers.doMap(result)`（`f_orm/src/base/QueryResultIterator.cj:68-88`），`QueryResultWrap` 构造只取列信息、不预取行（`f_orm/src/wrap/QueryResultWrap.cj:48-55`）。`SqlExecutor` 的注释明确禁止在迭代器关闭前归还连接：「结果集已移交迭代器（executeIterator 通道）时不能在这里归还连接」（`f_orm/src/base/SqlExecutor.cj:893-899`），靠 `activeQueryResult` 标记（`:963-1006`）保护，而 `resource` 的显式 `close()` 绕过了这层保护。
- **描述**：六个方法都在 `resource(ORM.executor(driverName)){exe => ...}` 内构造 `.iterator<T>().map{...}` 后就返回，`resource` 退出时连接与语句已关闭，调用方（`SchemaFinderMediator` 在 `findTableSchema(...).fold(...)` 处才开始消费）读到的是已关闭的结果集。
- **后果**：表现为空迭代器或 `SQLException`（取决于驱动是否整包缓冲结果集）。空迭代器的后果与上一条相同：把现有表判成新表；同时 `activeQueryResult` 留在 `true`、连接被提前归还，后续在同一 executor 上的执行会报 "cannot execute SQL while a previous query result is still active"。
- **建议**：不要用 `resource` 包裹「交出迭代器」的方法；改为在方法内部就地物化（`fold(ArrayList())` 后返回 `list.iterator()`），或返回已带 `Resource` 语义的迭代器（`QueryResultIterator` 自己实现 `Resource`，调用方 `try (it = ...)`）；若必须流式，让调用方持有 `exe` 并负责 `close()`。

### [严重][存量][S3] 列重命名同时生成 `rename/change` 与 `add column`，DDL 冲突

- **位置**：`f_orm/src/migro/MysqlSchema.cj:124-139`（`:126` 生成 `change old new`，`:136-138` 又生成 `add column`）；`f_orm/src/migro/PostgresSchema.cj:157-201`（`:159` 生成 `rename column ... to`，`:192-193` 又生成 `add column`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）+ §2（近似重复：两段分支少了「排除已重命名列」的判断）
- **证据**：静态确定 —— 第一轮遍历 `currentColumnMap` 用 `oldColumnMap` 命中重命名列并生成改名语句；第二轮遍历 `new` 时，新列名在 `currentColumnMap` 里必然不存在（库里仍是旧名），于是落进 `else` 的 `add column`。README 承诺「`oldColumnName` 非空且与库中不一致 → 按重命名处理」（`f_orm/README.md:2016`）。
- **描述**：对 `oldColumnName = "email"`、`columnName = "email_addr"` 的列，MySQL 生成 `alter table t change email email_addr ...` + `alter table t add column email_addr ...`；Postgres 生成 `rename column name to full_name` + `add column full_name ...`。后者必然报「column already exists」。
- **后果**：任何带改名的迁移都会在中途失败（`auto` 模式下该语句失败后继续执行后续语句，库处于半迁移状态）。现有测试恰好掩盖了它：`f_orm/src/migro/migro_test.cj:113-122`、`:169-178` 只断言 `sqls[0]`/`sqls[last]`，不断言语句条数。
- **建议**：第二轮遍历增加跳过条件（`column.oldColumnName != ''` 且已由第一轮处理），或先把「重命名列」从 `new` 的 add 候选集里剔除；同时把测试改为断言完整语句列表。

### [严重][存量][S4] Postgres 新建索引只输出一个 `";"`：索引与唯一约束静默不创建

- **位置**：`f_orm/src/migro/PostgresSchema.cj:204-219`（`:214`、`:216` 直接拼 `"${i.def};"`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §14.1（承诺了但没实现）+ §11（静默失效）
- **证据**：静态确定 —— `new` 侧的 `IndexMeta` 来自 `IndexMeta(schema: IndexSchema)`，该构造器只设 `name/columns/unique`，`def` 保持 `''`（`f_orm/src/base/TableMeta.cj:106-110`，字段默认值见 `:99`）；`def` 只在读库路径被赋成 `pg_indexes.indexdef`（`PostgresSchema.cj:119`）。因此新索引的 `def` 恒为空串。
- **描述**：`generateIndexSql` 对「新索引」和「变更索引」都执行 `'${i.def};'`，`def` 为空时产出的是一条只有分号的语句。README 承诺「对比新旧索引生成变更语句（增删索引）」「索引优先使用 `IndexMeta.def` 原样重建」（`f_orm/README.md:2016`），但新建索引没有任何可原样重建的 `def`。
- **后果**：Postgres/OpenGauss 上新增索引不会生效，`unique` 索引对应的唯一性约束也不会建立——不报错、不中断，属于静默的数据完整性缺口；drop 旧索引却照常执行，所以「先删后建」的变更会让索引彻底消失。
- **建议**：`def` 为空时按 `columns/unique` 生成 `create [unique] index ${name} on ${table} (${columns})`；`def` 仅用于「库中已有索引」的重建路径，并在 `IndexMeta` 文档里写清这个前提。

### [一般][存量][G1] `PostgresSchema.findIndexes` 忽略 `database` 参数且不按 schema 过滤

- **位置**：`f_orm/src/migro/PostgresSchema.cj:107-112`（SQL 只有 `tablename` 条件）、`:209`、`:213`（`drop index ${i.name}` 不带 schema）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（读了不用 / 语义与签名不符）+ §12.1 无关但同一根因：`listTables` 限定 `table_schema = 'public'`（`:82`），`findTableSchema` 只限定 `table_catalog`（`:101-102`），`findIndexes` 两者都不限定，三条查询的作用域不一致
- **证据**：静态确定 —— `database` 形参在方法体内零引用；`pg_indexes` 由 `(schemaname, tablename)` 共同定位
- **描述**：同名表存在于多个 schema 时，`findIndexes` 会把其它 schema 的索引一并取出，diff 后对它们生成 `drop index <name>`；`drop index` 不带 schema 又依赖 `search_path`，可能删错对象或因找不到而报错。
- **建议**：`where schemaname = 'public' and tablename = ${arg(tableName)}`（或把 `database` 实参拆成 `catalog` + `schema`），`drop index` 带上 `public.` 前缀；`findTableSchema` 同步补 `table_schema` 条件。

### [一般][存量][G2] `PostgresTableSchemaPO.extra` 无条件拼 `generated always (...) STORED`

- **位置**：`f_orm/src/migro/PostgresSchema.cj:42-46`（使用点 `:128` 的 `generateColumn`、`:193` 的 `add column`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（语义与命名不符）+ §14.1（半成品）
- **证据**：静态确定 —— getter 没有对 `generationExpression` 为空串的分支
- **描述**：普通列 `generationExpression` 为空，`extra` 得到 `generated always () STORED`，`generateColumn` 会把它贴到每一列的列定义后面，`create table` / `add column` 因此非法；而生成列本身也不对——PostgreSQL 需要 `GENERATED ALWAYS AS (expr) STORED`，这里缺 `AS`。
- **建议**：`if (generationExpression.isEmpty()) { '' } else { 'generated always as (${generationExpression}) stored' }`。

### [一般][存量][G3] `esc` 只转义单引号：MySQL 反斜杠可击穿字面量

- **位置**：`f_orm/src/migro/MysqlSchema.cj:97-99`、`f_orm/src/migro/PostgresSchema.cj:124-126`（同一实现两份）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §10 安全性（SQL 字面量转义不完整）+ §2（跨文件重复）
- **证据**：静态确定（MySQL 默认 `NO_BACKSLASH_ESCAPES` 关闭，`\` 是转义符；PostgreSQL 在 `standard_conforming_strings = on` 时反斜杠是普通字符，故只需处理单引号）
- **描述**：默认值以反斜杠结尾时（如 `default value = "C:\\"`），生成 `default 'C:\'`——反斜杠把收尾单引号转义掉，语句语法错误或把后续内容吞进字面量。默认值来自库元数据/注解，未必可信。
- **建议**：MySQL 侧按 `replace("\\", "\\\\").replace("'", "''")` 转义（或整体改用 `NO_BACKSLASH_ESCAPES` 会话模式并文档化）；把 `esc` 提到 `SchemaFinder` 同包的一个私有工具里，两处方言差异显式参数化。

### [一般][存量][G4] `listTables` 未过滤 `TABLE_TYPE`，视图被当成表

- **位置**：`f_orm/src/migro/MysqlSchema.cj:61-65`、`f_orm/src/migro/PostgresSchema.cj:78-83`
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（错误处理/语义不符）
- **证据**：静态确定（`information_schema.tables` 同时含 `BASE TABLE` / `VIEW` / `FOREIGN`）；影响面待确认（库里是否存在视图）
- **描述**：视图会被算进「库里存在但定义里没有」的集合，生成 `drop table <view>`；反过来，若视图名与新表定义重名，会生成 `create table` 撞名。
- **建议**：`and table_type = 'BASE TABLE'`（Postgres 侧 `and table_type = 'BASE TABLE'`），并对已有视图单独出 `drop view` 或直接跳过。

### [一般][存量][G5] `@ORMField` 的 `var` 分支缺 `isPublic` 校验，`private` 成员被静默改成 `public mut prop`

- **位置**：`f_orm/src/migro/../macros/ORMField.cj:46-76`（判定条件在 `:48`，对比 `PropDecl` 分支 `:78` 有 `propDecl.isPublic()`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（契约与实现不符 / 可见性）+ §2（同一意图的两分支，一处少了校验）
- **证据**：静态确定 —— `varDecl.keyword.kind == VAR && !varDecl.isStatic()` 之外没有可见性判断，生成的 tokens 固定是 `public mut prop`（`:63`）；而同文件的错误消息与文档都要求「must be modified by `public var` or `public mut prop`」（`:75`、`:82`）、「使用宏@ORMField 注解public mut prop或public var」（`:26`）
- **描述**：`@ORMField[...] private var x: Int64` 会把私有成员提升为公开属性（本模块 `MysqlTableSchemaPO` / `PostgresTableSchemaPO` 正是靠这个副作用工作）。对外部使用者来说，一个笔误的 `private` 会静默变成公共 API，且与文档/错误消息矛盾。
- **建议**：二选一并写进文档——要么 `var` 分支加 `varDecl.isPublic()` 校验（与 `prop` 分支对称）并修正本模块两个 schema PO 的写法，要么明确「`private var` 会被改写成 `public mut prop`」并给出诊断提示（`diagReport(WARNING, ...)`）。

### [一般][存量][G6] `dirty` 注入的两处静默失效：类型 token 数启发式 + `catch(_){}`

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:203`（类型 token 数判定）、`:205-207`（`try{...}catch(_){}`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §3（`catch {}` 静默吞异常）+ §11（契约不符）
- **证据**：静态确定 —— `DirtyTag.setDirtyField<T>(field: String)` 的 `T` 是被修饰的**类**，与字段类型无关（`f_orm/src/base/DirtyTag.cj:34`），所以 `dts.size == 1 || ?T || Option<T>` 这个限制没有语义依据；`Map<String, Int64>`（6 token）、`pkg.Type`（3 token）等属性会被静默跳过。
- **描述**：文档承诺「`dirty` 指定这个属性……会向 ORM 标记修改历史」（`:36-38`），但多 token 类型的属性、以及没有 setter 的属性（`decl.setter` 取不到时抛异常被吞）都不会打上脏标记，`update<T>(dirty: true)` 因此少更新字段——不报错、不告警。
- **建议**：去掉 token 数条件（改为「有 setter 就注入」）；`catch` 分支至少 `diagReport(WARNING, ...)` 或加注释说明「抽象属性无 setter，跳过」，不要空吞。

### [一般][存量][G7] 属性解析无边界检查，缺值/缺冒号时抛越界异常而非编译诊断

- **位置**：`f_orm/src/macros/ORMField.cj:123-137`（`case 'column'` 的 `i += 2` 后直接 `attrs[i]`）、`:138-140`（`converter` 同型）；`f_orm/src/macros/QueryMappersGenerator.cj:415-429`（`table:` / `classPrefix:` 等五处 `attrs[i + 2]`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（边界/越界）+ §10 错误处理
- **证据**：静态确定 —— 五处取值都没有 `i + 2 < attrs.size` 判断，也没有校验中间那个 token 是 `COLON`
- **描述**：`@ORMField[column]`、`@QueryMappersGenerator[table:]`、`@QueryMappersGenerator[classPrefix: 'U']` 末尾缺值时，宏在编译期抛 `IndexOutOfBounds` 类异常，用户看到的是宏内部堆栈而不是「attr 缺少取值」的编译错误；若写成 `classPrefix LowerUnderScore`（漏冒号）则会静默取到错位的 token。
- **建议**：抽一个 `attrValueAt(attrs, i)` 小工具，统一校验 `i + 2 < size` 与 `attrs[i + 1].kind == COLON`，失败时 `diagReport(ERROR, attrs, ...)` 并抛 `ORMException`。

### [一般][存量][G8] 列名直接当标识符生成 `prop`，非法/重名列名只会炸在生成代码里

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:462-473`（`Token(IDENTIFIER, mapperMetaFn(identifier.value)[1])`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（缺少边界校验）+ §10 可维护性
- **证据**：静态确定 —— token 拼接，无关键字/字符集/重名校验
- **描述**：`@ORMField[true "user-name"]`、列名以数字开头、列名是 `type`/`class` 之类关键字、两个字段映射同一列名，都会让生成的 `Columns` 类出现非法或重复成员；`@ORMField` 文档明确允许列名是任意字符串（`ORMField.cj:28`、`:36`），所以这是可达输入。错误最终表现为生成代码的语法错误，难以回溯到注解。
- **建议**：生成前做「列名 → 合法标识符」的显式映射（非法字符替换 + 数字开头加前缀 + 关键字加后缀），或改用 `Column("user-name")` 的索引/常量形式；重名列名直接 `diagReport(ERROR, ...)`。

### [一般][存量][G9] `ColumnMeta.comment` 不参与任何 DDL 与比较，列注释静默丢失

- **位置**：`f_orm/src/migro/MysqlSchema.cj:100-141`、`f_orm/src/migro/PostgresSchema.cj:127-203`（`generateColumn` / `generateAlterSql` 均未使用 `comment`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（读了不用 / 半成品）+ §14.1
- **证据**：静态确定 —— 在 `f_orm/src/migro/` 全目录搜 `comment` 零命中；`ColumnMeta.comment` 由 `ColumnSchema.comment` 灌入（`f_orm/src/base/TableMeta.cj:72`、`:81`），`ColumnMeta.==` 也不含 `comment`（`:86-92`）
- **描述**：PO 上声明的列注释不会出现在 `create table`，改注释也不会产生任何 `alter`（`column != c` 对注释差异为 false）。用户以为注解生效，实际静默丢弃。
- **建议**：MySQL 追加 `comment '...'`（同样要 `esc`）、Postgres 追加 `comment on column` 语句；或明确从 `ColumnSchema` 移除该字段并写进文档。

### [轻微][存量][M1] 未使用的 import：`fountain::f_regex.*`

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:22`
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `Regex` / `regexp` / `f_regex` 除该 import 外零命中
- **描述**：历史残留，增加宏库的依赖面。
- **建议**：删除该行。

### [轻微][存量][M2] 重复逻辑：索引索引化、转义、删表语句、列定义串、putter 模板

- **位置**：`f_orm/src/migro/MysqlSchema.cj:53-58` vs `f_orm/src/migro/PostgresSchema.cj:70-75`（`indexColumns` / `indexIndexes` 4 个函数逐行相同）；`MysqlSchema.cj:97-99` vs `PostgresSchema.cj:124-126`（`esc`）；`MysqlSchema.cj:110-112` vs `PostgresSchema.cj:143-145`（`generateDropTableSql`）；`MysqlSchema.cj:101` 的列定义模板在 `:126`、`:134` 又内联两次；`QueryMappersGenerator.cj:286-289 / 311-315 / 342-346 / 362-368 / 373-377 / 382-386` 六份同构 putter 闭包
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— 逐行比对
- **描述**：`indexColumns`/`indexIndexes` 两文件完全一致，`esc` 与 `generateDropTableSql` 亦同；列定义串三处内联导致「改默认值渲染」需要改三个地方（本次 `esc` 的差异就属于这种漂移风险）；六份 putter 模板只差 `converter` 分支。
- **建议**：`indexColumns`/`indexIndexes`/`generateDropTableSql` 提到 `migro` 包内的公共 `private func`（同包、不破坏分层）；方言差异（转义规则）显式参数化；列定义抽一个 `renderColumn(column, withDefault: Bool)`；putter 抽成宏内的一个辅助函数（`genPutter(name, dataType, nullable, converter)`）。差异点（MySQL 用 `change` 全量重写、Postgres 拆成多条 `alter`）属于方言要求，保留两份。

### [轻微][存量][M3] `dirty` 属性大小写判定不一致，`Dirty` 会多报一条 WARNING

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:122`（`token.value.toAsciiLower() == 'dirty'`）vs `:430`（`case (IDENTIFIER, 'dirty')`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（语义与命名不符 / 两处口径不一）
- **证据**：静态确定 —— `@QueryMappersGenerator[Dirty table: 'columns']` 在 `:122` 被认作 dirty，在 `:414-433` 落到 `case _` 报 `'Dirty is illegal attr'`
- **描述**：功能生效但同时输出误导性警告。
- **建议**：两处统一（都 `toAsciiLower()` 比较）。

### [轻微][存量][M4] 每个 `@QueryMappersGenerator` 类都注册 `TableMetas`，schema 内部 PO 启动期产生 warn 噪音

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:186-190`（生成 `private let _ = TableMetas.register<T>()`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（副作用过大）+ §1（注册了但永不使用的条目）
- **证据**：静态确定 —— `MysqlTableSchemaPO` / `MysqlIndexSchemaPO` / `PostgresTableSchemaPO` / `PostgresIndexSchemaPO` 均未标注 `@DatabaseSchema`（`MysqlSchema.cj:25-50`、`PostgresSchema.cj:25-68`），而 `TableMeta.new<T>` 找不到注解就抛 `TableMetaException`（`f_orm/src/base/TableMeta.cj:34`），`TableMetas.register` 捕获后只 `log.warn`（`f_orm/src/base/TableMetas.cj:26-32`）
- **描述**：每启动一次都会为这几个「只用来接结果集」的 PO 打 warn「register table meta error」，并把噪声混进真正的注册失败里。
- **建议**：给宏加一个「只生成映射、不注册表」的开关（如 `@QueryMappersGenerator[noRegister]`），schema 内部 PO 用它；或让 `register` 区分「缺注解 = 非表 PO」与真实失败。

### [轻微][存量][M5] `DAO` 宏的 70 行注释示例已过期，且对宏行为的描述与实现不符

- **位置**：`f_orm/src/macros/DAO.cj:21-26`（行为描述）、`:28-91`（示例代码）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（注释与实现不符）+ §13 精神（示例不可用）
- **证据**：静态确定 —— `:22` 写「在DAO接口函数的默认实现添加生成sql和调用RootDAO函数完成访问数据库的工作」，但 `expand` 只生成 `extend SqlExecutor <: $(d.identifier){}`（`:103-108`），函数体完全由使用者手写（对比 `f_llm/src/dao/mysql/MetaDAO.cj:26-38`）；示例里的 `fountain.orm.*` / `fountain.base.*`、`orm.convert<Int64>(v)`、`meet(...)`、`.donw()`（拼写错误）都已过时或不存在，`arg.name` 与函数名 `arg(...)` 同名冲突
- **描述**：注释是唯一说明 `@DAO` 用法的就地文档，照抄会编译不过，也误解宏职责。
- **建议**：把示例换成当前包名与 `ORMConverter.convert`，删掉 `meet/donw`，并改写 `:21-26` 的职责说明（「把 `SqlExecutor` 声明为 DAO 接口的实现，使接口默认方法里的 `executor` 指向当前 executor」）。

### [轻微][存量][M6] 无列场景下 `generateColumns` 生成非法代码

- **位置**：`f_orm/src/macros/QueryMappersGenerator.cj:480-485`（`builder.substring(0, builder.size - 1)` 与 `iterator[0 .. iterator.size - 1]`）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §11（空集合边界）
- **证据**：静态确定 —— 列数为 0 时 `toString` 走 `substring(0, -1)`、`iterator` 会把开头的 `[` 当末尾逗号裁掉；前提是存在没有任何 public 可变成员的 PO（标记类/空类）
- **描述**：编译期抛异常或生成 `[].iterator()` 之外的非法片段，错误信息指向生成代码。
- **建议**：`if (props.isEmpty() && vars.isEmpty())` 时直接生成 `''`/空迭代器分支，或提前 `diagReport(ERROR, ...)` 明确「该 PO 没有可映射列」。

### [轻微][存量][M7] exception 包的导入与继承口径不一致

- **位置**：`f_orm/src/exception/imports.cj:18`（`internal import fountain::f_exception.BaseException`）、`f_orm/src/exception/SqlArgException.cj:18`（`<: BaseException`）、`f_orm/src/exception/ORMException.cj:18`（同样 private 导入）
- **来源**：存量（快照模式，无 git 基线）
- **判据**：review-checklist §10 设计合理性（异常层次一致性）+ §1（隐式依赖）
- **证据**：静态确定 —— `BaseException` 在本包内只有 `SqlArgException` 直接使用；`ORMException` 另行 private 导入，两条导入机制并存；其余 11 个异常都继承 `ORMException` / `TransactionException` 家族
- **描述**：`throw SqlArgException(...)`（`f_orm/src/base/RootDAO.cj:249` 等 24 处）不会被 `catch (e: ORMException)` 捕获，与同包其他异常的行为不一致；影响面待确认（取决于调用方是否只捕 `ORMException`）。
- **建议**：`SqlArgException` 改继承 `ORMException`（若确需与 ORM 业务错误区分，可继承 `ORMException` 的子类）；`imports.cj` 的整包重导出收窄为一个文件内的 private import，避免隐式可用。

<!-- 第 7 部分 -->

### [严重][存量] #1 迁移命令的入口 `groupBy` 恒返回空 map —— `dbmigro` 一条 SQL 都不生成，且退出码为成功

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:29-30`（`TableMetas.tableMetas().groupBy{m => m.driver}`）；下游 `33-53`、`60-75`、`79-101` 全部以它为输入
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02，早于本轮快照）
- **判据**：review-checklist §11「错误处理缺失或静默 / 失败路径当成功」、§14「承诺了但没实现」
- **证据**：静态确定 —— 被调用的 `groupBy` 是 `f_base/src/ExtendIterator.cj:108-119` 的扩展实现，循环体只有一次 `m.get(k)`（读），`if`/`else` 两个分支返回的 `ArrayList<T>` 被 `.add(t)` 后即丢弃，**全程没有任何 `m[k] =` / `m.add`**，因此从 `HashMap<K, ArrayList<T>>()` 建好到 `118` 行 `m` 返回，map 始终为空。`std` 的 `Iterator` 没有 `groupBy`（标准库文档全量检索无 `func groupBy`），所以解析到的一定是这个坏扩展。
- **描述**：`generate(cmdargs)` 的全部输出都来自 `metasByDriver.iterator().flatMap{...}`（`30-58`）与 `metasByDriver.iterator().flatMap{...}`（`60-75`）。`metasByDriver` 恒为 `HashMap()` ⇒ 两个 `flatMap` 都不迭代 ⇒ `allSqls` 恒为空 ⇒ 四种模式（`file` / `auto` / `dry` / `interactive`）全部**什么都不做**：不打印、不写 `./migro.sql`、不执行；`MigroCommand.exec` 返回 `0`（`src/migro/SubCommand.cj:30-33`）。用户看到的是"迁移成功、无变更"，实际是彻底空转。同一根因还有两个连带后果（根因文件属 `f_base`，由该模块报告覆盖，这里只确认调用点）：
  1. `SchemaFinderMediator.cj:45-46` 的 `finder.findIndexes(...)` → `MysqlSchema.cj:88` 内的 `groupBy{po => po.name}` 同样恒空 ⇒ 库里的索引永远"查不到"，`generateIndexSql` 会把所有已存在的索引当成"缺失"再 `add` 一次（`alter table ... add index` 对已存在索引必然报错，然后被 #3 吞掉）。
  2. 孤儿表清理（`60-75`，正是 `doc/优化方案.md` 记录的"P1 generateDropTableSql 从未被调用"的修复）随 `metasByDriver` 一起失效，等于该修复被回退。
- **建议**：修 `ExtendIterator.groupBy`（写入 map），并在 `SchemaFinderMediator` 侧加一条自检：`metasByDriver` 为空但 `TableMetas` 非空时抛 `ORMException`（"no table meta grouped by driver"），不要"空输入 → 静默成功"。补一条用例：注册 2 个驱动各 1 张表，断言 `generate` 至少产出 2 条 `create/alter` SQL；目前 `migro_test.cj` 只测 `SchemaFinder` 的 DDL 生成（不经 `generate`），所以这条断链没有任何用例覆盖。

### [严重][存量] #2 `use <db>;` 与后续 DDL 不在同一会话执行 —— 修好 #1 后多库场景的建表/删表会落到连接的默认库

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:103-113`（`for` 循环内每条语句 `try(exe = ORM.executor(driver))`）与 `47-49`（每条驱动只插一条 `['use ${m.database};']`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「语义与注释/契约不符」、§12.1「跨线程资源 / 会话状态」
- **证据**：静态确定 —— `execute` 把 `try (exe = ORM.executor(driver))` **放在 `for` 循环体内**，每条 SQL 进出一次作用域；`SqlExecutor.close()`（`f_orm/src/base/SqlExecutor.cj:141-160`）会 `current.set(None)`、`currents.get()?.remove(driverName)`、`close()` 连接并把 `_connection_` 换成 `NoneConnection.instance`。下一条语句的 `ORM.executor(driver)` 因此**重新 `getConnection`**，拿到池里另一条物理连接。`USE db` 是会话级状态，换连接即丢失；`m.database` 与连接串默认库不同时（`@DatabaseSchema[database: ...]` 正是为这种场景准备的），`create table users(...)` / `drop table t;` 这些**不带库名前缀**的语句会落到默认库。
- **描述**：`'use ${m.database};'` 是本模块唯一表达"目标库"的手段，而它的作用域被逐语句关闭 executor 的行为抹平。两个附加事实：① PostgreSQL 没有 `USE` 语句，这一行对 `postgres` / `opengauss` 驱动本身就是语法错误（被 #3 吞掉后继续）；② 每条语句新建并关闭一次 executor ⇒ N 条语句 = N 次建连/归还，迁移期间连接数抖动。当前被 #1 掩盖（`allSqls` 恒空），修好 #1 后立刻生效。
- **建议**：`execute` 把 `ORM.executor(driver)` 提到按驱动分组的外层（每个驱动一个 executor / 一次会话，语句间不关闭），或在 SQL 文本里直接拼库名（`${database}.${table}`）；`use` 语句只对支持它的方言生成（放进 `SchemaFinder` 的方言能力里，而不是在 mediator 里硬编码）。连接复用要顺带核对 README `README.md:545` 的 `close()` 语义（事务中不关闭、提交后由 `finishTransaction` 收尾），别在事务里提前关。

### [一般][存量] #3 迁移语句失败被就地吞掉，命令恒返回 0 —— 部分应用的 DDL 与"成功"无法区分

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:107-111`（`try { exe.setSql(sql).update } catch(e: Exception) { e.printStackTrace() }`）；退出码在 `f_orm/src/migro/SubCommand.cj:30-33`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §3「静默吞异常」、§11「错误处理缺失」
- **证据**：静态确定 —— `catch` 只 `printStackTrace()`，不计数、不抛出、不改变返回值；`generate` 返回 `Unit`，`MigroCommand.exec` 无条件 `0`。
- **描述**：DDL 逐条独立执行（见 #2），任一条失败后**后续语句继续**，最终库处于"改了一半"的状态，但进程退出码为 0。`auto` 模式（无人值守）下 CI / 发布脚本无法感知失败；配合 #1 的"0 条 SQL"场景，"什么都没做"与"全部成功"完全同形。
- **建议**：`execute` 返回失败条数（或收集 `(sql, exception)`），`generate` 在有失败时抛 `ORMException`（带第一条失败 SQL 与计数），`MigroCommand.exec` 返回非 0；`auto` 模式建议整体放进一个事务（MySQL DDL 隐式提交，需按方言说明"不可回滚"）。

### [一般][存量] #4 表元数据里的 driver 没有对应 `SchemaFinder` 时抛 `NoneValueException`，且不带驱动名

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:34`、`62`（`let finder = finders[driver]`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「空值未处理」「错误处理缺失」
- **证据**：静态确定 —— `finders` 是 `ConcurrentHashMap<String, SchemaFinder>`，本 SDK 的 `operator func [](key: K): V` 在键不存在时抛 `NoneValueException`（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:1832-1852`），不是返回 `?V`。`finders` 只在 `init`（`24-27`）里用 `lookupList<SchemaFinder>()` 填充，仓内实现的 `driverName` 只有 `mysql` / `mariadb` / `postgres` / `opengauss`（`MysqlSchema.cj:165/173`、`PostgresSchema.cj:223/231`）。
- **描述**：`@DatabaseSchema[driver: ...]` 可以写任意驱动名（`mockdb`、`sqlite`、`dm`…）。这类表一旦进入 `TableMetas`，`generate` 直接抛 `NoneValueException`（栈里没有驱动名、没有表名），用户无法判断是"这个驱动不支持 DDL"还是"注册丢了"。`init` 里 `lookupList` 返回空（bean 未初始化）时也是同一现象。
- **建议**：改用 `finders.get(driver)`，`None` 时抛 `ORMException('no SchemaFinder registered for driver ${driver}; registered: ${...}')`；`init` 末尾对空 `finders` 打一条 warn。

### [一般][存量] #5 `-m` 是最后一个参数时 `cmdargs[i + 1]` 越界崩溃；同一循环只处理第一个 `-m`

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:79-80`（`for(i in 0 .. cmdargs.size where ...) { match(cmdargs[i + 1]) ... }`），`89-97`（interactive），`100`（`break`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界差一 / 越界」、§10「缺少边界校验」
- **证据**：静态确定 —— `i` 的取值域是 `0 .. cmdargs.size`，当 `-m`/`--mode` 位于末尾时 `i + 1 == cmdargs.size`，`Array` 下标越界抛 `IndexOutOfBoundsException`。循环体末尾的 `break` 又保证只认第一个 `-m`，`-m auto -m file` 静默丢弃后者。
- **描述**：`dbmigro -m` 这类少写一个参数的调用直接崩栈，报错与"参数缺失"无关；多写一个 `-m` 时不报错也不算。两种都是"用户输入未被校验"。
- **建议**：先 `if (i + 1 >= cmdargs.size) throw ORMException('--mode requires a value')`；收集全部 `-m` 后按"后者覆盖前者 或 重复即报错"明确一种语义（fountain 基线偏好"同名冲突直接失败"）。

### [一般][存量] #6 孤儿表清理阶段：视图未过滤、只覆盖 `metas[0].database`、无白名单/无确认

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:60-75`（`knownNames` 在 `63-66`，`metas[0].database` 在 `68`，`filter{!knownNames.contains(...)}` 在 `69`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02；`doc/优化方案.md:16-19` 记录该能力是本次新增）
- **判据**：review-checklist §11「契约与实现不符」、§5「无拒绝路径」、§10「安全性（数据破坏面）」
- **证据**：静态确定（代码形态）+ 待确认（方言事实）—— `listTables` 的实现是 `select table_name from information_schema.tables where table_schema = ?`（`MysqlSchema.cj:62-66`），**没有 `table_type = 'BASE TABLE'` 过滤**；MySQL 的 `information_schema.tables` 同时包含视图，视图会被 `generateDropTableSql` 生成 `drop table <view>` 并在 `auto` 模式执行（必然报错，再被 #3 吞掉）。`metas[0].database` 只取该驱动第一张表的库：同一驱动下声明了多个 `database` 时，其余库的孤儿表永远不会被列出，而生成的 `drop` 又不带库名前缀（见 #2），存在"在错的库里删同名表"的窗口。
- **描述**：`drop table` 的集合 = "库里所有未声明的表"，没有任何排除清单（视图、他人维护的表、临时表），`auto` 模式也没有确认步骤。这是设计选择（注释写明 "orphaned tables"），但对共享库/生产库是数据破坏面；对多库 + 视图则确定是错的。
- **建议**：`listTables` 增加 `table_type = 'BASE TABLE'`；按 `database` 分组生成（而不是 `metas[0]`）；`drop` 之前要求显式开关（如 `--allow-drop`）或至少把 `drop` 语句单独成段、`auto` 模式下默认不执行。

### [一般][存量] #7 `makeReader` 与 `toMap()` 是两张 typeName 表，同名类型结论不一致（`SqlByte` → `Int8` vs `UInt8`）

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:66`（`case 'SqlByte' | 'Int8' => getOrNull<Int8>`）与 `1013`（`case 'SqlByte' | 'Byte' | 'UInt8' => get<UInt8>`）；另一处口径差在 `60-79`（`makeReader` 无任何 `SqlNullable*` 分支，未知名落 `String` 兜底，`78`）与 `1002-1029`（`toMap` 逐个处理 `SqlNullable*`）
- **来源**：存量（`git blame`：`66` 为 `83e7547f7` 2026-10-05，`1013` 同文件历史更早；两表并行存在）
- **判据**：review-checklist §2「字面量复制 / 只改类型名」、§13（同文件内对同一 typeName 的两处结论不同）
- **证据**：静态确定 —— 同一列 `typeName = 'SqlByte'`，走 `get<Int8>()` 得到有符号值，走 `toMap()` 得到无符号值（-1 → `Int8(-1)` vs `UInt8(255)`）。`SqlNullable*` 只在 `toMap` 里被识别，`makeReader` 一律走 `getOrNull<String>`，于是"nullable 数字列"实际是靠 `convertFromString` 二次解析救回来的（见 #13），"nullable bool / blob / clob" 则救不回来（`convertFromString` 没有 Bool，Blob 走 `?String` 分支必然抛）。
- **描述**：`doc/spec/fix-orm-queryresultwrap-type-alias/design.md:77` 已把"两张表未来可能再次漂移"记为已知结构性风险，本次审查确认漂移已经发生（`SqlByte`）。本仓三个驱动上报仓颉类型名（同文档 `design.md:12`），所以 `Sql*` 名字只有第三方驱动才会出现——影响面因此是"接第三方驱动时行为不一致"，而不是全量错。
- **建议**：合并成一张 `typeName -> (getter, 是否可空)` 表，`makeReader` 与 `toMap` 共用；先行补 `SqlNullable*` 到 `makeReader`（或把两处的未知名兜底都改成显式报错），并用 `QueryResultWrap_test.testEveryReaderBranchAndAlias` 之外再加一条"同一 typeName 经 get 与 toMap 结果一致"的用例。

### [一般][存量] #8 配置解析失败的处理策略不统一：声明"退回默认值"，实际 6 个 getter 直接抛异常

- **位置**：`f_orm/src/wrap/ORMConfig.cj:129`（`Bool.parse(x)`）、`338`、`347`、`357`、`366`、`372`、`378`（`Int64.parse` / `Int32.parse`）；对照 `184-192` 的 `get<T>`（用 `T.tryParse` 退回 `default`）与 `178-183` 的注释承诺
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「契约与注释不符」、§10「错误处理」
- **证据**：静态确定 —— `parse` 解析失败抛异常、`tryParse` 返回 `None`（`stdlib/doc/libs/std/convert/convert_package_api/convert_package_interfaces.md:758-768`）。注释 `179-182` 明确写"配置里写错值不该让进程在读取时抛异常……非法值应按默认值处理"，`ORMConfigTest.testPoolMaxWaiting`（`ORMConfig_test.cj:41-42`）钉的也是这条。但 `getUseCache`（每个 `SqlExecutor` 构造都会调，`SqlExecutor.cj:62`）与 6 个 `getStdPool*`（`NamedDatasource.cj:67-84` 在 `useStdPool` 默认 true 时逐个调）用的是 `parse`。
- **描述**：`orm_useCache=yes` 会在**第一次执行 SQL** 时抛 `IllegalArgumentException`；`orm_stdPoolMaxSize=10x` 会在**构造数据源**时抛异常 ⇒ 启动失败。同一份配置文件，一半键非法会退回默认、另一半会炸，行为不可预期；错误信息也不含键名。
- **建议**：全部改成 `get<T>(...)`（`T <: Parsable<T>`）或 `tryParse` + 默认值；非法值时打 warn（含键名与原文）。`transactionIncluding/Excluding` 的 `Regex(reg)`（`74-79`）同理：非法正则目前会让 `static init` 直接抛，建议 try 住并 warn + 视为"不配置"。

### [轻微][存量] #9 `wrap/NoneConnection.cj` 与 `base/NoneConnection.cj` 逐行重复、全仓零引用

- **位置**：`f_orm/src/wrap/NoneConnection.cj:21-43`（对应 `f_orm/src/base/NoneConnection.cj:21-43`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02，与 base 那份同批存在）
- **判据**：review-checklist §1「非 public 顶层类型无引用 ⇒ 其 `public` 成员同样不可达」、§2「只改类型名/跨包复制」
- **证据**：静态确定 —— 全仓 `grep -rn NoneConnection --include=*.cj` 只命中 `f_orm/src/base/SqlExecutor.cj:117/119/126/171/329/411`，它们都在 `fountain::f_orm.base` 包内、解析到 base 那份；`src/wrap/` 内及任何其它包对 `fountain::f_orm.wrap.NoneConnection` 零引用。两份文件的类名、单例 `instance`、5 个成员逐行一致（后者只差 `package` 声明）。
- **描述**：该类没有访问修饰符 ⇒ 只在本包可见，属"包内放宽的 `public` 成员"，全项目无使用即死代码。风险不只是冗余：`SqlExecutor` 的 `_connection_ is NoneConnection` 绑定的是 base 类型，若本包内有人写 `NoneConnection.instance`（同名、同包），拿到的是另一个类型，`getInstance` 的"Closed → 重置连接"判断会静默失效。
- **建议**：删除 `src/wrap/NoneConnection.cj`；确需跨包引用就改成重导出（`public import fountain::f_orm.base.NoneConnection`），不要复制类。

### [轻微][存量] #10 4 处 `case _ where !driverName.isEmpty()` 回退分支恒等价（死分支）

- **位置**：`f_orm/src/wrap/ORMConfig.cj:130`（`getUseCache`）、`296`（`getTransactionLevel`）、`309`（`getTransactionAccessMode`）、`323`（`getTransactionDeferrableMode`）；依据 `getConf` 在 `134-140`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §1「恒真恒假分支 / 死分支」
- **证据**：静态确定 —— `getConf` 的语义是"驱动键有值就用驱动键，否则返回全局键"。因此它返回 `None` ⇒ 全局键也是 `None`；此时递归调用 `driverName = ''` 仍读同一个全局键，必然还是 `None`。两个分支同值，递归只多一次配置读取。
- **描述**：这 4 处读起来像"驱动级缺失时回退全局"，实际上回退已由 `getConf` 完成；留着会让后续维护者以为驱动级配置有独立的兜底链（`getUseCache` 的 `?Bool` 默认值另有 `?? true`，更容易看错）。
- **建议**：删掉 4 个分支，直接 `case _ => None<...>`；把"驱动优先、全局兜底"的说明集中写在 `getConf` 上。

### [轻微][存量] #11 `getOrNull` 的 18×18 转换矩阵与 `convertFromString` / `toMap` 是三份同语义实现

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:134-979`（矩阵）、`108-133`（字符串解析）、`997-1034`（`toMap`）
- **来源**：存量（`git blame`：`83e7547f7` 2026-10-05 起的逐类型展开）
- **判据**：review-checklist §2「只改类型名 / 换算复制」
- **证据**：静态确定 —— 矩阵按"源 `Option` 类型 × 目标类型"逐条展开，`?Int8 → ?Int16 => Int16(x)`、`?Int16 → ?Int8 => Int8(x)`……共 13×13 组、每组 5 行；规则只有"宽窄转换 + `None` 传播 + 不支持则抛"一条。
- **描述**：新增一种类型（`Float16` 只在字符串路径、`Bool` 两条路径都缺）要在三处同步；#7 的 `SqlByte` 漂移就是这么来的。~700 行同构代码也是审查与改动成本（任何一处改错都只在特定类型组合上暴露）。
- **建议**：抽"统一升到 `Int64`/`Float64`/`BigInt`/`Decimal` 再降"的一条转换链 + `None` 短路，`toMap` 复用同一张列类型表；必须用等价性用例锁住 `None` 传播与异常文案。与 #O4 是同一处改造。

### [轻微][存量] #12 interactive 模式执行后不退出循环，第二次输入 `y` 会重放全部 DDL

- **位置**：`f_orm/src/migro/SchemaFinderMediator.cj:89-97`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「逻辑错误（控制流）」
- **证据**：静态确定 —— `while(let Some(r) <- getStdIn().read())` 的 `'y'` 分支只调 `execute(allSqls)`，没有 `break`；提示语在循环外只打一次，`'n'`/EOF 才退出。
- **描述**：用户按提示输入 `y` 后程序继续读下一行；再输入任何 `y` 会把全部 SQL（含 `drop table`、`alter table ... drop column`）再执行一遍，第二次必然报错并被 #3 吞掉。脚本化输入（`printf 'y\ny\n'`）可稳定复现。
- **建议**：`'y'` 分支执行完 `break`；`_` 分支重打提示或直接退出。

### [轻微][存量] #13 `convertFromString` 缺 `Bool`/`Rune` 分支，且用 `match(None<T>)` 当类型探针

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:108-133`（分支在 `111-128`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「语义与实现不符」、§10「语言特性（用值做类型探针）」
- **证据**：静态确定（分支缺失）+ 待确认（`?X` 目标是否命中）—— 分支表只有 Int8…UInt64、Float16/32/64、BigInt、Decimal、Duration、DateTime，没有 `Bool`、`Rune`；因此 typeName 未识别（落 `String` 兜底）而目标类型是 `Bool`/`Rune` 时，必然抛 `ORMException('String ${x} cannot be parsed to ...')`。目标类型靠 `match(None<T>)` 的 `_: ?X` 模式判定，而 `None<T>` 的静态类型是 `Option<T>`：`T` 为具体类型时命中，`T` 本身可空（`?Int32`）时是否命中取决于 `Option<Option<Int32>>` 与 `?Int32` 的类型测试语义，本轮未实测。
- **描述**：从签名看不出支持哪些目标类型，遗漏分支没有编译期提示（`Bool` 就是这么漏的）；字符串兜底是"未知 typeName"的唯一出路，这条路径上少两种类型就是少两种可用映射。
- **建议**：改用 `TypeInfo.of<T>()` 一次查表（与 #O4 合并），补齐 `Bool`（`true/false/1/0`）与 `Rune`；不支持时抛带列名与目标类型的 `ORMException`。

### [轻微][存量] #14 列名重复时 `columnInfoMap` 静默覆盖，按名取值与 `toMap` 只保留最后一列

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:51-53`（`columnInfoMap[columns[i].name] = i`）、`988-993`、`997-1032`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界/空集合未处理」
- **证据**：静态确定 —— 构造期按列名写 map，同名后写覆盖先写；`getOrNull<T>(columnName)` 与 `toMap()` 都以该 map 为唯一入口，`toMap` 的 `for ((column, index) in columnInfoMap)` 因此只产出 1 个条目。
- **描述**：`select a.id, b.id from ...`、`select 1 as x, 2 as x` 这类结果集里，按名取 `id` 静默拿到最后一列；`toMap()` 的条目数比 `columnInfos.size` 少。无异常、无日志。
- **建议**：重名时保留首个或直接抛 `ORMException`（与"同名注册直接失败"的项目偏好一致）；`toMap` 改为遍历 `columnInfos`。

### [轻微][存量] #15 事务切面正则用可变静态字段，跨线程写读无同步

- **位置**：`f_orm/src/wrap/ORMConfig.cj:69-70`、`72-81`、`259-262`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1「可见性」「共享可变状态无保护」
- **证据**：待确认 —— 写入点是 `static init()` 与 `Config.refresher` 注册的 `fn`（`ORMConfig.cj:82-85`），`fn` 由 `Config.set` 在**调用方线程**同步执行（`f_config/src/Config.cj:101-126`）；读取点是 `transactionable`（事务切面，可在任意请求线程）。字段是普通 `private static var`，无原子/无同步/无 `volatile` 语义；引用赋值不会撕裂，但可见性无保证。若配置只在启动期 `set`，实际影响≈0。
- **描述**：当前"启动期一次性写入"把问题掩盖了；一旦运行期 `Config.set` 改事务切面正则，其他线程可能长期读到旧 `Regex` 或 `None`——属于"写完立刻被看到"的可见性假设。
- **建议**：把两个正则合成一个不可变快照（`?Regex, ?Regex`）用原子引用整体替换；或读侧加一次 `synchronized`。

### [轻微][存量] #16 `AnnotatedQueryMappers_test.cj` 只有 SPDX 行，缺 Apache 2.0 版权头

- **位置**：`f_orm/src/orm_test/AnnotatedQueryMappers_test.cj:1-2`
- **来源**：存量（`git blame`：该文件创建时即如此）
- **判据**：fountain 基线 §3（每个 `.cj` 必须有 Apache 2.0 注释且在 `package` 之前）
- **证据**：静态确定 —— 第 1 行 `// SPDX-License-Identifier: Apache-2.0`，第 2 行即 `package fountain::f_orm.orm_test`；同目录 `ORM_test.cj:1-15` 与本部分其余 18 个文件都是完整的 15 行头。
- **描述**：许可证声明形式与全仓不一致；按行号提取头部的脚本会漏掉该文件。
- **建议**：替换成标准头（与 `ORM_test.cj:1-15` 一致）。

### [轻微][存量] #17 `getOrNull` 只校验上界，负索引直接落到 `list[index]`

- **位置**：`f_orm/src/wrap/QueryResultWrap.cj:94-97`（`if(columns.size <= index) return None`）、`134`（`match(list[index])`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界差一 / 越界」
- **证据**：静态确定 —— `index = -1` 时 `columns.size <= -1` 为假，`99` 的 `if (index >= list.size)` 也为假（不填充），随后 `list[-1]` 抛 `IndexOutOfBoundsException`，被 `980-983` 包成 `ORMException`，文案变成"colum index: -1 ... requires: ..."。
- **描述**：按列序号取值时传负数，拿到的是"列类型不匹配"式异常，定位成本高；而 `getOrNull` 的契约是越界返回 `None`。
- **建议**：`if (index < 0 || columns.size <= index) { return None<T> }`。

### [轻微][存量] #18 示例 DAO 在 SET 片段全空时生成 `update ... where ...`（缺 SET 子句）

- **位置**：`f_orm/src/orm_test/ORM_test.cj:32-48`（SET 在 `35-40`，WHERE 在 `41-46`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §11「边界/空集合未处理」、§10「可读性（示例会被照抄）」
- **证据**：静态确定 —— `Condition.SET`（`f_orm/src/base/Condition.cj:40-52`）在片段 trim 后为空时返回 `''`；该 DAO 的 SET 只有 `param.name`、`param.gender` 两个可选片段，两者都不满足时整条 SQL 变成 ``update `character` WHERE `id`=?``（`WHERE` 的 delimiter 为空串，`Condition.cj:54-57`），执行必报语法错误。WHERE 里 `${meet(..., '`name`=')}` 靠 `trim` 去掉悬空 `and`（`Condition.cj:66-84`）是安全的，说明 SET 侧本该有同样的保护。
- **描述**：这是 `_test.cj` 里的示例，但它示范了 `SET{}` + `meet()` 的标准写法；使用者照抄后"所有可选字段都为空"就是必现的语法错误。
- **建议**：示例里补一条"SET 为空则跳过执行"的守卫（或在 `SET` 侧明确要求调用方保证至少一个片段），并加一条对应用例。

### [轻微][存量] #19 `NamedDatasource` 对同一组 options 应用两次（`open(url, options)` 与 `setOptions`）

- **位置**：`f_orm/src/wrap/NamedDatasource.cj:59-60`（`driver.open(url, options)`）与 `107`（`setOptions(ds, options)`）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §2「同语义副作用执行两遍」
- **证据**：静态确定 —— `newDatasource` 把 `options` 传给 `driver.open`，返回后无条件再逐项 `ds.setOption`；`setOptions` 在 `newDatasource` 内只被调用这一处。
- **描述**：对幂等 option 无害（多数驱动如此），但驱动若把 `setOption` 实现成"重建连接/只对新建连接生效"，第二次写入会与 `DatabasePool` 的预建连（`initSize`，`f_dbpool/src/DatabasePool.cj:62-72` 的 `creator`）交错——顺序不确定。更根本的是它掩盖了"以 `open` 的参数为准还是以 `setOption` 为准"这个问题。
- **建议**：二选一——`open(url)` 之后只 `setOptions`，或全部交给 `open` 并删掉 `setOptions`；在注释里写清选择理由。

### [轻微][存量] #20 `ORMConfigTest.testORMConfig` 用空 fn 覆盖全局 refresher —— 之后配置刷新不再重编事务切面正则

- **位置**：`f_orm/src/wrap/ORMConfig_test.cj:23-26`（`ORMConfig.refresh {}`）；机制在 `f_orm/src/wrap/ORMConfig.cj:82-85`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1「共享可变状态」、§11「测试污染既有全局状态」
- **证据**：静态确定 —— `refresh(fn)` 的实现是 `Config.refresher(confPrefix, fn); fn()`，即**用传入的 `fn` 覆盖** `REFRESHER['orm_']`（`f_config/src/Config.cj:101-103`）。`static init` 注册的是"重编两个 `Regex`"的闭包（`ORMConfig.cj:72-81`），测试传入的是 `{}`，之后 `Config.set` 触发的刷新永远只执行空闭包。
- **描述**：该用例只验证"`refresh` 不抛异常"，却把产品行为改掉了：同一进程内后续用例若依赖 `orm_transactionIncluding/Excluding` 生效（事务切面），看到的是 `static init` 当时的旧正则；运行期 `Config.set` 改了正则配置也不再生效。测试执行顺序不同 → 结果不同。
- **建议**：`refresh` 改成"注册即执行"且不覆盖既有回调（或提供 `refreshRegex()` 供测试）；用例改成断言"刷新后 `transactionable` 反映新正则"，而不是只调一次空 `refresh`。

<!-- 第 8 部分 -->

### [严重][存量] `InputStreamSqlArg` 的 `==` / `hashCode` 完全忽略流内容，导致「同一 SQL + 不同流参数」命中同一条结果缓存

- **位置**：`f_orm/src/wrap/SqlArg.cj:456-461`（`==`）、`f_orm/src/wrap/SqlArg.cj:450-455`（`hashCode`）；缓存键构造在 `f_orm/src/base/SqlExecutor.cj:905-906`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02；快照模式无基线可比）
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）+ §12.1（缓存键语义）
- **证据**：静态确定 —— `hashCode` 只用 `index` + `TypeInfo.of<InputStream>()` + 常量串 `'std.io.InputStream'`；`==` 在 `equals(other)`（同 index、同类、同 hash）成立后直接 `case x: InputStreamSqlArg => true`。两个内容完全不同的 `InputStream`，只要绑定位置相同，哈希相同、`==` 为 true
- **描述**：`SqlExecutor.execute<T>` 的缓存分支条件是 `useCache && !clearCache && isSelectStatement(sql)`（`SqlExecutor.cj:905`），`useCache` 默认 `true`（`SqlExecutor.cj:62`）；规避缓存的唯一措施是「结果里交出过流」（`lastResultHadStream`，`SqlExecutor.cj:915`、`978`），**只看结果方向、不看参数方向**。于是「参数是流、结果是标量」的 SELECT（如 `select id from attachment where digest = ?`，`RootDAO.arg(InputStream)` → `SqlArgs.add(InputStream)`）在**同一事务内**（`tx.isSome()` 时 `exec()` 不 close，缓存不清）连续执行两次、换一条内容不同的流，第二次直接命中第一次的结果 —— 返回上一次的行，属数据错误。可达性还有一条旁路：`_connection_` 已为 `NoneConnection` 时 `SqlExecutor.close()` 的 `!isClosed()` 短路会让缓存**不被清空**（`NoneConnection.isClosed()` 恒 `true`，`NoneConnection.cj:39-41`；`close()` 见 `SqlExecutor.cj:154-157`），executor 也留在 `currents` 线程表中继续复用
- **建议**：`InputStreamSqlArg` 的 `hashCode`/`==` 必须能区分实例（至少用 `refEq`，或按流身份生成单调 id）；更稳妥的做法是给 `SqlArg` 增加「是否可缓存（cacheable）」标记，`InputStreamSqlArg` 返回不可缓存，`SqlExecutor.execute` 在构造 key 前检查（与 `lastResultHadStream` 对称）。补一条用例：同一 executor 内两次不同流的同 SQL 查询必须各自执行

### [一般][存量] `SqlArgs` 即可变、又被 `SqlCacheKey` 直接持有，且 `==` 用 `refEq` 短路 —— 缓存键的「对象身份」被当成「参数内容相等」

- **位置**：`f_orm/src/wrap/SqlArgs.cj:120-122`（`refEq` 短路）、`f_orm/src/wrap/SqlArgs.cj:31-37`（`add` 复位 `h`）、`f_orm/src/wrap/SqlArgs.cj:109-119`（`h` 记忆化）；键持有参数见 `f_orm/src/base/SqlExecutor.cj:25-38`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §11（并发/语义）+ §1（hash/equals 契约一致性）；`SqlArgs` 的注释 `SqlArgs.cj:33-35`、`SqlExecutor.cj:100-103` 已记录同类历史缺陷 ORM-1
- **证据**：静态确定（不变量层面）；是否会产出**用户可见的错误结果**为待确认 —— 需要「同一 SQL 文本 + 复用同一 `SqlArgs` 实例 + 参数内容不同」三条件同时成立
- **描述**：ORM-1 的修法是「执行后换新 `SqlArgs` 实例」（`clearSql` → `this.args = SqlArgs()`，`SqlExecutor.cj:104`），但 `setSql(sql, clearArgsAfterExec=false)` 是公开参数，仓内 `f_orm/src/base/SqlPartial.cj:295`、`298` 正在使用它。这条路径下：①同一实例被连续两次当作键，`refEq` 让内容不同的参数判等（ORM-1 复活）；②`SqlCacheKey.h` 在构造时固化（`SqlExecutor.cj:27-32`），而 `SqlArgs.add` 会把 `SqlArgs.h` 置 0 重算，于是**已入表**的键 `hashCode()` 漂移、`HashMap` 里再也找不到自己（条目悬挂，直到 `cache.clear()`）。`page()` 路径因两条 SQL 文本不同未触发①，但②在每次 `page()` 都会留下悬挂条目
- **建议**：`SqlArgs` 改为「写入期可变、入键前冻结」：`SqlCacheKey` 构造时把参数压成不可变快照（`(index, TypeInfo, value)` 的紧凑数组或参数哈希 + 长度），不要持有 `SqlArgs` 实例；`==` 去掉 `refEq` 短路，或保证只有冻结实例能进缓存

### [一般][存量] 绑定参数原文（含凭据与整块 BLOB）被拼进 debug 日志与异常消息

- **位置**：`f_orm/src/wrap/SqlArg.cj:60-62`（`toString<T>(value)` 输出 `${value}`）、`f_orm/src/wrap/SqlArg.cj:513-515`（`ByteArraySqlArg.toString` 输出整个字节数组）、`f_orm/src/wrap/SqlArgs.cj:105-107`；消费方 `f_orm/src/base/SqlExecutor.cj:432-442`（`logMsg`）、`f_orm/src/base/SqlExecutor.cj:36-38`（`SqlCacheKey.toString`）、`f_orm/src/base/SqlExecutor.cj:909`（把 `key` 插进 `ORMException` 消息）
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §10（敏感数据进日志）+ §5（按不可信长度做字符串化）+ `fountain-baseline.md` §6（日志中不得出现凭据、完整报文）
- **证据**：静态确定（构造路径）；实际暴露面为待确认 —— 需确认生产是否开 DEBUG
- **描述**：每次执行 SQL 都会 `logger.debug(logMsg(...))`（`SqlExecutor.cj:936`），闭包插值 `${args}` 逐参数调 `SqlArg.toString`，`String`/`Decimal`/`DateTime`/`Array<Byte>` 全部按原文输出。后果两条：①口令、令牌、身份证等以参数形式出现的敏感值进入日志文件；②BLOB 参数被整体格式化成字符串（`Array<Byte>.toString` 形如 `[1, 2, 3]`，见 std 文档 `core_package_structs.md:2760` 的输出样例），一个 10 MB 的 BLOB 在日志字符串里约放大到 40 MB 字符量级，且与 `SqlCacheKey.toString` 的异常消息共用同一路径
- **建议**：把「日志用」与「诊断用」的 `toString` 分开：日志侧只输出 `index + 类型 + 长度/摘要`（`InputStreamSqlArg` 已经是这种写法，`SqlArg.cj:447-449`，可作为范式）；确需原文时按 `orm_logArgs` 之类开关显式开启，并对 `Array<Byte>` 走长度 + 前缀哈希

### [轻微][存量] `SqlArg` 各子类 `==` 里 14 处跨类型比较分支永不可达

- **位置**：`f_orm/src/wrap/SqlArg.cj:283-285`（`Float16SqlArg`）、`309`、`311-312`（`Float32SqlArg`）、`333-334`、`336`（`Float64SqlArg`）、`357-359`（`DecimalSqlArg`）、`403`（`RuneSqlArg`）、`424`（`StringSqlArg`）；根因 `f_orm/src/wrap/SqlArg.cj:70-73`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §1（恒假分支）+ §2（重复逻辑导致的行为漂移）
- **证据**：静态确定 —— `equals(other)` 要求 `ClassTypeInfo.of(this) == ClassTypeInfo.of(other)`，`Float16SqlArg` 与 `Float32SqlArg` 的运行时类不同，`equals` 必为 `false`，`&&` 之后的跨类型 `case` 永不执行
- **描述**：代码想表达「数值型参数按数值相等、`Rune` 与 `String` 按字符相等」，实际只实现了「同类同值」。这 14 个分支既误导读者（以为跨类型相等成立），也让「`Float16(1.5)` 与 `Float32(1.5)` 是否同一参数」的答案依赖不可达代码。当前唯一消费者是缓存键与测试，所以后果仅限语义含糊
- **建议**：二选一 —— 要么删掉跨类型分支、把「严格同类型相等」写进注释与 README；要么把 `equals` 改成「先比 `index`，再按数值域比较」，并让各子类 `hashCode` 统一到数值域（注意 `Float16→Float32` 的绑定约定会让「相等但绑定类型不同」自相矛盾）

### [轻微][存量] 三张并行的「参数类型分派表」重复且已漂移：`SqlArg.new` / `SqlArgs.add` 20 个重载 / `SqlExecutor.add<T>` 38 个分支

- **位置**：`f_orm/src/wrap/SqlArg.cj:34-58`（19 个 `case`）、`f_orm/src/wrap/SqlArgs.cj:38-100`（20 个 `add` 重载，每个都是 `add(XxxSqlArg(args.size, arg))`）、`f_orm/src/base/SqlExecutor.cj:610-654`（38 个 `case`）
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §2（只改类型名 / 字面量表复制）+ §14.1（接线缺失导致的漂移）
- **证据**：静态确定 —— 新增一种参数类型要同时改三处；`SqlArg.new` 对未知类型 `throw SqlArgException`（`SqlArg.cj:56`），而 `SqlExecutor.add<T>` 的兜底是 `case x => add(x.toString())`（`SqlExecutor.cj:652`）**静默转字符串**。同一概念（「这个值能不能当参数」）两条路径结论相反：`SqlArg.new(0, someCustomObj)` 抛异常，`executor.add(someCustomObj)` 存成字符串
- **描述**：`SqlArg.new` 仓内零引用（见下一条），等于一张无人维护的表；`SqlArgs.add` 的 20 个重载纯机械重复（`SqlArg.cj` 20 个子类也几乎逐行相同，仅类型名不同，其中 `Float16→Float32` 加宽、`BigInt→String` 转换、`InputStream` 忽略值、`Array<Byte>` 走字符串哈希是四处真实差异）。这类「改一处漏一处」的结构正是 `Float16` 静默丢参（ORM-N2）能存活的原因
- **建议**：把「类型 → SqlArg」收敛为一处（例如以 `SqlArg.new` 为唯一工厂，`SqlArgs.add<T>` 只做 `add(SqlArg.new<T>(args.size, arg))`，`SqlExecutor.add<T>` 只做可空拆包）；未知类型的处理口径统一（建议统一抛 `SqlArgException`，若要保留 `toString` 兜底必须写进 README）。合并前把四处差异显式列出，避免把 `Float16` 加宽等约定改掉

### [轻微][存量] 死代码：`ByteSqlArg` 类型别名、`SqlArgs` 的 protected 主构造、`SqlArgs.add(all!)` 整条链

- **位置**：`f_orm/src/wrap/SqlArg.cj:139`；`f_orm/src/wrap/SqlArgs.cj:19`；`f_orm/src/wrap/SqlArgs.cj:101-104`（唯一调用者 `f_orm/src/base/SqlExecutor.cj:867-869`）
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §1（`internal`/`protected` 无引用；`protected` 只有「`public open` / `public abstract` 非 `sealed` 类的成员」才豁免）
- **证据**：静态确定 —— 全仓搜 `ByteSqlArg` 只有定义处 1 处命中；搜 `SqlArgs` 无任何子类，`SqlArgs` 又是 `public class`（非 `open`），其 `protected` 构造在本模块外不可继承、模块内无 `super(...)` 调用；搜 `add(all:` 在 `f_orm` 内只有 `SqlArgs.cj:102` 与 `SqlExecutor.cj:868`，而 `SqlExecutor.add(all!: SqlExecutor)` 自身零调用者（`exe.add(otherExe)` 会落到 `add(arg: Any)` 并抛 `SqlException`），整条链不可达
- **描述**：`ByteSqlArg` 是 `Byte`→`UInt8` 时代的兼容残留；`SqlArgs(args)` 主构造只剩「能被继承」这一个用途，而类不可继承。附带一个潜在缺陷：`add(all!: SqlArgs)` 直接把对方列表并入，**保留对方的 `index`**，若目标列表非空会出现重复 `index`（后者覆盖前者的绑定位置）—— 该缺陷随死链一起存在，复活前必须先修索引
- **建议**：删除三处；`add(all!)` 若确需保留，重排索引（`for (a in all.args) add(...)` 而不是 `args.add(all:)`）

### [轻微][存量] `imports.cj` 的 `std.ast.*` 在本包内零使用

- **位置**：`f_orm/src/wrap/imports.cj:18`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 在 `f_orm/src/wrap` 全包搜 `ast` 只有这一行；搜 `Token` / `Decl` / `Expr` / `Position` / `quote(` / `MacroContext` 均 0 命中。Cangjie 的 `import` 默认 `internal`（包内可见，见 `docs/dev-guide/source_en/class_and_interface/class.md:370-375` 对可见性层级的说明），所以这条 import 对整个 `f_orm.wrap` 包生效而非仅本文件
- **描述**：模块复制骨架时留下的无用依赖；`fountain::f_data.*` 与 `fountain::f_regex.*` 同样没有直接符号引用，但二者可能通过扩展成员（`Regex` 扩展、`@Data` 宏）生效，**未确认前不算死代码**
- **建议**：删除 `std.ast.*`；`f_data` / `f_regex` 用编译器 unused-import 诊断或逐个摘除试验确认后再删

### [轻微][存量] `TransactionWrap.setIsoLevel` / `setAccessMode` / `setDeferrableMode` 与同名 mut prop 完全重复，仓内零引用

- **位置**：`f_orm/src/wrap/TransactionWrap.cj:32-35`、`44-47`、`56-59`；对应 prop 在 `36-43`、`48-55`、`60-67`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §2（同一写操作的两种入口）+ §1 信息项
- **证据**：静态确定 —— 两套实现都只做 `transaction.xxx = value`，返回 `this` 与返回 `Unit` 是唯一差异；全仓搜 `setIsoLevel|setAccessMode|setDeferrableMode` 只有定义处命中，`SqlExecutor.createTransaction` 用的是 prop 赋值（`SqlExecutor.cj:274`、`277`、`280`）。`TransactionWrap` 是顶层 `public` 类，成员对外可达，**按硬原则一不算死代码**，只作 API 面重复
- **建议**：保留 prop（它与 `Transaction` 接口语义一致），把三个 `setXxx` 标注 `@Deprecated` 或直接删除；若要保留链式写法，至少让 `setXxx` 内部调用 prop setter，避免将来只改一处

### [轻微][存量] `StatementWrap` 让 `Statement` 接口的参数版 `update(params)` / `query(params)` 恒抛异常

- **位置**：`f_orm/src/wrap/StatementWrap.cj:38-43`
- **来源**：存量（`git blame`：`4be871f2f`，2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）+ §3（接口方法被实现成不可用）
- **证据**：待确认 —— 仓内没有任何代码通过 `Statement` 接口调用这两个方法（`f_orm` 内搜 `update(params)` / `query(params)` 只命中各驱动的实现与测试桩），所以当前不会崩；但 `ConnectionWrap.prepareStatement` 返回的就是 `StatementWrap`（`ConnectionWrap.cj:46`），任何按 `std.database.sql.Statement` 通用写法使用该语句的代码都会拿到 `ORMException`
- **描述**：README 第 2192 行已声明这是有意为之（「参数版直接抛 `ORMException('current access is deprecated')`」），因此不是「忘写实现」；问题是异常被抛在**具备该能力**的类型上，破坏了 `Statement` 的可替换性，且异常文案是英文短语而非可判定的错误码
- **建议**：把「不支持参数版」写进 `StatementWrap` 的类注释并改用专用异常类型（如 `UnsupportedOperationException` 语义的 `ORMException` 子类），或在包装层直接不实现 `Statement`、改用更窄的自有接口

### [轻微][存量] 两个测试的断言与夹具问题：`contains` 过宽导致 `Int8`/`UInt8` 不可区分；配置还原用 `set` 而非 `remove`

- **位置**：`f_orm/src/wrap/SqlArgBinding_test.cj:95-101`（`contains(expected)`），受影响的用例 `119-127`；`f_orm/src/wrap/QueryResultWrap_test.cj:168-189`（`Config.set` 还原）
- **来源**：存量（`git blame`：测试文件 `2026` 年版权头，属快照既有内容）
- **判据**：review-checklist §11（测试断言不成立 = 覆盖缺口）+ §1（机械检查）
- **证据**：静态确定 —— 记录串形如 `set<core.UInt8>(0)`，`'set<core.UInt8>(0)'.contains('Int8')` 为 `true`，所以 `check('Int8','Int8',…)` 在误绑 `UInt8` 时同样通过（`UInt16`/`Int16`、`UInt32`/`Int32`、`UInt64`/`Int64` 同理）；`Config.set` 是进程内全局表（`f_config/src/Config.cj:107-129`），`Config.remove` 才是「本来没有这个键」的正确还原（`Config.cj:130-139` 的注释明确写了这一点），用例却把键改成 `'true'` 留下残键
- **描述**：`expectOnce` 是本文件唯一的类型断言，它区分不了有/无符号，恰好放过了「窄类型绑错」这类历史缺陷（`ORM-N2`）；另外 `90` 行注释明说 `InputStream` 与 `Array<Byte>` **未覆盖**，而 `InputStreamSqlArg` 的等值缺陷（本报告第 1 条）正落在未覆盖区
- **建议**：`expectOnce` 改成精确比较完整类型名（`set<core.Int8>(0)` 全等），或直接解析出 `<>` 内的类型串做相等比较；配置还原改 `Config.remove(key)`；补 `InputStream` / `Array<Byte>` 的绑定与缓存键用例

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分只有 `README.md`，不含可执行路径，因此不产出性能 / 内存优化方案（§7 / §8 / §9 的候选留给第 2–8 部分的 `.cj` 审查）。

<!-- 第 2 部分 -->

**本部分 0 条。** 理由：本部分没有任何生产侧可优化代码（`ORM.cj` 只有一行 `public import`；`EmbedSensitive.cj` 是编译期宏，循环上界 = 驱动数，编译期开销可忽略；其余两个文件是测试）。唯一有数据的候选——`SqlPartial.UPDATE` 的 `HashMap<String,Any>` 中转——已由同模块 spec 记录并**决策不做**（`f_orm/doc/spec/test-f-orm-update-column-keys/design.md:9-15`：mock 下每次 UPDATE 16,763 B、中间映射 1,542 B ≈ 9%；local 化被 `Any` 的 local 限定阻断；替代方案会改掉「重复键 last-wins」与「缺键抛 `values[idColumn]` 异常」语义），故不重复提议，只列入下方假设等待真实链路数据。

<!-- 第 3 部分 -->

### [堆内存] 让 `partials` 与 `args` 跟随语句生命周期归零

- **现状**：每个线程一个 `SqlExecutor`，其 `partials`（`StringGenerator`）与 `args`（`SqlArgs`）在事务内跨语句存活。`clearSql()`（`SqlExecutor.cj:97-106`）换掉 `args` 实例但**不触碰** `partials`；`close()`（`153-174`）在事务中直接返回。字符串拼接路径（`MeetCondition.frag` / `ChooseCondition.done` / `ExtendString.append`）持续追加，量级 ≈ 每条语句的片段字节数 × 事务内语句数（未测）。
- **方案**：`clearSql()` 增加 `partials.clear()`；`Partials` 增加只读 `size` 供观测；`close()` 的早退分支也清一次。
- **预期**：事务内常驻片段文本从「N × 片段长度」降到「当前语句一份」；对长事务批量任务（1k+ 语句）应能把该项常驻降到常数级（**无实测**）。
- **代价**：若确有调用方依赖「跨语句累积片段」的隐式行为（当前实现没有这样的显式入口），会改变语义；需要在 `TableClause` 之外补一个用例确认无回归。
- **验证**：同一事务内循环 1k / 10k 次 `meet(...).done()`，采 `getAllocatedHeapSize()` 与 RSS，确认曲线变平；同时对比 SQL 文本逐字节一致（复用 `ArgSqlText_test` 的口径）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 表达式树 `toString()` 单次求值 + 消除 `ParenExpr` 的重复遍历

- **现状**：`ParenExpr.toString()`（`LogicalExpr.cj:252-258`）对内层树求值两次；`RelationExpr.toString()`（`227-249`）对每个子表达式求值一次并 `emptyLogicalExpr` 再扫一遍文本；`CmpExpr.toString()` 每次都新建 `ExprSqlExec()`（`129`/`142`）。输入规模是一次 WHERE 的条件数 n（典型个位数到几十）。
- **方案**：#1 修完后顺带把「一次遍历产出 sql + args」落地（表达式节点缓存本次求值结果，或在 `toString` 外层包一个求值上下文），`RelationExpr` 的空判断改为「求值结果为空则跳过」而不是对字符串再做一次扫描。
- **预期**：条件数为 n 时，字符串化次数从「约 2n」降到「n」；`ExprSqlExec` 分配次数同比例下降（**无实测**，占比未知，可能低于 5% 噪声阈值）。
- **代价**：需要给表达式节点加「已求值」状态或引入显式求值器，改动面覆盖 `LogicalExpr.cj` 全部 7 个类；缓存状态还可能引入新的可变性（必须与 #9 的「求值/绑定分离」一起做）。
- **验证**：`cjpm bench -O2`，同一 DAO 方法（10 个条件）执行 10 万次，对比 `cjprof record` 中 `LogicalExpr.toString` 系函数的自耗时占比与总耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 4 部分 -->

> 不是缺陷，是"还能更好"。每条都必须可执行、可验证。

### [堆内存] 给结果缓存加容量上限与"语句级失效"

- **现状**：`SqlExecutor.cache`（`SqlExecutor.cj:54-56`）在事务内跨语句存活，键是 `(sql, args)`，值是完整结果集；没有容量、TTL、淘汰（见 #8）。对象数 ≈ Σ(每次查询的行数 × 每行对象数)，生命周期 = 整个事务。
- **方案**：`cache` 增加 `maxEntries`（默认 128）与 `maxRows`（按 `ArrayList.size` 累计），超限整体清空；`clearSql()` 时把"上一语句的键"标记为可淘汰（LRU 保留最近 K 条）。
- **预期**：长事务内的常驻结果集从"全部查询之和"降到"最近 K 条"；峰值应显著下降（**无实测**）。
- **代价**：命中率下降（重复查询跨语句时不再命中）；需要新增两个配置项并进 README 的配置表。
- **验证**：mockdb 事务内跑 1k / 10k 次不同 id 的 `first<T>`，对比 `getAllocatedHeapSize()` 峰值与 RSS，并对比总耗时确认没有明显回退（`-O2`，同机，中位数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 延迟建连 + 空闲 executor 回收

- **现状**：每线程每驱动一个 `SqlExecutor`，构造即取连接（#22）；请求只取 DAO 不执行 SQL 时连接闲置到下一次 `getInstance` 或线程退出。
- **方案**：`_connection_` 初值设为 `NoneConnection.instance`，`connection` 属性首次访问时才 `getConnection`；`getInstance` 里按 `lastUsedAt` 回收超过 N 秒未使用的 executor（`close()` 即可）。
- **预期**：空闲连接数从"线程数 × 驱动数"降到"活跃请求数"（**无实测**）。
- **代价**：首条语句多一次建连/取池开销；需要给 `lastUsedAt` 打点（`DateTime.now()` 每次执行已有 `start`，可复用）。
- **验证**：线程池 200 线程、池大小 20、QPS 由 0 阶跃到峰值，采 `f_dbpool` 的活跃/空闲连接计数与 `pg_stat_activity` 连接数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 三处 40+ 分支的 `Any` 分派合并为一张类型表

- **现状**：`RootDAO.arg(Any)`（`258-306`）、`RootDAO.arg<I,T>`（`333-376`）、`SqlExecutor.add<T>`（`610-653`）各有一份"按运行时类型逐条 `case`"的线性分派，合计约 120 个 `case` 行；绑定热路径上每个参数都要走一遍（含 `?T` 组，最坏命中位置 40+）。三份还必须手工保持同序（注释 `327-332`、`607-609` 明确要求"与另一处保持同步"）。
- **方案**：抽出 `private func bind(exe: SqlExecutor, v: Any): Unit` 单点分派，三处改为调用它；若要进一步降开销，用 `ConcurrentHashMap<TypeInfo, (SqlExecutor, Any) -> Unit>` 做一次查表（类型数有界、可缓存），避免每参数多次 `is` 检查。
- **预期**：单参数分派失败检查次数从"位次"降到 O(1)；对 `IN (10k)` 这类批量绑定应能看到端到端改善（**无实测**，按 `SqlExecutorArgBranches_test` 的注释，历史重排曾把 Int64 的检查次数从 8 降到 1）。
- **代价**：一次哈希查表（可能比 1~2 次 `is` 检查更贵）+ 一张需要维护的类型表；语义必须保持"不支持类型抛 `SqlArgException`"。
- **验证**：`cjpm bench -O2`，对 `IN` 100 / 1k / 10k 元素 + 单参数 `first` 各跑 10 轮取中位数；同时用 `SqlExecutorArgBranches_test` 做等价性回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `waitConnecting` 退让

- **现状**：忙等（#21），循环体只有状态读与时钟读，无退让。
- **方案**：`sleep(1ms)` 起步、逐步退避到 10ms；超时判断用预先算好的 deadline，避免每轮 `MonoTime.now()`。
- **预期**：Connecting 期间 CPU 占用从"一核"降到"每秒千次状态读"；对连接建立慢的驱动（建连 50ms+）效果明显（**无实测**）。
- **代价**：连接就绪的发现延迟最多增加一个 sleep 周期（1~10ms）；建连本身远大于这个量级。
- **验证**：mock 一个 `Connecting` 持续 200ms 的连接，采 `cjprof` 的 CPU 占用与该函数的 self time，对比改前改后；同时断言端到端建连耗时增量 < 10ms。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

> 本部分没有 bench / profile 数据；以下两条都只有静态依据，收益必须实测后才能进 `tasks.md`。

### [堆内存] 去掉 `UPDATE` 数组/Map 重载的中间 `HashMap<String, Any>` 拷贝

- **现状**：`UPDATE<T>(values: Array<(Column, Any)>)`、`(Map<Column, Any>)` 及其带 `id` 的版本，先 new 一个 `HashMap<String, Any>`，把每个 `(Column, v)` 的 `name` 重新插入（`SqlPartial.cj:123-143`、`181-187`），随后 `Map` 版本又对它迭代一遍。列数为 N 时每次调用多 N 次装箱 + N 次哈希插入 + 一个容量 ≥N 的表，生命周期仅到本次 UPDATE 结束。
- **方案**：抽出 `private func updateByKeys<T>(lookup: (String) -> Option<Any>, id: …)`，让数组/`Map<Column,Any>` 版本直接提供查找闭包（数组版本可先只做"字段名/列名命中"的一次线性扫描，N 通常 < 20），不再构造中间 map。
- **预期**：每次 UPDATE 少 N 个临时对象与一次哈希表分配；对高频小批量更新（每秒数千次）可减少 young 区分配量。收益上限取决于 UPDATE 调用频次，未测量。
- **代价**：多一层闭包间接调用（`perf §11.3` 提示热路径去抽象，N 大时可能更慢）；需要保序与"后写覆盖先写"的语义（当前 map 版本对同名列是后者覆盖前者）。
- **验证**：`cjpm bench -O2` 跑固定 POJO（15 列）× 10 万次 UPDATE（mockdb 驱动），对照 `getAllocatedHeapSize()` 增量与中位耗时；再在真实 MySQL 上跑 1 万次确认无回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `TableMeta.new` 的 `iterator().map().fold()` 两段式构建

- **现状**：列与索引各自走 `iterator().map{…}.fold(ArrayList(), …).unsafeData()`（`TableMeta.cj:38-60`），每个 PO 类型在静态初始化时构造 2 个迭代器链 + 若干闭包，并对每个字段做 1–2 次反射（`getInstanceProperty` → 失败 → `getInstanceVariable`）。PO 数量 M、平均字段 K 时启动期成本 ≈ M×K 次反射 + 2M 条闭包链。
- **方案**：改成一次 `ArrayList` + `for` 追加（`let list = ArrayList<ColumnMeta>(); for (m in …) { if (let Some(c) <- …) { list.add(c) } }`），省掉 `Map/Filter/Fold` 三层闭包与两处 `unsafeData()`；反射部分可先 `typeInfo.getInstanceVariable` 一次（`@DataAssist[fields]` 生成的 PO 多为 `var`），失败再回退 property，减少一半正常路径开销。
- **预期**：启动期反射次数与临时对象数近似减半；对 M 大（数百个 PO）的应用可缩短冷启动。单次成本很低，收益只在启动时可见。
- **代价**：改写顺序敏感（`oldColumnName`/`comment` 的搬运不能漏）；需要保持"字段顺序 = mapper 顺序"。
- **验证**：用 50/200/500 个 PO 的样例模块测冷启动（进程启动到 `ORM.initialize()` 返回）与 `cjprof record` 的 `TableMeta.new` 自耗时；`-O2`、同机器、3 轮中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 6 部分 -->

### [堆内存] migro DDL 生成改为「按需流式」，去掉 `ArrayList` 全量暂存

- **现状**：`generateAlterSql`（`MysqlSchema.cj:123`、`PostgresSchema.cj:156`）与 `generateIndexSql`（`MysqlSchema.cj:145`、`PostgresSchema.cj:207`）把所有语句先攒进 `ArrayList<String>` 再 `iterator()`；`PostgresSchema.generateCreateSql:131-139` 额外把 `columns` 迭代器物化进 `ArrayList` 后遍历两次。规模 = 单表列数/索引数（通常 < 100），单条语句 100–300 字节
- **方案**：改用 `Sequence`/生成器式 `Iterator` 组合（`flatMap` + `intersperse`），或保留 `ArrayList` 但用 `ArrayList(capacity)` 预分配并按 `columns.size` 估容量；`generateCreateSql` 的 `list` 换成 `toArray()` 后复用同一数组
- **预期**：单表单次迁移少分配 O(列数) 个短命字符串容器；对「表多、每表列多」的库降低 GC 峰值
- **代价**：生成器组合可读性略降；`ArrayList` 版本便于一次看到完整 DDL，改成流式后打印顺序依赖消费方
- **验证**：`-O2` 下对 200 表 × 50 列的元数据跑 `dbmigro -m dry`，对照 `getAllocatedHeapSize()` 与 RSS 峰值（`mem §1.2`），各 10 轮取中位数
- **证据状态**：`无基线（待验证）`，不进 `tasks.md`

### [CPU] `Columns` 生成类的 `Column` 属性每次访问都新建对象

- **现状**：`QueryMappersGenerator.cj:464-470` 生成的 `public prop xxx: Column { get(){ Column("xxx") } }`，每次读取都构造一个 `Column`；`toString`（`:471`）与 `iterator`（`:472`）在拼 SQL 别名时按属性逐个访问，单次查询会为每列构造 1 个 `Column`
- **方案**：改为 `static let` 常量（`private static let c_xxx = Column("xxx")`）或在 `Columns` 实例里缓存
- **预期**：每列每次拼 SQL 少一次小对象分配；查询构建路径上约「列数」量级的分配减少
- **代价**：生成代码多几个静态字段；`Column` 若带可变状态则不能共享（需先确认 `Column` 无状态）
- **验证**：`cjpm bench -O2` 跑「同一 PO 连续构建 10 万次查询」对照；先用 `cjprof record` 看 `Column` 构造是否进入自耗时前 20
- **证据状态**：`无基线（待验证）`，不进 `tasks.md`

<!-- 第 7 部分 -->

### [堆内存] #O1 `getOrNull` 每个单元格都新构造一个 reader 闭包

- **现状**：`QueryResultWrap.cj:101` 对每个未读单元格调 `makeReader(result, columns[i].typeName)(i + indexStartsWith)`；`makeReader`（`59-80`）返回 `(Int64) -> Any`，捕获 `result` 的闭包每次都是新对象。一次 `n 行 × m 列` 的结果集最多 `n×m` 个闭包，存活到该单元格读完（其余部分随 `list` 一起被 `next()` 的 `clear()` 丢弃）。
- **方案**：给 `QueryResultWrap` 增加 `private var readers: Array<?(Int64) -> Any>`（构造期按列懒填：`readers[i]` 为 `None` 时才 `makeReader`），一个结果集内每列只构造一次。
- **预期**：闭包对象数从 `n×m` 降到 `m`（列数），即同一查询下降 `n` 倍；`n=10^4` 时约 10^4 倍对象数差。
- **代价**：多一个 `Array<?(Int64)->Any>` 成员（`m×8` 字节）；`makeReader` 仍需 static。
- **验证**：`cjpm bench -O2` 同输入（10k 行 × 20 列）对照 `getAllocatedHeapSize()` 与 `cjprof heap`；RSS 稳态对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] #O2 `getOrNull` 用 `ArrayList<Any>` 缓存整行（含装箱与"前置列连带读取"）

- **现状**：`QueryResultWrap.cj:26`、`99-105`：读到第 `i` 列时会把 `list.size..i` 的所有列都读出来塞进 `ArrayList<Any>`（每格一次 `Any` 装箱），`next()` 时 `clear()`。若只映射最后一列，前面所有列（包括 BLOB/CLOB 的 `InputStream`）都会被驱动取出并留在 `list` 里直到下一行——流不会被关闭。
- **方案**：只缓存"被请求过的列"（`HashMap<Int64, Any>` 或 `Array<?Any>` 按需填），不做前缀填充；`hadStream` 保持现有置位点。
- **预期**：每行装箱数从 `m` 降到"实际读取列数"；避免为未读列创建流对象（BLOB 列在前时尤其明显）。
- **代价**：`Array<?Any>` 需要判空；若某驱动的 `getOrNull` 依赖"按列顺序读取"（需核对三个驱动的实现），则不能跳过前置列——这是方案的前提，必须先确认。
- **验证**：`getAllocatedHeapSize()` 对照 + 句柄数（`/proc/<pid>/fd`）在"只读最后一列、前面 3 个 BLOB 列"场景下是否不增长。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] #O3 `ORMConfig` 每次 getter 调用都全量复制一遍配置表

- **现状**：`ORMConfig.cj:96-105` 的 `getAllConfigs` 每次 `Config.getAll('orm')` + 逐键 `replace` 构造新 `HashMap`；`getConf`/`get<T>` 每个键都走一次。`NamedDatasource.newDatasource`（`NamedDatasource.cj:89-103`）一次性调用 12 个池参数 getter，`useStdPool` 分支另有 6 个 `getStdPool*`（`67-84`），外加 `getNoPool` / `getUseStdPool`；`SqlExecutor` 每次构造还要 `getUseCache`。
- **方案**：`NamedDatasource`/`SqlExecutor` 侧一次 `getAllConfigs` 拿到快照后本地取键；或给 `ORMConfig` 加"按 driverName 缓存的只读快照"，在 `Config.refresher` 回调里失效重建（与 `static init` 的刷新机制天然对齐）。
- **预期**：数据源初始化时的配置表复制次数从 ~14 降到 1；Executor 构造从 1 次全量复制降到 0（命中快照）。绝对耗时只在启动/首请求，量级小。
- **代价**：多一份缓存（配置量级，KB 级）；需要与 `Config.set` 的刷新路径严格对齐，否则读到陈旧值。
- **验证**：启动期分段计时（`MonoTime`）+ 分配计数；`cjpm bench -O2` 对 `NamedDatasource(driver)` 构造 1000 次对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] #O4 `getOrNull` 的 18×18 类型矩阵：每格两次类型测试

- **现状**：`QueryResultWrap.cj:134-979` 对 `list[index]` 先做一层 ~18 分支类型匹配，每个分支内再对 `None<T>` 做一层 ~15 分支匹配来判定目标类型；每读一格至少一次多层 `match`（`TypeInfo` 比较）。`convertFromString`（`108-133`）与 `toMap`（`997-1034`）是同一套映射的另外两份（见 #7、#11）。
- **方案**：按"目标类型 `TypeInfo.of<T>()` → 一次查表得到转换函数"重构；数值之间统一走 `toInt64()/toFloat64()/toBigInt()` 等标准转换，不再枚举 `?Int8→?Int16` 这类组合。
- **预期**：每格的分支数从 O(源类型数) 降到 O(1)（一次查表）；代码行数从 ~700 行降到 ~80 行，顺带消除 #7 的漂移。收益需 profile 证明（结果映射是每单元格都走的路径，但占比未知）。
- **代价**：行为等价性要逐类型用例锁定（当前的宽窄转换、`None` 传播、异常文案都不能变）；`toMap` 的 `Rune`/`Nullable` 语义要保留。
- **验证**：`cjprof record` 跑"10k 行 × 20 列"查询，看 `getOrNull` 自耗时占比；改造后同输入对照 + `QueryResultWrap_test` 全绿。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 8 部分 -->

### [堆内存] `SqlCacheKey` 持有整个 `SqlArgs`（含参数值与流引用），缓存条目钉住参数对象

- **现状**：每条缓存条目 = `SqlCacheKey(sql, args)` + 结果值。`args` 是执行期的 `SqlArgs` 实例，内部 `ArrayList<SqlArg>` 每个元素持有一个装箱值：`String` 参数整串、`Array<Byte>` 整块、`InputStream` 是**调用方的流对象**（`SqlArg.cj:441`）。生命周期：至少到下一次 `close()` 的 `cache.clear()`（`SqlExecutor.cj:157`），事务内跨语句一直存活
- **方案**：`SqlCacheKey` 只存 `sql` + 参数个数 + 参数哈希（现有 `h` 已够用），去掉 `args` 强引用；`==` 退化为「`sql` 相等 + `h` 相等」（哈希碰撞时按保守方式视为不同，宁可不命中）
- **预期**：每条缓存条目少持有 N 个 `SqlArg` 及其参数值（BLOB 场景单条即 N 字节级 → 命中期间常驻），事务内长查询序列的峰值可降；具体幅度未知
- **代价**：碰撞时退化为不命中（正确性不受损，只是缓存命中率略降）；`SqlCacheKey.toString` 失去参数明细，异常诊断信息变弱（可用参数个数 + 哈希替代）
- **验证**：同输入事务（20 条 SELECT，含 1 个 5 MB BLOB 参数）多轮跑，对比 `getAllocatedHeapSize()` / RSS 与 `cache.size`；`-O2`
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU / 堆内存] `ByteArraySqlArg.hashCode` 走 `value.toString()` 全量字符串化

- **现状**：`f_orm/src/wrap/SqlArg.cj:516-518` 用 `hashCode<String>(value.toString())` 求哈希；`Array<Byte>.toString` 会生成 `[1, 2, 3]` 形态字符串（std 文档 `core_package_structs.md:2760`），一个 n 字节的 BLOB 约产生 4n 个字符 + 一次完整数组遍历，每次 SELECT 建缓存键都会走一遍（`SqlExecutor.cj:905-906`）
- **方案**：改为按块喂 `HashBuilder`（`for (b in value) hasher.append(b)` 或分块 `append(Array<Byte>)`），不再构造字符串；`toString` 只输出长度 + 前 16 字节摘要
- **预期**：BLOB 参数建键的分配量从 O(4n) 字符降到 O(1) 额外对象；单次哈希耗时从「格式化 + 哈希」降为「一遍哈希」
- **代价**：哈希分布变化 → 已存在的缓存条目失效一次（进程内缓存，无持久化影响）
- **验证**：固定 1 MB / 10 MB 两个尺寸，`cjpm bench -O2` 对比 `SqlCacheKey` 构造耗时与分配量；`cjprof record` 看 `HashMap` 建键路径占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次绑定都新建 `SqlArg` 对象（20 类 × 每参数 1 个）

- **现状**：`SqlArgs.add` 的每个重载都 `new XxxSqlArg(...)`（`SqlArgs.cj:38-100`）；一条 20 参数的 INSERT 每次执行分配 20 个 `SqlArg` + 20 个装箱值，`args` 换实例后全部成为垃圾（`SqlExecutor.cj:104`）
- **方案**：`SqlArgs` 内部改用「类型标签 + 值」的紧凑数组（`Array<Int64>` 索引 + `Array<Any>` 值 + 复用缓冲），`SqlArg` 降级为绑定视图；或在 executor 生命周期内复用 `SqlArgs` 的存储槽（配合本报告第 2 条的冻结语义）
- **预期**：每参数分配从 2 个对象降到 0～1 个；GC 压力与 `SqlArg` 构造开销下降
- **代价**：`SqlArg` 的 `protected` 扩展点与各子类语义要重新设计（对外 `SqlArg` 是 public 抽象类，属契约变更）；`index`/`TypeInfo` 语义必须保持
- **验证**：`cjpm bench -O2` 跑 10 万次 20 参数 INSERT 的绑定阶段（不连库，用 `RecordingStatement` 桩），对比耗时中位数、分配量、GC 次数
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

> 本部分为文档审查，无性能测量数据可用，也没有"疑似热点"可提。下列一条是文档承诺可能带来的运行期开销线索，仅用于下一轮补数据，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README §8.1 的 DSL 编译缓存（`HeapCache(maxLife: 1 天, maxSize: 10000)`）在"动态拼接 DSL 文本"的调用方式下命中率可能很低，导致每次都重新 `cangjieLex` 解析 | `f_orm/src/base/SqlDSL.cj:45-47`、`README.md:829` | 缓存命中率、单次 `compile()` 耗时占比 | 在 `dslcache.getOrCompute` 前后加命中/未命中计数，跑 10 分钟稳态负载；`cjprof record` 看 `compile` 自耗时 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | UPDATE 的中间映射 1,542 B/次（9%）在真实 DB I/O 下可忽略；若真实链路占比明显更高，才值得动 `SqlPartial.UPDATE` 的结构 | `f_orm/src/base/SqlPartial.cj:123-142` | 真实驱动下单次 UPDATE 的分配总量与 `HashMap` 占比 | 接真实 pgsql/mysql 跑 1 万次三列 UPDATE，`getAllocatedHeapSize()` 前后差 + `cjprof heap` 看 `HashMap` 分配占比 |
| 2 | #1 的夹具泄漏在「新增一个只执行 SQL、不设夹具」的用例后确实会显形（当前无受害用例，属潜伏） | `f_orm/src/base/ArgBindCount_test.cj:41` | 追加临时用例后的实际行为 | 在 `ArgBindCount_test` 之后追加一个只跑 `select` 的临时用例（不设 `MOCKDB.execution`），断言结果集列数/行数是否被改成 1 列 1 行；再删掉临时用例 |
| 3 | #8 的计时断言在本仓 CI 上的翻红概率 | `f_orm/src/base/ArgAnyBinding_test.cj:103` | 失败率与 `anyNs` 分布 | CI 上重复 200 次，记录 `anyNs`/`typed` 的 P50/P99 与超阈值次数 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 字符串拼接路径的 `partials` 残留是长事务的内存增长主项之一 | `f_orm/src/base/MeetCondition.cj:47`、`ChooseCondition.cj:114`、`ExtendString.cj:30` | 事务内语句数、每条语句片段字节数、`StringGenerator` 实际占用 | 在 `Partials.append` 处加计数（次数 + 累计字节），跑一个 10k 语句的批量事务，对照 RSS 与 `getAllocatedHeapSize()` |
| 2 | `LogicalExpr` 系 `toString()` 的重复求值在条件多的查询里占可观 CPU | `f_orm/src/base/LogicalExpr.cj:252-258`、`227-249` | 自耗时占比、条件数分布 | `cjprof record` 跑 10 万次 10 条件查询，看 `LogicalExpr.toString` 系函数 self time 是否 >5% |
| 3 | `Condition.trim` 的自定义分支每次调用都编译一次正则，是低频热点的隐藏开销 | `f_orm/src/base/Condition.cj:79` | 自定义 prefix/suffix 的调用次数 | 全仓搜 `Condition.trim(prefix:` 的非常量实参调用点；有则加计数并计时，无则可忽略 |
| 4 | `SqlDialectMediator` 的懒填充在启动期被并发触发多次 | `f_orm/src/base/Dialect.cj:176-182` | 填充次数（是否 >1） | 在 `176` 分支内加计数，`fboot` 冷启动 100 次统计非 1 的比例 |

**范围外提示**（不计入本部分统计）：

1. `QueryMappersGenerator.cj:319-323` 生成 `GroupedQueryMapper<...>(name: $columnName, grouped: ..., groupedGetter: ...)`，而本部分的 `GroupedQueryMapper` 构造器只有 `grouped!` / `groupedGetter!` 两个形参（`GroupedQueryMapper.cj:21-26`）。一旦某个 `@QueryMappersGenerator` 类出现 `ArrayList<实体>`（非可空、无转换器）字段，宏展开即编译失败。仓内已用的 PO（`f_llm` / `fdemo` / `fdbm`）没有这种字段，所以当前未被触发；归第 4/5 部分（宏）确认。
2. `SqlDialect` 家族里 `OracleDialect` / `DB2Dialect` 未覆写 `lastInsertId`，采用基类返回 `''`（`Dialect.cj:22-24`），即这两种方言插入后拿不到自增 ID；`PostgresDialect` 的 `' returning ${id}'` 未对标识符加引号（`99-101`）。是否属已知限制需要 README 侧确认（不在本部分）。

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每条 SQL 都跑一次 `Regex.replaceAll` 做空白归一，短 SQL 高 QPS 下占可观 CPU | `f_orm/src/base/SqlExecutor.cj:76` | `blankRegex.replaceAll` 的 self time 占比 | `cjprof record` 跑 10 万次 `setSql`+`first`，看该函数与 `Regex` 相关帧占比是否 >5% |
| 2 | `Any` 入口的线性类型分派是参数绑定的主开销 | `f_orm/src/base/RootDAO.cj:258-306`、`SqlExecutor.cj:610-653` | 绑定阶段耗时占端到端比例 | 分段计时：`IN(10k)` 的 `arg` 总耗时 / 整条语句耗时；`cjprof` 看 `arg`/`add` 系 self time |
| 3 | 缓存键对 `SqlArgs` 求哈希时会把 BLOB 参数整体转字符串，形成等大内存峰值 | `f_orm/src/base/SqlExecutor.cj:27-29`、`wrap/SqlArgs.cj:109-119` | 单次 `hashCode` 的分配量与耗时（按 BLOB 大小） | 用 1MB / 10MB `Array<Byte>` 参数跑一次 `first`，采 `getAllocatedHeapSize()` 与耗时 |
| 4 | DSL 编译缓存命中率低（`dslcache` 10000 条 / 1 天）导致重复 `cangjieLex` | `f_orm/src/base/SqlDSL.cj:45-47` | 命中率 | 在 `compile()` 外挂计数（命中/未命中），跑真实业务 10 分钟 |
| 5 | `groupedList` 每行一次 `LinkedHashMap.get(id, false)` + 分组 `populate` 在 1:N 大结果集上是热点 | `f_orm/src/base/QueryMappers.cj:92-109` | 行数、分组基数、该循环占比 | 造 10 万行 / 1 万分组的 mock 结果集，`cjprof` 看 `groupedList` self time |
| 6 | 事务内结果缓存（#8）在批量任务里是峰值内存主项 | `f_orm/src/base/SqlExecutor.cj:54-56`、`915-917` | 事务内不同键数、结果集总量 | 1k/10k 次 `first<T>` 事务内循环，采 RSS 与 `getUsedHeapSize()` 曲线 |

**范围外提示**（不计入本部分统计）：

1. `DirtyTag` 的"全局 `beforeDirty` + 线程私有 `dirtyFields`"并发丢更新问题见第 3 部分 #3（`DirtyTag.cj:23-79` 与 `SqlExecutor.cj:172`），本部分不重复报，只确认 `SqlExecutor.close()` 是它的触发点之一。
2. `partials` 在字符串拼接路径上"只增不清"见第 3 部分 #10；本部分 `SqlExecutor.clearSql()`（`97-106`）确实不触碰 `partials`，与该结论一致。
3. `TableClause` 的 INSERT 列名列表（`TableClause.cj:441-448`）会把嵌套映射器的空 `columnName` 拼进列清单（`insert into t(a,,b)`），属第 3 部分文件；与本部分 #11 同源（嵌套映射器 `dataType: UnknownDataType(true,'','')`）。
4. README（第 8 部分范围）`f_orm/README.md:388-393` 把结果缓存描述为"读操作按 SQL + 参数缓存，写操作整体清空"，未说明"非事务路径每条语句都清空、只有事务内才命中"；与本部分 #3 / #8 同源。

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `TableMeta.new` 的反射与闭包链是冷启动可观开销 | `f_orm/src/base/TableMeta.cj:38-60` | 启动 profile、PO 数量与字段数 | 造 200 个 `@QueryMappersGenerator` PO，`cjprof record` 覆盖启动前 3s，看 `TableMeta.new` / `findAnnotation` 自耗时占比 |
| 2 | `appendPartial` 的 `Regex.replaceAll` 在长条件链上占比可观 | `f_orm/src/base/TableClause.cj:56` | 单次调用耗时、每语句调用次数 | 构造 100 段 `AND(...)` 的条件构建循环，`cjpm bench -O2` 对照"预编译常量"与"纯字符串首尾裁切"两版 |
| 3 | `UPDATE` 的中间 `HashMap` 拷贝在批量更新场景产生可见 GC 压力 | `f_orm/src/base/SqlPartial.cj:123-143` | 分配量、GC 次数、UPDATE QPS | mockdb 驱动跑 10 万次 15 列 UPDATE，采 `getAllocatedHeapSize()` 增量与 GC 次数，中位数 3 轮 |

<!-- 第 6 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Columns` 属性每次新建 `Column` 是查询构建路径的分配热点 | `f_orm/src/macros/QueryMappersGenerator.cj:464-470` | `Column` 构造在分配总量/自耗时中的占比 | `cjprof record` 跑 10 万次列表查询构建，看 `Column.<init>` 占比与 `cjprof heap` 分配量 |
| 2 | 宏展开期 `generateColumns` 的 token 逐条 `+=` 拼接是编译热点（大 PO 时明显） | `f_orm/src/macros/QueryMappersGenerator.cj:462-485` | 编译期耗时占 `cjc --compile-macro` 的比例 | 对一个 100 列 PO 前后对照 `cjpm build` 墙钟时间；用 `--debug-macro` 粗看展开体量 |
| 3 | `dbmigro` 全量物化 SQL（`allSqls`）在大库下抬高峰值 RSS | 调用侧 `f_orm/src/migro/SchemaFinderMediator.cj:76-78`（本部分范围外） | 表数 × 语句数的实际量级 | 构造 500 表元数据跑 `-m dry`，量 RSS 峰值与 `getAllocatedHeapSize()` |
| 4 | `PostgresSchema.findIndexes` 的 `groupBy` 在索引数很大的库上占迁移时间主要部分 | `f_orm/src/migro/PostgresSchema.cj:113-121` | 单表索引数与单表耗时占比 | 对 200 索引的表分段计时 `findIndexes` 与 `generateIndexSql` |

<!-- 第 7 部分 -->

> 没有性能测试数据支撑，只用于下一轮补数据。不计入模块统计，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `getOrNull` 的多层 `match` 是结果映射的主要 CPU 自耗时 | `f_orm/src/wrap/QueryResultWrap.cj:134-979` | 自耗时占比、调用次数 | `cjprof record` 跑 10k 行 × 20 列的 `iterator<T>()` 映射，1 万次迭代 |
| 2 | 每单元格一个 reader 闭包造成可观的分配量 | `f_orm/src/wrap/QueryResultWrap.cj:101` | 分配字节数 / GC 次数 | `cjprof heap` + `getAllocatedHeapSize()` 前后对照（同查询、同并发） |
| 3 | 迁移时逐语句建连/关闭带来明显的连接建立开销 | `f_orm/src/migro/SchemaFinderMediator.cj:103-113` | 建连次数与总耗时占比 | 100 条 DDL 的迁移，分段计时 + 驱动侧连接日志（对比"一次会话执行"） |
| 4 | `ORMConfig` 每次 getter 全量复制配置表拖慢启动 | `f_orm/src/wrap/ORMConfig.cj:96-105`（调用点 `NamedDatasource.cj:89-103`） | 构造 1 个数据源的配置读取耗时/分配 | `MonoTime` 分段计时 + 分配计数，构造 1000 次取中位数与离散度 |

<!-- 第 8 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SqlCacheKey` 构造（含 `SqlArgs.hashCode`）在含大参数事务里占端到端 5% 以上 | `f_orm/src/base/SqlExecutor.cj:905-906` | 自耗时占比 + 参数规模 | `cjprof record` 跑「事务内 20 条 SELECT，1 个 10 MB BLOB 参数」，看建键路径 self time |
| 2 | 结果缓存命中率低于 30%，当前 `refEq` + 实例替换策略抵消了大部分收益 | `f_orm/src/base/SqlExecutor.cj:905-919` | 命中/未命中计数 | 在 `cache.get(key)` 两分支加计数埋点，跑 10 分钟稳态负载 |
| 3 | 生产开 DEBUG 时参数日志占日志量主要部分并抬高 RSS | `f_orm/src/base/SqlExecutor.cj:936` | 日志字节数 / 单条格式化耗时 | 打开 DEBUG 跑 1 万条带 1 KB 字符串参数的查询，测日志字节数与堆峰值 |
| 4 | 每次执行重建 `SqlArgs` 造成的分配在 ORM 侧分配量中占比可观 | `f_orm/src/wrap/SqlArgs.cj:19-22`、`SqlExecutor.cj:104` | 分配采样 | `cjprof heap` 对比 1 万次 20 参数绑定前后的分配直方图 |

## 文件覆盖

> 与 `files/f_orm.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/README.md` | .md | ✅ | — |
| 2 | `f_orm/README_en.md` | .md | ✅ | — |
| 3 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/design.md` | .md | ✅ | — |
| 4 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/proposal.md` | .md | ✅ | — |
| 5 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/specs/orm-result-type-mapping/spec.md` | .md | ✅ | — |
| 6 | `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/tasks.md` | .md | ✅ | — |
| 7 | `f_orm/doc/spec/test-f-orm-update-column-keys/design.md` | .md | ✅ | — |
| 8 | `f_orm/doc/spec/test-f-orm-update-column-keys/proposal.md` | .md | ✅ | — |
| 9 | `f_orm/doc/spec/test-f-orm-update-column-keys/specs/orm-update-binding/spec.md` | .md | ✅ | — |
| 10 | `f_orm/doc/spec/test-f-orm-update-column-keys/tasks.md` | .md | ✅ | — |
| 11 | `f_orm/doc/优化方案.md` | .md | ✅ | — |
| 12 | `f_orm/src/ORM.cj` | .cj | ✅ | — |
| 13 | `f_orm/src/ProtectedMacros/EmbedSensitive.cj` | .cj | ✅ | — |
| 14 | `f_orm/src/base/ArgAnyBinding_test.cj` | .cj | ✅ | — |
| 15 | `f_orm/src/base/ArgBindCount_test.cj` | .cj | ✅ | — |
| 16 | `f_orm/src/base/ArgInSql_test.cj` | .cj | ✅ | — |
| 17 | `f_orm/src/base/ArgSqlText_test.cj` | .cj | ✅ | — |
| 18 | `f_orm/src/base/ChooseCondition.cj` | .cj | ✅ | — |
| 19 | `f_orm/src/base/ColumnInfo_test.cj` | .cj | ✅ | — |
| 20 | `f_orm/src/base/Columns.cj` | .cj | ✅ | — |
| 21 | `f_orm/src/base/CondRelOp.cj` | .cj | ✅ | — |
| 22 | `f_orm/src/base/Condition.cj` | .cj | ✅ | — |
| 23 | `f_orm/src/base/ConditionTrim_test.cj` | .cj | ✅ | — |
| 24 | `f_orm/src/base/Connection_test.cj` | .cj | ✅ | — |
| 25 | `f_orm/src/base/DAO_test.cj` | .cj | ✅ | — |
| 26 | `f_orm/src/base/Datasource_test.cj` | .cj | ✅ | — |
| 27 | `f_orm/src/base/Dialect.cj` | .cj | ✅ | — |
| 28 | `f_orm/src/base/DirtyTag.cj` | .cj | ✅ | — |
| 29 | `f_orm/src/base/Driver_test.cj` | .cj | ✅ | — |
| 30 | `f_orm/src/base/ExtendString.cj` | .cj | ✅ | — |
| 31 | `f_orm/src/base/GroupedQueryMapper.cj` | .cj | ✅ | — |
| 32 | `f_orm/src/base/IdQueryMapper.cj` | .cj | ✅ | — |
| 33 | `f_orm/src/base/LogicalExpr.cj` | .cj | ✅ | — |
| 34 | `f_orm/src/base/LoopCondition.cj` | .cj | ✅ | — |
| 35 | `f_orm/src/base/MeetCondition.cj` | .cj | ✅ | — |
| 36 | `f_orm/src/base/NestQueryMapper.cj` | .cj | ✅ | — |
| 37 | `f_orm/src/base/NoneConnection.cj` | .cj | ✅ | — |
| 38 | `f_orm/src/base/ORM.cj` | .cj | ✅ | — |
| 39 | `f_orm/src/base/ORMColumn.cj` | .cj | ✅ | — |
| 40 | `f_orm/src/base/ORMInitializer.cj` | .cj | ✅ | — |
| 41 | `f_orm/src/base/ORM_test.cj` | .cj | ✅ | — |
| 42 | `f_orm/src/base/Pagination.cj` | .cj | ✅ | — |
| 43 | `f_orm/src/base/Partials.cj` | .cj | ✅ | — |
| 44 | `f_orm/src/base/QueryMapper.cj` | .cj | ✅ | — |
| 45 | `f_orm/src/base/QueryMapperConverter.cj` | .cj | ✅ | — |
| 46 | `f_orm/src/base/QueryMappers.cj` | .cj | ✅ | — |
| 47 | `f_orm/src/base/QueryMappersInit.cj` | .cj | ✅ | — |
| 48 | `f_orm/src/base/QueryResultIterator.cj` | .cj | ✅ | — |
| 49 | `f_orm/src/base/QueryResultIterator_test.cj` | .cj | ✅ | — |
| 50 | `f_orm/src/base/QueryResult_test.cj` | .cj | ✅ | — |
| 51 | `f_orm/src/base/RootDAO.cj` | .cj | ✅ | — |
| 52 | `f_orm/src/base/RootService.cj` | .cj | ✅ | — |
| 53 | `f_orm/src/base/SqlDSL.cj` | .cj | ✅ | — |
| 54 | `f_orm/src/base/SqlExecutor.cj` | .cj | ✅ | — |
| 55 | `f_orm/src/base/SqlExecutorArgBranches_test.cj` | .cj | ✅ | — |
| 56 | `f_orm/src/base/SqlExecutorConnectingTimeout_test.cj` | .cj | ✅ | — |
| 57 | `f_orm/src/base/SqlExecutorStatement_test.cj` | .cj | ✅ | — |
| 58 | `f_orm/src/base/SqlPartial.cj` | .cj | ✅ | — |
| 59 | `f_orm/src/base/SqlPartialColumnKey_test.cj` | .cj | ✅ | — |
| 60 | `f_orm/src/base/SqlResultCacheStream_test.cj` | .cj | ✅ | — |
| 61 | `f_orm/src/base/SqlResultCache_test.cj` | .cj | ✅ | — |
| 62 | `f_orm/src/base/Statement_test.cj` | .cj | ✅ | — |
| 63 | `f_orm/src/base/TableClause.cj` | .cj | ✅ | — |
| 64 | `f_orm/src/base/TableMeta.cj` | .cj | ✅ | — |
| 65 | `f_orm/src/base/TableMetas.cj` | .cj | ✅ | — |
| 66 | `f_orm/src/base/TableSchema.cj` | .cj | ✅ | — |
| 67 | `f_orm/src/base/TransactionAspect.cj` | .cj | ✅ | — |
| 68 | `f_orm/src/base/TransactionHook.cj` | .cj | ✅ | — |
| 69 | `f_orm/src/base/TransactionStatus.cj` | .cj | ✅ | — |
| 70 | `f_orm/src/base/Transaction_test.cj` | .cj | ✅ | — |
| 71 | `f_orm/src/base/Transactional.cj` | .cj | ✅ | — |
| 72 | `f_orm/src/base/TrsactionHooks.cj` | .cj | ✅ | — |
| 73 | `f_orm/src/base/UpdateResult_test.cj` | .cj | ✅ | — |
| 74 | `f_orm/src/base/converter.cj` | .cj | ✅ | — |
| 75 | `f_orm/src/base/imports.cj` | .cj | ✅ | — |
| 76 | `f_orm/src/exception/ConnectionException.cj` | .cj | ✅ | — |
| 77 | `f_orm/src/exception/DirtyFieldException.cj` | .cj | ✅ | — |
| 78 | `f_orm/src/exception/MandatoryTransactionException.cj` | .cj | ✅ | — |
| 79 | `f_orm/src/exception/MockDBException.cj` | .cj | ✅ | — |
| 80 | `f_orm/src/exception/NeverTransactionException.cj` | .cj | ✅ | — |
| 81 | `f_orm/src/exception/NoIdException.cj` | .cj | ✅ | — |
| 82 | `f_orm/src/exception/NoneTransactionException.cj` | .cj | ✅ | — |
| 83 | `f_orm/src/exception/ORMException.cj` | .cj | ✅ | — |
| 84 | `f_orm/src/exception/PropagationException.cj` | .cj | ✅ | — |
| 85 | `f_orm/src/exception/SqlArgException.cj` | .cj | ✅ | — |
| 86 | `f_orm/src/exception/StartFailureTransactionException.cj` | .cj | ✅ | — |
| 87 | `f_orm/src/exception/TableMetaException.cj` | .cj | ✅ | — |
| 88 | `f_orm/src/exception/TransactionException.cj` | .cj | ✅ | — |
| 89 | `f_orm/src/exception/imports.cj` | .cj | ✅ | — |
| 90 | `f_orm/src/macros/DAO.cj` | .cj | ✅ | — |
| 91 | `f_orm/src/macros/ORMField.cj` | .cj | ✅ | — |
| 92 | `f_orm/src/macros/QueryMappersGenerator.cj` | .cj | ✅ | — |
| 93 | `f_orm/src/macros/TransactionalService.cj` | .cj | ✅ | — |
| 94 | `f_orm/src/migro/MysqlSchema.cj` | .cj | ✅ | — |
| 95 | `f_orm/src/migro/PostgresSchema.cj` | .cj | ✅ | — |
| 96 | `f_orm/src/migro/SchemaFinder.cj` | .cj | ✅ | — |
| 97 | `f_orm/src/migro/SchemaFinderMediator.cj` | .cj | ✅ | — |
| 98 | `f_orm/src/migro/SubCommand.cj` | .cj | ✅ | — |
| 99 | `f_orm/src/migro/f_mockdb_po_test.cj` | .cj | ✅ | — |
| 100 | `f_orm/src/migro/imports.cj` | .cj | ✅ | — |
| 101 | `f_orm/src/migro/migro_test.cj` | .cj | ✅ | — |
| 102 | `f_orm/src/orm_test/AnnotatedQueryMappers_test.cj` | .cj | ✅ | — |
| 103 | `f_orm/src/orm_test/ORM_test.cj` | .cj | ✅ | — |
| 104 | `f_orm/src/wrap/ConnectionWrap.cj` | .cj | ✅ | — |
| 105 | `f_orm/src/wrap/DataType.cj` | .cj | ✅ | — |
| 106 | `f_orm/src/wrap/DatabasePool.cj` | .cj | ✅ | — |
| 107 | `f_orm/src/wrap/DatasourceCreator.cj` | .cj | ✅ | — |
| 108 | `f_orm/src/wrap/DummyTransaction.cj` | .cj | ✅ | — |
| 109 | `f_orm/src/wrap/InputStreamOwnership_test.cj` | .cj | ✅ | — |
| 110 | `f_orm/src/wrap/NamedDatasource.cj` | .cj | ✅ | — |
| 111 | `f_orm/src/wrap/NoneConnection.cj` | .cj | ✅ | — |
| 112 | `f_orm/src/wrap/ORMConfig.cj` | .cj | ✅ | — |
| 113 | `f_orm/src/wrap/ORMConfig_test.cj` | .cj | ✅ | — |
| 114 | `f_orm/src/wrap/Propagation.cj` | .cj | ✅ | — |
| 115 | `f_orm/src/wrap/QueryResultWrap.cj` | .cj | ✅ | — |
| 116 | `f_orm/src/wrap/QueryResultWrap_test.cj` | .cj | ✅ | — |
| 117 | `f_orm/src/wrap/SqlArg.cj` | .cj | ✅ | — |
| 118 | `f_orm/src/wrap/SqlArgBinding_test.cj` | .cj | ✅ | — |
| 119 | `f_orm/src/wrap/SqlArgs.cj` | .cj | ✅ | — |
| 120 | `f_orm/src/wrap/StatementWrap.cj` | .cj | ✅ | — |
| 121 | `f_orm/src/wrap/TransactionWrap.cj` | .cj | ✅ | — |
| 122 | `f_orm/src/wrap/imports.cj` | .cj | ✅ | — |

合计：`.cj` 111 个 / `.md` 11 个 / 共 122 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 #1 / #2 / #5 / #6 / #8 / #9；文档契约 #3 / #4 / #7。安全性：README 对注入的口径（§5.1 全部走 `?` 绑定、§11.5 `argInSql` 明确标注"不转义、只给受控内容"）与实现一致，未发现"文档鼓励拼串"之处；凭据相关风险落在 #3 / #4（敏感信息取值链与 SM4 键名写错）。语言特性：README 的 `Option` / `interface` 默认实现 / `extend` 语义描述与源码一致，未命中 |
| §1 死代码 | 0 | 本部分无 `.cj`，不做符号级死代码扫描（由第 2–8 部分覆盖）。已对 README 列举的符号做存在性核对：`ORMConfig.sm4*` 常量、`SqlArgs.clone()`、`SqlArgs.clear()` 三者在源码中不存在（"文档里有、代码里没有"），已并入 #4 / #10；未发现"代码里有、README 未提"的对外可达 `public`（`grep` 核对 §4 / §5 / §19.2 清单，缺项只有 #7 的两个配置项） |
| §2 重复逻辑 | 0 | 本部分无 `.cj`，不做函数体两两比对。范围外提示（不计入统计）：取证时见到 `SqlPartial.UPDATE<T>(Map<String, Any>)`（`SqlPartial.cj:144-181`）与 `UPDATE<T, ID>(Map<String, Any>, id)`（`188-225`）的 SET 构造段几乎逐行相同，属源码级重复，交后续部分判定 |
| §3 空实现 | 0 | README 本身无实现。核对"文档承诺 + 代码是否落实"的 4 项：`:name` 绑定、`argInSql`、结果缓存、迭代器 `close()` 顺序均落实；`:{...}` 路径与 `Iterable` 展开属**实现有缺陷**而非空实现（已入 #5 / #6） |
| §4 栈溢出 | 0 | 本部分无递归代码。取证路径上的 `SqlDSL.compile` 是 `while` 循环（缺陷是循环条件写错，见 #5，不是递归） |
| §5 OOM | 0 | 本部分无容器 / 物化逻辑。README 未承诺任何"全量读入"能力；§13.6 对 BLOB 的"整块内存副本"风险已如实写明，口径与 `QueryResultWrap` 一致 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，不成立；DSL 缓存命中率降级为待验证假设 1 |
| §6.2 大粒度锁 | 0 | 本部分不涉及锁；README §5 明确"同一 `SqlExecutor` 不允许并发"，与 `activeQueryResult` 检查（`SqlExecutor.cj:963-966`）一致，无"文档鼓励在锁内做 I/O"的表述 |
| §6.3 并发串行 | 0 | 本部分无线程模型描述上的串行承诺；`ThreadLocal` 线程内复用语义（§1、§5、§5.5）与 `currents` / `current` 实现一致 |
| §6.4 低效算法 | 0 | 本部分无算法实现；仅待验证假设 1 涉及重复解析 |
| §7 降堆内存方案 | 0 | 无 `.cj`，不产出 |
| §8 降 CPU 方案 | 0 | 无 `.cj`，不产出 |
| §9 local mode 可行性 | 0 | 无函数体可评估逃逸；README 未涉及 local mode |
| §11 现有代码的 BUG（存量） | 5 | #1（`false` 被提交）、#2（`readOnly` 粘滞）、#5（DSL 路径循环条件）、#6（DSL 占位符翻倍）、#9（`Pagination` 除零）。另核对了 `close()` 语义（§5.5 与 `SqlExecutor.cj:153-174` 一致）、事务钩子 5 种顺序（§5.4 与 `1028-1103` 一致）、`UPDATE` 三条异常消息（§7.2 与 `SqlPartial.cj:146/170/172` 一致，含 `udpate` 拼写）、`StatementWrap` 无 `getConnection` 且参数版 `update/query` 抛 `current access is deprecated`（§19.2 与 `StatementWrap.cj:38-43` 一致）、异常继承树（§17.1 与 `src/exception/*.cj` 一致）、8 个方言类（§19.1 与 `Dialect.cj:56-138` 一致）、4 个 `SchemaFinder` 实现（§16.4 与 `migro/*.cj` 一致）——均无缺陷 |
| §12 并发安全与锁粒度 | 0 | 本部分不审并发实现。README 的并发口径（"`SqlExecutor` 线程内单例、禁止同一实例并发"）与 `SqlExecutor.cj:44-45`、`113-132`、`963-966` 一致；锁粒度问题留给后续部分 |
| §14 功能完备性与 README 覆盖 | 1 | #7（`orm_connectingTimeout` / `orm_databasePoolMaxWaiting` 及对应 getter 与 const 未文档化）。其余核对：`ORM` 的 11 个 `register` 重载（`ORM.cj:74-147`）、`SqlExecutor` 的 `add` 全类型重载、`SqlPartial` 的 `INTO/UPDATE/FROM`、`RootDAO.arg/meet/choose/loop`、`TableMeta/TableMetas`、`Transactional`、`ORMInitializer`、`MigroCommand` 均在 README 中可检索到；反向核对未发现 README 承诺但代码完全缺失的能力（`:{...}`、`Iterable` 展开是"有实现但坏"，#5 / #6） |
| 文件覆盖（§13 等） | 1/1 | `README.md` 全读；本部分清单只有这一个文件，无缺项 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #2（`readOnly` 文档相反且实现粘滞）、#9（示例 WHERE 列错）、#1（夹具顺序依赖）；设计：本部分无分层/依赖问题（`ORM.cj` 只做再导出）；语言特性 #6 / #7（用 `Any` 分派 + `ArgAnyBinding` 的可观测性受 `private args` 限制）；可读性 #5 / #11；安全性 #3（凭据来源与 SM4 强度描述） |
| §1 死代码 | 1 | 逐个符号过了一遍：本部分 4 个 `.cj` 里**没有任何** `private` / `internal` / `protected` 成员声明（唯一的 `protected` 是 `EmbedSensitive.cj:16` 的包声明；`ORM.cj` 只有一条 `public import`；`EmbedSensitive.cj` 是一个 `public macro` + 一条 `public import`；两个用例类的成员都被 `@TestCase` 引用），因此「非 public 符号无调用者」类 0 命中；`public` 侧：`ORMEmbedSensitive` 是宏（对外/对内扩展点，`base/imports.cj:38` 有调用），测试类与 `@TestCase` 由框架调用，均不判。唯一命中是 6 个未使用 `import`（#5）。另核对：`EmbedSensitive.cj:26` 的 `public import ...EmbedSensitive` 的 `public` 在 `protected macro package` 内实际不可跨模块引用，但其导入本身被 `42` 行使用，只作信息，不单列 |
| §2 重复逻辑 | 0 | 同文件两两比对：`ArgAnyBinding_test` 两个用例无同语义（一个验分支存在性、一个验分派成本）；`ArgBindCount_test` 与 `ArgAnyBinding_test` 的不变量不同（占位符=绑定数 vs 返回 `?`），不算重复。跨文件：两处「按字节数 `?`」的计数（`ArgBindCount_test.cj:43-48`）与本仓 `f_mockdb` 的先例同形，属测试辅助，按 §2 误报边界不计。文档层：事务回调顺序表在 §5.4（`550-560`）与 §14.4（`1786-1794`）各有一份，`14.4` 显式指向 `5.4` 且少了 `rollbackFor` 命中行，属有意摘要，不判重复（若将来改一处忘另一处，风险已在 #3 那类文档问题里体现） |
| §3 空实现 | 0 | 逐处核对：`ORM.cj` 无函数体（纯再导出）；`ORMEmbedSensitive` 的宏体非空且有实际产出（`29-42`）；两个用例的 `@TestCase` 全有断言（`@Assert` 双参语义已查文档确认）；无 `TODO` / `FIXME` / `UnsupportedException` / `catch { }` / 空 `case _ => ()`。`MOCKDB.execution` 的缺省 `EMPTY_EXECUTION`（`mockdb.cj:38-40`）是「没有夹具」的 Null Object，有注释说明，不判 |
| §4 栈溢出 | 0 | 无递归：宏体只有一层 `for`（`35-41`），用例无递归、无自引用结构、无深度拷贝；`quote` / `@EmbedSensitive` 的展开深度由驱动数决定（配置常量级） |
| §5 OOM | 0 | 编译期：`keys` 只随 `orm_drivers` 条目数线性增长（每驱动 3 个 token），无用户可控长度；运行期：本部分无容器、无 `readToEnd`、无按报文长度预分配。用例侧 `ArgAnyBinding_test:92-100` 每次 `arg` 会往 `SqlArgs` 追加 1000 个参数，但只活在一个用例内且随后 `close()`，不构成模块级 OOM 风险 |
| §6.1 热点瓶颈 | 0 | 未提供任何 `cjprof` / `cjpm bench` 数据；本部分唯一与耗时相关的是 `ArgAnyBinding_test` 的自计时用例，其阈值稳定性进假设 3，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁：宏在编译期单线程执行，用例无 `synchronized` / `Mutex` |
| §6.3 并发串行 | 0 | 无 `spawn`、无并发度配置、无单消费者队列 |
| §6.4 低效算法 | 0 | 宏里 `keys += quote(...)` 是编译期字符串拼接，O(驱动数²) 但规模是配置级（≤ 数个驱动），不构成运行时成本；用例的两个 1000 次循环是 O(n) |
| §7 降堆内存方案 | 0 | 见「优化可行性方案」：本部分无生产侧分配热点；唯一有数据的候选已被 spec 决策否决 |
| §8 降 CPU 方案 | 0 | 同上；`arg(Any)` 的分派顺序与成本属 `base/RootDAO.cj`（其他部分），本部分只用例护栏 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内用完」的大对象；模块内唯一候选（`SqlPartial.UPDATE` 的中间 `HashMap`）已在 `doc/spec/test-f-orm-update-column-keys/design.md:9-15,30-38` 用探针证明被 `Any` 的 local 限定阻断（1,542 B→120 B 可达但真实代码编译不过），结论为不可行，无需重复评估 |
| §11 现有代码的 BUG（存量） | 11 | 11 条全部为存量（快照无 diff）：代码/测试侧 #1、#5、#6、#7、#8；文档侧 #2、#3、#4、#9、#10、#11。另逐项核对了本轮读到的边界与空值：`ArgBindCount_test` 的 `problems[0]` 取值前有 `size > 0` 守卫（`66-70`）、`ArgAnyBinding_test` 的 `finally { ex.close() }`（`78-80`、`104-106`）、宏的 `for(d in getDriverNames())` 空集合退化（只嵌全局键，与 `ORMConfig` 的取值回退一致），均无缺陷 |
| §12 并发安全与锁粒度 | 1 | #1：`MOCKDB.execution` 是进程级 `AtomicOptionReference` 单例（`f_mockdb/src/mockdb.cj:57`），用例写后不还原 ⇒ 同进程后续用例会读到别人的夹具（顺序依赖；当前无实际受害用例，属潜伏）。本部分无锁，故锁粒度 0 命中；宏的编译期执行也无线程共享面。已核对：两个用例都在 `try/finally` 里 `close()` executor，没有连接泄漏 |
| §14 功能完备性与 README 覆盖 | 2 | #4（两个公开配置键 + 两个 getter 完全无文档，已点名 `orm_connectingTimeout` / `orm_databasePoolMaxWaiting` / `getConnectingTimeout` / `getPoolMaxWaiting`）、#3（§14.0 的承诺其实成立，§18 却断言运行期不读，同一份文档自相矛盾）。其余 public 符号抽查（`ORM` 静态 API、`SqlDSL`、`Pagination`、`SqlDialect`、`QueryMapper` 家族、`DirtyTag`）在 README 中均有登记 |
| 文件覆盖（§13 等） | 14/14 | 无缺文件；10 个 `.md` 全部逐节对照实现（#2/#3/#4/#9/#10/#11 为命中项，其余章节一致） |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1 / #2 / #4 / #5 / #6 / #8；设计 #9（求值与绑定耦合）、#13（单例可变）；安全性 #12（标识符直通）；可读性 #16 / #21 / #22；语言特性：`Unit` 实现 `ToString`（`core.md:29`）导致 #4 的 `"()"` 绑定，`ThreadLocal` 语义见 #3 / #9 |
| §1 死代码 | 2 | 已逐个 `private`（全仓搜）/ 默认 `internal`（本包及子包搜）/ `protected` 排查：#18 列出 7 个无引用符号（`Columns.executor`、3 个 `newXxx`、`SqlDialectMediator` 的 3 个 `lastInsertId` + `limit`）；#19 列出测试替身链（`DatasourceCreatorImpl` → `DriverTest` → `DatasourceTest` → `ConnectionTest`）与注释文件。无不可达语句（`return` 后无同层语句）；`Columns.tableAlias_` / `SqlExpr.alias_|sort` / `DirtyTag` 的 `protected` 成员分别属于「`public abstract class` 的扩展点」与「有引用」，不判；对外可达的 `public`（`SqlExpr` 16 个运算符、`LoopCondition` 8 个链式方法、`Column`、`EmptyExpr`、`InExpr` 等）一律不判，其中 `LoopCondition.wrapLeft/wrapRight/trimLeft/trimRight`、`Columns.tableAlias` 仓内零调用（`IdQueryMapper.id` 被 `QueryMappers.cj:97` 使用，不在此列），记「对外 API、仓内无引用」作为信息 |
| §2 重复逻辑 | 3 | 同文件两两比对 20 个文件的函数体：`Condition.SET` vs `WHERE`（#15）、`CondRelOp` vs `RelationOp`（#14）、`ExtendString.AND/OR/NOT` vs `Partials.AND/OR/NOT`（#21）。另核对：`CmpExpr` vs `InExpr` vs `In2Expr` 的 `toString` 骨架相似但取值规则不同（差异已被 #8 报为缺陷，不重复计）；`MeetCondition.IN` vs `NOT_IN` 只差 `' in'`/`' not in'`（两个公开重载，语义对称，属预期形态，不判）；`GroupedQueryMapper` 三个 `populate` 的 getter 形态不同（`ArrayList.add` vs 逐 mapper 写），不构成重复 |
| §3 空实现 | 1 | #20（测试替身 `close`/`setOption` 空体、`isClosed` 恒 false，且无注释说明）；`GroupedQueryMapper` 的 `super(putter: {o, v =>}, ...)` 是刻意的 no-op putter（分组映射器不用 `putter`，字段由 `populate` 写），不算空实现；`SqlDialect.lastInsertId` 基类返回 `''` 已在「范围外提示 2」记录 |
| §4 栈溢出 | 0 | 仅 `DirtyTag.setDirtyField` / `setBeforeDirty` 的二层自递归（`47` / `56`），`register<T>()` 后必然命中 `Some`，深度固定为 1；`LogicalExpr` 的表达式树按「用户手写的嵌套深度」递归，无自引用环、无用户输入的深层结构（DAO 代码里手写的条件层数是个位数量级），不构成 §4 风险 |
| §5 OOM | 2 | #6（`IN`/`loop` 元素数无上限、无拒绝路径，占位符串与参数表同步线性增长）、#10（`partials` 在长事务内只增不清）。已核对：`ChooseCondition.conditions` / `LoopCondition` 的临时对象都随构建器实例死亡；`GroupedQueryMapper` 的 `ArrayList` 由结果集行数决定（属结果集本身）；`DIRTY_TAGS` 以 `TypeInfo` 为键，类型数有界 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，2 条疑似热点（重复求值、正则构造）全部进「优化可行性方案」+ 待验证假设，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex`；并发面只有 `ConcurrentHashMap`（`DirtyTag`、`SqlDialectMediator`）与 `ThreadLocal`（`Condition.delimiter`、`SqlExecutor.current`），不存在「锁内做 I/O」形态。`DirtyTag` 的无锁读改写已在 #3 按正确性报 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池；executor 是线程封闭的（`ThreadLocal`），不存在「并发度配成 1」的串行段 |
| §6.4 低效算法 | 0 | 逐个核对：`RelationExpr`/`CommaExpr` 是 O(子表达式数)；`LoopCondition` 单趟遍历 + `StringGenerator`；`MeetCondition.IN` 单趟；`Condition.trim` 的正则替换是 O(片段长度)，内部三组已预编译；无嵌套循环匹配、无 `remove(at: 0)`、无循环内 `+` 拼串（`builder` 累积）；`Dialect.involvedIdentifier` 的 `indexOf` 是 O(长度)，不构成量级问题 |
| §7 降堆内存方案 | 1 | 优化方案 1（`partials` / `args` 随语句清零），标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 优化方案 2（表达式树单次求值），标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分的临时对象都是「要逃逸的最终产物」：`LoopCondition.done()` / `MeetCondition.frag()` 的字符串要进 SQL 文本、`Column.toString()` 的结果要进语句、`PARTIALS` 的 `StringGenerator` 是 executor 字段——逃逸检查直接不通过；`GroupedQueryMapper.populate` 的 `ArrayList` 是返回值的一部分。没有「函数内建、函数内销毁」的大对象，也没有 `getAllocatedLocalObjectSize()` 前后峰值数据 |
| §11 现有代码的 BUG（存量） | 24 | 本部分 24 条全部为存量（快照无 diff，`git blame` 落在 `9fe28abd50 2026-09-13` / `e494170cc4 2026-09-15`）。另逐项核对了本轮读到的边界与空值：`MeetCondition.condition == false` 不执行 `frag()`（正确，不会多绑参数）；`ChooseCondition` 的 `pair` 状态机缺 `partial` 时抛异常（正确）；`Dialect.limit` 的返回顺序与三处绑定点一致（正确）；`Condition.trim` 的内部三组输出由 `ConditionTrim_test` 逐字符钉住（正确） |
| §12 并发安全与锁粒度 | 3 | 并发安全 #3（`DirtyTag.beforeDirty` 共享无同步 + `clearAll` 只清本线程）、#13（`Columns` 单例可变字段）、#24（`getDialect` 检查-然后-写入，幂等无害但非原子）。已核对的同步手段：`SqlExecutor` 全部状态线程封闭（`currents`/`current` 为 `ThreadLocal`）；`Condition.delimiter` 线程封闭；`DIRTY_TAGS`/`dialects` 用 `ConcurrentHashMap` 但只保证单次操作原子。锁粒度：#3 需要「跨线程共享的开关 + 线程私有集合」统一到同一作用域，不能靠加锁解决 |
| §14 功能完备性与 README 覆盖 | 0 | README / `doc/**` 不在本部分（第 1、2 部分），本部分只核对了 public 声明与调用链：`LoopCondition` 的 `wrapLeft/wrapRight/trimLeft/trimRight`、`Columns.tableAlias`、`IdQueryMapper.id` 仓内零调用但属对外 API；`GroupedQueryMapper` 构造器与宏生成实参不一致已在「范围外提示 1」记录，无法在本部分给出「承诺源 + 缺失证据」双证，故不计 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，§13 文档一致性留给第 1、2 部分（本报告只引用了 `cangjie-doc/md/doc/core.md:29` 作为 `Unit <: ToString` 的判据） |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 #1 / #2 / #3 / #7 / #9 / #10 / #11 / #12 / #14 / #15；设计 #5（语句级状态与事务级状态混用）、#6（线程内隐藏 executor）；安全性：参数绑定统一走 `arg(...)` / `?`，未发现字符串插值外部输入（`SqlPartial` / `TableClause` 的拼串都是标识符与常量）；语言特性：#5 的 `Option` 静默丢弃、#10 的类型模式分派 |
| §1 死代码 | 1 | #19（`ORM.driverNames` 1 个 + `Partials` 10 个 + `newNest`/`newNullableNest` 2 个，全仓搜索确认零引用）；另核对：`NoneConnection` 的 3 个抛异常方法是 `Connection` 接口实现（豁免）、`QueryMapper.new` / `isGrouped` / `isId` 是 `public open class` 的 protected 扩展点（豁免）、`QueryMappers.idName` 被 `TableClause.cj:283+` 使用、`QueryMapperConverter.lookup` 被宏（`QueryMappersGenerator.cj:289+`）使用、`SqlExecutor.releaseActiveQueryResult` 被迭代器使用、`SqlDSL` 的 private 分片类型全部有构造点 |
| §2 重复逻辑 | 2 | #10（三份 40+ 类型的 `Any` 分派，且 `Data`/`?Any` 分支不一致）、#16（6 个 `register` 重载的同一段前置检查，日志口径不一致）；另核对：`RootService.dao` 两个重载是薄封装、`SqlExecutor.update`/`delete` 共用 `updateOrDelete`、`singleFirst`/`singleList` 的 index/column 变体差异在 `get` 的重载，均属刻意展开，不判重复 |
| §3 空实现 | 2 | #14（测试替身的 `close` 空体 + `isClosed` 恒 false，且 `getOrNull` 恒抛）、#18（空 `@TestCase`）；`NoneConnection.close()` 是哨兵对象的正确 no-op（`state == Closed`），`DummyTransaction` 的空实现是传播语义（`begin` 里按 mode 抛错），均不算 |
| §4 栈溢出 | 0 | 唯一自递归是 `SqlExecutor.connection`（`409-431`）与 `DirtyTag` 的二层自递归：`connection` 只在 `_connection_ is NoneConnection` 时重新取连接再递归一次，`NamedDatasource.connect()` 恒返回 `ConnectionWrap`（`wrap/NamedDatasource.cj:47-49`），深度 ≤ 2；`RootDAO.arg(?Any)` → `arg(Any)` 的递归每层剥一层 `Option`，层数由调用方写死的嵌套决定，无环 |
| §5 OOM | 1 | #8（事务内结果缓存无容量上限、不随语句释放）；另核对：`SqlDSL.compile` 的 `HeapCache` 有 `maxSize: 10000` / 1 天过期（有界）、`rollbackExceptions` 以配置字符串为键（有界）、`list`/`mapList` 的全量物化是 API 语义本身 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据：`blankRegex.replaceAll`、`Any` 分派、`SqlArgs` 哈希、DSL 编译缓存、`groupedList` 五条疑似热点全部进「待验证假设」，不作缺陷、不进 tasks |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / `ReentrantLock`；并发面只有 `ThreadLocal`（`currents` / `current`）与 `ConcurrentHashMap`（`ORM.datasources` / `QueryMapperConverter.converters` / `SqlExecutor.rollbackExceptions`），不存在「锁内 I/O / 锁内回调」形态 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；executor 线程封闭，事务内"单连接串行"是数据库会话的固有约束，不是可并行化的串行段 |
| §6.4 低效算法 | 1 | #21（Connecting 忙等无退让）；另核对：`isSelectStatement` 是 O(1) 前缀判断、`arg<I,T>` 的占位符已改为一次 `"?" * (n-1)`、`groupedList` 用 `LinkedHashMap` O(1) 取行 |
| §7 降堆内存方案 | 2 | 结果缓存上限（#8 的对应方案）、延迟建连 + 空闲 executor 回收；`partials` 的降内存方案已在第 3 部分给出，本部分不重复 |
| §8 降 CPU 方案 | 2 | `Any` 分派合并为类型表、`waitConnecting` 退让；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内用完的大临时对象"：结果集、映射对象、缓存值都要逃逸出函数（返回给调用方或存进 `cache`）；`SqlDSL.compile` 的中间 `Tokens`/`ArrayList` 会被 `HeapCache` 长期持有，也不满足"函数返回即释放"。收益只能靠峰值内存对照证明，当前无数据 ⇒ 不列方案 |
| §11 现有代码的 BUG（存量） | 22 | 本部分 22 条发现全部为存量（快照无 diff）：逐条核对了 `Pagination` 的除法/offset、`SqlDSL` 的两处循环与占位符、`QueryMappers.create` 的数组下标、`SqlExecutor` 的状态位（`readOnly` / `activeQueryResult` / `hasRealTx` / `clearCache`）、`ORM` 的注册与默认库切换、5 个文件的 `Option` 使用点（`commit`/`save`/`release`/`current.get()`/`tx?.`）；`hasRealTx` 不复位经核对不构成泄漏（`close()` 会丢弃整个 executor 实例） |
| §12 并发安全与锁粒度 | 2 | #6（线程内 `current` 单槽被跨驱动覆盖/清空，共享路径是 `ThreadLocal` 单槽 + 所有 SQL 构造点）、#7（`activeQueryResult` 在异常路径不复位，`SqlExecutor` 线程封闭但状态机不自洽）；`DirtyTag.clearAll()` 的跨线程污染属第 3 部分 #3（同源，已交叉引用）；`ORM.datasources` 用 `addIfAbsent` 的检查-然后-写入已核对：`Driver` 重载的 "contains → register" 是竞态窗口，但最终由 `addIfAbsent` 兜住（表现为 #16 的静默丢弃），未造成重复注册 |
| §14 功能完备性与 README 覆盖 | 2 | #4（README:822 承诺的 `:{a.b.c}` 不可用）、#11（嵌套映射器的 `newXxx` 未接线、nullable 语义未实现）；README 其余段落不在本部分文件清单内，`public` 声明与 README 的逐项对照留给第 8 部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完，无 `.md` ⇒ §13 文档一致性主体不在本部分，只在 #4 / #20 处引用了 README 与宏作为承诺源 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 23 | #2–#4、#8、#10、#11 属正确性；#12、#18、#23 属设计；#22 属可读性；安全性（注入）专项结论见下 |
| §1 死代码 | 4 | 已逐个符号搜引用：`sqlPartialLog`/`involve`/`involveTable`/`limit`/`sqlWithLimit`/`APPEND_TRIM_*`/`EMPTY_LOGICAL_EXPR`/`emptyLogicalExpr`/`schemas`/`list` 等均有调用者；命中 4 条：#13（不可达分支）、#8（不可达 `else if`）、#14（死类型参数）、#15（仅测试使用的 public 替身，按可见性建议记录）。对外可达的 `public`（`TableClause` 系列子句、`ColumnMeta/IndexMeta`、`ORMConverter`、`Transactional`、`TransactionStatus`）零引用也不判死代码 |
| §2 重复逻辑 | 4 | 已两两比对同文件函数体并按相同错误文案/字面量跨文件搜：命中 #2（UPDATE 两重载同错）、#3（ORDER_BY 与 GROUP_BY）、#4（`TableClause` 与 `Condition` 的 trim 正则漂移）、#18（`findById`/`deleteById`/`Column` 键映射/`IntoClause` 两构造函数）；另 #12 为跨层复制 |
| §3 空实现 | 2 | #1（`inTx` 契约空：接口有默认空实现、框架从不调用）、#7（两处 `catch(_){}` + `register` 只 warn）；`StatementTest.set/TransactionTest.begin` 等测试替身空实现归入 #15；#19 属异常语义问题，记在正确性维度 |
| §4 栈溢出 | 0 | 本部分无递归调用：`TableClause.condition/PAREN` 只调用传入 lambda 一次，`IntoClause.VALUES` 内嵌套函数不递归，`TableMeta.new` 为迭代器链 |
| §5 OOM | 1 | #6（钩子列表随 `initialize()` 次数无界增长）；其余容器均以"每 PO 类型/每列"为界（`TableMetas.schemas`、`ColumnMeta` 数组），无按不可信长度预分配 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/`cjpm bench` 数据，未成立任何热点结论；三条线索已进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / 显式锁，无临界区可评 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 并行批处理 |
| §6.4 低效算法 | 0 | 循环均为 O(列数/Mapper 数)，`sort(list)` 只在注册期；无嵌套扫描、无 `remove(at: 0)`、无循环内字符串 `+`（统一 `StringGenerator`） |
| §7 降堆内存方案 | 1 | 「[堆内存] 去掉 UPDATE 中间 HashMap」（无基线） |
| §8 降 CPU 方案 | 1 | 「[CPU] `TableMeta.new` 迭代器链」（无基线） |
| §9 local mode 可行性 | 0 | 本部分临时对象（SQL 片段、`ArrayList`）都逃逸到 executor / 返回值，且峰值内存无对照数据，改造不成立 |
| §11 现有代码的 BUG（存量） | 9 | #2、#3、#4、#8、#9、#10、#11、#12、#23；另外 #6、#7、#19 同时具备并发/错误处理属性 |
| §12 并发安全与锁粒度 | 1 | 共享路径只有 `ORM.hooks.list`（static）与 `TableMetas.schemas`（`ConcurrentHashMap`，写入在静态初始化、读取走迭代器，安全）；命中 #6（注册无同步，与 `ORM.registerTransactionHook` 的 public 入口构成"检查-然后-写入 + 迭代中修改"）。#5 是顺序契约问题，不计入本行 |
| §14 功能完备性与 README 覆盖 | 2 | #1（`inTx` 未实现）、#9（`comment` 未接线）；README 中 `deleteById` 的怪异返回值已在 #23 记录，属"已文档化的债务" |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md`，§13 不适用（模块 README/doc 由其他部分覆盖）；20 个 `.cj` 全部逐行读完 |

安全性专项补充（不计入上表）：本部分所有值绑定走 `arg()`/`argNull()`（`SqlPartial.cj:164/166/174/207/209/217/253/264`、`TableClause.cj:283-299/414-420/485`），未发现把外部输入插值进 SQL 的路径；`involve()` 只引用 mapper 的列名（受注解控制）。`WHERE(String)`/`ORDER_BY(() -> String)`/`ON_DUPLICATE_KEY_UPDATE` 等是显式的"原生 SQL 逃生口"，属既定设计，不在本部分判为注入。

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性 5（S1、S2、S3、G2、G9）、设计 2（G5 的宏副作用、M7 的异常层次）、语言特性 2（S1 的 `Option` 静默丢弃、G5 的展开期可见性）、可读性 2（M5、M6）、安全性 1（G3） |
| §1 死代码 | 1 | 逐个 private / internal 符号搜过引用：`expand`/`reportError`/`expandORMField`/`expandQueryMappers`/`generateMappers`/`transformTableName`/`generateColumns`/`indexColumns`/`indexIndexes`/`esc`/`generateColumn` 均有调用者；13 个异常类均为对外可达 `public`，按硬原则一**不判**死代码（`DirtyFieldException`、`NoneTransactionException` 仓内零引用，仅记录为信息）；命中项为未使用的 `import fountain::f_regex.*`（M1） |
| §2 重复逻辑 | 1 | 已把本部分 20 个文件的函数体压成「输入→输出→副作用」两两比对：异常类的 4 个构造（52 处）属语言限制（构造不被继承），不判；命中 5 组同语义实现（M2），另 S3 属「近似重复少了边界判断」的重复形态 |
| §3 空实现 | 1 | 空函数体只有异常类的 `public init(){}`（合法转发）；命中 `try{...}catch(_){}` 静默吞异常 1 处（G6 的后半） |
| §4 栈溢出 | 0 | `ORMField.expandORMField`（`:84-99`）与 `QueryMappersGenerator.expandQueryMappers`（`:73-78`）确有自递归，但深度 = 源码注解嵌套层数（由源文件写法限定，用户不可在运行期控制），且无环检测需求，不构成无界递归 |
| §5 OOM | 0 | 本部分唯一的全量物化是单表列/索引级别的 `ArrayList<String>`（数量由表结构决定，几十到几百条），无按不可信长度预分配、无全局增长容器；`TableMetas`/`DirtyTag` 的全局容器只增不减问题在 `src/base`（本部分范围外） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；宏只在编译期运行、migro 为 CLI 路径，无自耗时占比与调用频次证据，相关猜测已列入「待验证假设」#1–#4 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁原语（`synchronized` / `Mutex` / `Atomic` 零命中）；生成的 `TableMetas.register` 走 `ConcurrentHashMap`，不在本部分实现内 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future`；migro 全流程单线程遍历表，串行度由 CLI 语义决定，非热点 |
| §6.4 低效算法 | 0 | `generateAlterSql` / `generateIndexSql` 的查找全部走 `HashMap`（O(n)），无嵌套扫描、无 `remove(at: 0)`、无循环内字符串 `+`（用 `StringGenerator`）；`attrs` 解析为线性扫描 |
| §7 降堆内存方案 | 1 | 见「优化可行性方案 / 堆内存」一条（`无基线（待验证）`） |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 / CPU」一条（`无基线（待验证）`） |
| §9 local mode 可行性 | 0 | 本部分热路径都在编译期（宏）或 CLI（migro），无高频短命临时对象；`Tokens` / `Token` 来自 `std.ast`，没有 local mode 重载，逃逸检查也无法通过（生成的 token 要作为编译产物返回），结论为不可行，不列方案 |
| §11 现有代码的 BUG（存量） | 20 | 全部 20 条均为存量（快照模式无 git 基线）；其中严重 4、一般 9、轻微 7 |
| §12 并发安全与锁粒度 | 0 | 宏在编译期单线程执行；migro 由 `SubCommand.exec` 单线程驱动；本部分代码内无共享可变状态、无线程池、无跨线程句柄（`SqlExecutor` 的线程内复用语义在 `src/base`，属第 3–5 部分） |
| §14 功能完备性与 README 覆盖 | 2 | 与 README `§16`（`f_orm/README.md:1974-2016`）逐条对照：`generateIndexSql` 承诺「增删索引」但 Postgres 新索引只产出 `";"`（S4）；`generateAlterSql` 承诺「按重命名处理」但实现同时 `add column`（S3）；其余方法签名与 README 一致 |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md` 文件，§13 文档一致性在本部分无适用对象；README 侧结论归第 1、2 部分，本报告只引用其行号作「承诺源」 |

### 第 7 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1 #4 #5；错误处理 #3 #8；安全性 #6（DDL 破坏面、标识符未加引号）；语言特性：`ConcurrentHashMap[]` 的抛异常语义、`parse`/`tryParse` 语义均已查文档（#4 #8） |
| §1 死代码 | 2 | 已对每个 `private`/`internal`/`protected` 符号全仓搜引用：`wrap/NoneConnection` 整文件零引用（#9）；`ORMConfig` 4 处 `case _ where !driverName.isEmpty()` 回退分支恒等价（#10）。`DataType` 子类与 3 个 `type` 别名由宏按名拼接（`QueryMappersGenerator.cj:248`），不算死代码；`DatabasePool.cj` 是 `public import` 重导出、`DatasourceCreator`/`DummyTransactionMode`/`Propagation` 是对外可达或已被 `SqlExecutor` 使用，均不判。`QueryResultWrap.next(values)` 的未用形参属接口实现，不判。 |
| §2 重复逻辑 | 4 | `wrap/NoneConnection` 与 `base/NoneConnection` 逐行重复（#9）；`makeReader` / `toMap` 两张 typeName 表（#7）；`getOrNull` 的 18×18 转换矩阵与 `convertFromString` 再一份（#11）；同一组 options 经 `open` 与 `setOption` 各应用一遍（#19）。`DataType` 20 个类的样板与 `ORMConfig` 4 个 `getStdPool*` 的近似重复按"宏/字面量差异属业务要求"记录在 #11/#O3，未单列。 |
| §3 空实现 | 0 | 逐函数体核对：`DummyTransaction.commit/rollback/save/release` 与 `NoneConnection.close` 是 README 明文记录的 Null Object（`README.md:2194`、`README.md:386/545`），有契约、有调用方；无 `TODO`/`FIXME`；`catch` 全部有日志或重抛（`SchemaFinderMediator:109` 的"吞"已按 #3 计缺陷）。 |
| §4 栈溢出 | 0 | 全部分无递归：`ORMConfig.getTransactionLevel/AccessMode/DeferrableMode/getUseCache` 的自递归都把 `driverName` 降为空串后终止（`getConf` 在 `134-140` 已合并全局键，见 #10），不存在无界递归；无递归遍历、无自引用结构。 |
| §5 OOM | 0 | `generate` 把全部 SQL 物化成 `ArrayList<(String,String)>`，上界=表数×列数（schema 规模，KB 级）；`QueryResultWrap.list` 上界=列数；`converterMap`/`finders` 只在启动写一次、按驱动/类型为键，有界。无按不可信长度预分配、无只增不减的全局容器。 |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据，无法成立热点结论；`getOrNull` 多层 match、reader 闭包、逐语句建连、配置全量复制 4 项已列入「待验证假设」并给出采数方法。 |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件无 `Mutex`/`synchronized`/`ReentrantLock`；唯一的并发结构是 `ConcurrentHashMap`（`SchemaFinderMediator.finders`、`ORMConfig.converterMap`），无临界区、无锁内 I/O。 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`；迁移语句串行执行是 CLI 语义（不是把可并行任务串行化）。 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无热点 `contains`/`indexOf`、无 `remove(at: 0)`、无循环内字符串拼接（`StringGenerator` 已用）；`getAllConfigs` 的逐键 `replace` 与按列前缀读取归入 #O2/#O3 待验证。 |
| §7 降堆内存方案 | 2 | #O1（reader 闭包按列复用）、#O2（只缓存被请求列）；均无基线，标注"待验证"。 |
| §8 降 CPU 方案 | 2 | #O3（配置快照）、#O4（类型矩阵查表化）；均无基线。 |
| §9 local mode 可行性 | 0 | 本部分热点候选（`getOrNull` 的闭包/中间 `Any`）都是会被调用方持有或跨函数返回的值（`?T` 返回、`list` 成员），逃逸检查不通过；没有 peak memory 前后对照也无法证明收益，故不作为方案。 |
| §11 现有代码的 BUG（存量） | 10 | #1 #2 #3 #4 #5 #6 #7 #8 #13 #17（其余 #9 #10 #11 #12 #14 #15 #16 #18 #19 #20 为死代码/重复/测试/可读性类）。本轮读到的 20 个文件里每个 `Option`/越界/空集合路径均已核对：`columns.size <= index` 有上界检查但无下界（#17）；`columnInfoMap` 重名覆盖（#14）；`convertFromString` 缺 Bool/Rune（#13）。 |
| §12 并发安全与锁粒度 | 2 | 共享点只有 `ORMConfig.transactionIncludingRegex/transactionExcludingRegex`（`private static var`，`static init`/`Config.set` 回调写、`transactionable` 读，无原子/无同步 ⇒ 弱可见性，见 #15）；同一个 `refresh` 入口还能被调用方覆盖掉刷新回调（#20）。`finders`/`converterMap` 为 `ConcurrentHashMap` 且启动后只读，安全。无锁粒度问题。 |
| §14 功能完备性与 README 覆盖 | 1 | `dbmigro` 端到端不可用（#1）；README 对本部分涉及的 `QueryResultWrap`/`DummyTransaction`/`StatementWrap`/`DatasourceCreator`/`ORMConfig` 均已逐符号对照，无"README 承诺但代码没有"的其它项。 |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md` 文件，§13 无审查对象；对 part7 涉及符号抽查了 `README.md:185/236-241/386/545/2191-2194` 与 `README_en.md` 对应段落，未发现与本部分代码相反的表述（`orm_pooledDatasourceMaxLifeTime` 这类反直觉键名 README 已显式说明，不算漂移）。 |

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：`InputStreamSqlArg` 等值（#1）、`SqlArgs` 键语义（#2）；安全性：参数原文进日志（#3）；设计：三处分派表（#5）。语言特性已核对 `protected` = 模块内可见（`class.md:370-375`）、`TypeInfo.of(Any)` 取运行时类型（`reflect_package_classes.md:13524-13572`，故 `SqlArg.cj:30` 的诊断信息无缺陷）、`Array<T> ==` 为逐元素相等（`core_package_structs.md:2772-2790`） |
| §1 死代码 | 4 | 逐个 `private`/`internal`/`protected` 符号搜引用：`ByteSqlArg` 别名、`SqlArgs` protected 主构造、`SqlArgs.add(all!)` 链（其唯一调用者 `SqlExecutor.add(all!)` 也零调用）无引用 → 死代码；`std.ast.*` 未使用 → 死 import。`SqlArg` 为 `public abstract class`，其 `protected` 成员（`setValue`/`toString`/`hashCode`/`equals`/`index`/`h`）按扩展点豁免；`SqlArg.new`、`TransactionWrap.isDummy`/`setXxx` 虽仓内零引用但对外可达（硬原则一），只记信息 |
| §2 重复逻辑 | 2 | 三张类型分派表（#5）+ `TransactionWrap` 的 setXxx 与 mut prop（#8）；已逐个比对 `SqlArgs.add` 20 个重载（差异仅类型名）、`SqlArg` 20 个子类（差异为 `Float16→Float32`、`BigInt→String`、`ByteArray` 字符串哈希、`InputStream` 忽略值四处），并点名差异后给出合并建议 |
| §3 空实现 | 1 | `StatementWrap.update(params)`/`query(params)` 恒抛（计入 #9，语义为「不可用实现」而非空函数）；测试桩 `RecordingStatement.setOption` 空实现属测试专用、有注释，不计 |
| §4 栈溢出 | 0 | 本部分无递归：`SqlArgs.toString` → `ArrayList.toString` → `SqlArg.toString` → 值 `toString` 是单向有限的；`TransactionWrap.wrapping` 是单链（`tx.wrapping = this.tx` 后 `this.tx = tx`，无环，`SqlExecutor.cj:198-238`） |
| §5 OOM | 1 | BLOB 参数被 `Array<Byte>.toString` 全量字符串化（#3 描述），量级约 4n 字符；无按不可信长度预分配、无无界容器增长（`SqlArgs.args` 随 `add` 增长，但每条 SQL 执行后换实例 `SqlExecutor.cj:104`） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，本部分未定位到任何自耗时占比；相关猜测已进「待验证假设」1-4 |
| §6.2 大粒度锁 | 0 | 本部分 7 个文件无 `synchronized` / `Mutex` / 锁对象；`SqlArgs.h` 是单实例记忆字段，无锁需求 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批处理 |
| §6.4 低效算法 | 0 | `SqlArgs.hashCode` 为 O(n) 但记忆化（每条语句一次）；`SqlArg.==` 先比缓存哈希再比字段（O(1)）；`ByteArraySqlArg` 的 O(n)+字符串化已作为 §7/§8 方案处理，不重复计 |
| §7 降堆内存方案 | 2 | 缓存键持有参数（方案 1）、`SqlArg` 每参数分配（方案 3）；均无基线 |
| §8 降 CPU 方案 | 2 | `ByteArray` 哈希字符串化（方案 2）、`SqlArg` 分配（方案 3）；均无基线 |
| §9 local mode 可行性 | 0 | 不可行：`SqlArg` 必然逃逸（存入 `SqlArgs` 字段、被 `SqlCacheKey` 长期持有、作为 `ArrayList` 元素跨函数传递），不满足 local region 的逃逸检查；且 `ArrayList<SqlArg>` 的接口元素仍需装箱，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 6 | #1 等值/哈希（严重）、#2 键语义、#3 日志与字符串化、#6 `add(all!)` 的索引重复隐患、#9 接口恒抛、#10 测试断言不成立；已逐个核对 20 个 `set` 实现的类型实参与 `setValue` 契约（`Float16→Float32` 与 `BigInt→String` 为既定约定，见 `SqlArgBinding_test.cj:128`） |
| §12 并发安全与锁粒度 | 0 | 已给线程封闭证据：`SqlExecutor` 构造为 private、实例只由 `ThreadLocal<HashMap<String, SqlExecutor>>` 生产（`SqlExecutor.cj:44`、`113-131`），`SqlArgs`/`StatementWrap`/`TransactionWrap` 都随 executor 线程封闭；未发现跨线程共享路径，故无「缺同步」可报 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；7 个 `.cj` 的对外声明与 README §19.2/19.3 逐项对照未发现「承诺未实现」（`StatementWrap` 参数版恒抛、`DummyTransaction` 空实现均在 README 第 2192/2194 行明写）。README 侧的不一致见「范围外提示」 |
| 文件覆盖（§13 等） | 7/7 | 清单 7 个文件全部读完；本部分不含 `.md`，文档一致性只能核对到 README 的跨部分条目（见范围外提示） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 15 |
| 一般 | 60 |
| 轻微 | 67 |
| 其中存量 | 139 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分只有一个文件，但它是 `f_orm` 的"对外契约本体"——2227 行、覆盖 19 个章节，粒度细到函数签名与异常文案，绝大多数条目与源码能对上（我逐条核对了 `ORM` 的重复注册行为、`SqlExecutor` 的缓存与日志收尾、5 种事务钩子顺序、`UPDATE` 三条异常消息、`StatementWrap` 的废弃方法、异常继承树、8 个方言与 4 个 `SchemaFinder`，均一致）。这说明文档是跟着代码维护的，不是一次性产物。

问题集中在四处，且都是"文档比实现乐观"：

- **阻塞项（建议先修）**：#1 —— `execute{ (result, false) }` 在配置了 `orm_transactionRollbackFor` 的环境下会被**提交**。这是"调用方要求回滚、框架提交"的数据错误，而 README 516 行明确承诺回滚、514 行又承认提交，自相矛盾。修法应是让 `false` 走独立回滚分支，不参与异常分类。
- **口径错误（会误导运维/安全评审）**：#3 声称内嵌敏感信息运行期不用（实际 `Config.getString` 会回落到 `sensitiveMap` 并解密）；#4 的 `orm_sm4*` 键名根本不被读取、§3.5 的 `sm4*` 常量不存在、"全局名不会被原样内嵌"与宏相反。这三条合起来会让"敏感信息内嵌 + SM4"这个特性既不敢用、也不会配。
- **文档主推但实现坏掉的能力**：#5 `:{a.b.c}` 数据路径绑定（循环条件用了过期 token，必失败）、#6 `Iterable<Data>` 集合展开（占位符翻倍）。两者都在 §8「模板 SQL」的核心卖点上，建议要么修实现，要么在 README 上明确降级。
- **排期项**：#2 `isReadOnly` 粘滞（钩子拿到错误读写标记）、#8 `Nested` 无外层事务时实际开真事务、#9 `Pagination` 未声明 `size > 0` 导致除零。三条都是"平时不响、边界上错"的类型，修复成本低。

文档质量本身：注入相关的口径写得克制且正确（§5.1 全参数化、§11.5 把 `argInSql` 的风险、字符串引号、`?` 误用逐条列清），§13.6 对 BLOB 与驱动流的事实核查（标注了实测日期与驱动清单）也是同类文档里少见的严谨。真正需要的是把这四处"文档超前于实现"的地方对齐，而不是重写。

存量缺陷共 12 条（严重 1 / 一般 8 / 轻微 3），是否纳入修复待用户决定；本报告只读代码与文档，未做任何修改。

**第 2 部分**：本部分是全模块里「最薄」的一片：一个 18 行的门面、一个编译期敏感信息宏、两条参数绑定护栏用例，外加 10 个 `.md`。因此**没有**执行器生命周期、连接/事务、锁粒度层面的实现可供审查——这些风险在 `base/SqlExecutor.cj`、`wrap/*` 等其他部分；本部分的实际产出是「把文档当作契约去核对」，而问题恰好集中在文档：

- 最值得先改的是 **#2 与 #3**：README 关于 `isReadOnly` 与敏感信息的两段说明都与代码相反（前者把「select 后置 true」说成「恒 false」，后者把「`sensitiveMap` 兜底」说成「运行期不读」），前者还会掩盖一个真实的行为缺陷——`readOnly` 置 true 后永不复位，写事务会被当作只读事务交给 `beforeCommit`（该缺陷在 `base/SqlExecutor.cj`，属其他部分，本报告只作范围外提示）。文档口径不改，下一轮审查还会被同一段误导。
- **#4** 是纯覆盖缺口但影响运维：两个「保护性上限」（连接卡在 `Connecting` 的 5s、池耗尽的 30s）是线上卡死时唯一的旋钮，两版 README 都查不到。
- **#1** 是测试卫生里的潜伏项：`MOCKDB.execution` 是进程级单例且 `clear()` 明确不重置它，`clearExecution()` 又是包内可见，`f_orm` 用例只能覆盖不能还原。当前每个真正执行 SQL 的用例都自己重设夹具，所以还没翻红；但「下一个忘了设夹具的用例静默继承别人的结果集」这类失败极难定位，且同模块还有 10 处同样写法，建议一次改成「夹具作用域」。
- **#5-#8** 是宏与用例的清扫项（未使用 import、护栏只覆盖 16/20 标量分支与 2/20 `?T`、只验占位符不验绑定、计时断言可能抖动）；#9-#11 是文档细节（示例注释、版本/依赖头、审计文档过期）。这 7 条都不影响运行，随下次触碰顺手改即可。
- 明确**没有**命中的维度：死代码（本部分无 `private`/`internal`/`protected` 声明，唯一命中是未使用 import）、重复逻辑（两处测试辅助按误报边界不计）、空实现、栈溢出、OOM、锁与并发串行、local mode（唯一候选已被同模块 spec 用探针否决）。
- 两个 spec 目录（`fix-orm-queryresultwrap-type-alias`、`test-f-orm-update-column-keys`）与当前实现逐条自洽，未发现规格漂移；`优化方案.md` 只有一处已完成项未打勾（#11）。

存量缺陷共 11 条（严重 0 / 一般 3 / 轻微 8），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

**第 3 部分**：本部分是 `f_orm` 的 **SQL 片段构造层**，没有连接池、事务、锁，但它是全模块参数绑定的唯一出口：`Column.toString()` / `CmpExpr.toString()` / `MeetCondition.done()` 都在「字符串化」阶段把值塞进线程内 executor 的 `args`。把「求值」和「绑定」揉进 `toString()` 是这一层所有问题的共同根因，也是最值得优先动的一处结构性改造。

- **阻塞项（3 条严重）**：#1 `ParenExpr` 对子表达式求值两次，`AND/OR/NOT` 的 lambda 变体（DAO DSL 的公开写法）会得到「2 个占位符 / 4 个参数」或参数错位；#2 `BETWEEN` 混合 `Column` 与常量时把 `Column` 当字符串值绑定，静默查错数据；#3 `DirtyTag` 把「是否开启脏跟踪」放在全局、把脏字段放在线程内，`clearAll` 只清当前线程，并发下会丢更新，`UPDATE ... dirty` 可能一条 SQL 都不发。三条都只需局部改动（一次求值、操作数分流、开关下放到 `ThreadLocal`），但都需要补用例才能防回归。
- **契约面缺陷（#4–#8）**：`ChooseCondition` 的片段型 `partial` 与缺省 `otherwise` 在默认模式下必然多绑参数（#4）、`LoopCondition` 的 `Int64` 形参不是下标（#5）、`IN`/`loop` 空集合生成 `in ()` 且元素数无上限（#6）、`NullableGroupedQueryMapper` 的 `None` 兜底是死分支（#7）、`InExpr` 绕过引用与表别名（#8）——都是「写得出来、跑起来错」的形态，且有 4 条属于「同族实现已经写对，只有这一处漂移」，修法明确。
- **生命周期与内存（#9–#10）**：executor 的线程内 `current` 与「语句结束即 `close()`」是本模块的既有约束（基线 §2 明写），但构造层把参数绑定藏在 `toString()` 里，违反约束时没有编译期或运行期的明确报错；`partials` 缓冲在字符串拼接路径上只增不清，长事务里会随语句数累积。这两条不一定会立刻出错，但会把「偶发参数错位」变成不可复现的线上问题。
- **并发与单例状态（#13 / #3 / #24）**：`Columns` 是 `static let instance`，`tableAlias()` 直接改它的字段，别名会粘滞到后续所有查询并跨线程串扰。这类「给下游埋的坑」目前仓内零调用，所以没有任何用例能暴露它。
- **可维护性（#14–#24）**：两套 `AND/OR/NOT` 枚举、`SET` 重复实现 `WHERE` 的模板、复制粘贴的异常文案、`String` 的 `AND` 属性带隐式全局副作用、`ChooseCondition` 的重载歧义（测试注释自证）、`DAO_test.cj` 整文件注释 + 一条已死的替身链——单条都不重，但合起来是这一层「读代码比读文档更可靠」的原因。
- **未确认项**：宏生成的 `GroupedQueryMapper(name: ...)` 与本部分构造器形参不一致（范围外提示 1），一旦有实体类出现 `ArrayList<实体>` 字段就会编译失败，需要第 4/5 部分确认；Oracle / DB2 没有 `lastInsertId` 实现（范围外提示 2）需要 README 侧确认是否为已知限制。
- **性能与内存**：本部分没有任何改前/改后数据，1 条堆内存方案与 1 条 CPU 方案都标「无基线（待验证）」，4 条假设不进修复清单。下一轮最值得先补的是假设 1（事务内 `partials` 增长）——它同时决定 #10 的修复优先级。

**第 4 部分**：本部分的代码质量呈"两段式"：`SqlExecutor` / `QueryResultIterator` 明显经过一轮 bug.md 修复，`activeQueryResult` 三态、`handedOver`、`Statement` 所有权移交、`clearSql` 换实例这些细节都有注释和用例钉住，异常路径的资源释放核对下来是自洽的；问题集中在**没有被用例覆盖的旁路**——子类型映射（`QueryMappers.create`）、SQL DSL（`setSqlFromObject` / `setSqlFromMap` 全仓零调用）、事务内结果缓存，以及几处"状态位只置不复位"（`readOnly`）和"线程内单槽"（`current`）。

阻塞项建议按此顺序处理：#1（继承映射必崩）、#2（集合参数占位符翻倍，DSL 一用就错）、#3（缓存返回共享可变实例，事务内读到脏副本）。三者都属于"下游一用就出事、仓内没有用例"的类型，修完应各补一条回归。其余一般项可以排期：#5 / #6 / #7 是状态机与生命周期的小修，#8 / #9 / #10 / #11 / #12 / #13 是边界与降级语义，#15 需要先确认 `clearArgsAfterExec: false` 的真实时序。

死代码与重复逻辑各有一处集中点（`Partials` 的 10 个死成员、三份 40+ 类型分派表），清理成本低但要连同 `ExtendString` 的重复实现一起决策，建议在第 3 部分 #21 的结论出来后一并处理。

存量 22 条，是否纳入修复待用户决定。

**第 5 部分**：本部分代码的**主线是链式 DSL 的字符串拼接与事务钩子的分发**，质量不均衡：`SqlPartial`/`TableClause` 的骨架清晰、参数绑定纪律好（全部 `arg()` 占位符，未见注入）、`Partials` 与 `Condition` 两层各司其职；但字符串拼接的边界处有三处成体系的缺陷（#2 的 SET 逗号、#3 的 ORDER BY 空格、#4 的 trim 正则），它们的共同点是"单列/连续列/已裁剪输入"的用例能过，一旦输入形状变化就生成非法 SQL，且没有一条用例守住——本部分的 5 个含用例文件里，没有一个覆盖 `ORDER_BY` 多列或 `UPDATE` 缺列。

**阻塞项**是 #1：`TransactionHook.inTx()` 是从接口到 README 都承诺了的扩展点，实际零调用、零转发，属于"静默失效的公开钩子"，用户代码放进去的上下文绑定/审计永远不会执行；它和 #5（`order` 不生效）叠加后，事务钩子这一整块的可信度都需要重新建立。建议这两条先修，再补一组钩子顺序与触发时机的用例（当前 `TransactionHook` 在仓内没有任何测试）。

**可排期**：`TableMeta`/`TableMetas` 的静默降级（#7）与 `comment` 未接线（#9）属迁移链路，影响面是"建表少列/注释丢失"，建议在动 `migro` 前先修；#8（无列可更新时静默 return 0）、#10（分页参数未校验，构造期抛 `ArithmeticException`）、#11（子句复用后 SQL 带着残留 LIMIT、参数已被清空）修起来都只要几行。重复逻辑（#18）与测试替身外泄（#15）属维护性债务，可随下一次重构一起收。

**未做的部分**：本部分未跑构建与用例（只读审查），所有结论均基于源码；两条性能优化与三条热点假设都没有基线数据，仅作下一轮取证清单。另有两处**范围外提示**（不计入统计）：①`SqlExecutor.waitConnecting()`（`SqlExecutor.cj:400-409`）虽已加超时，仍是**无 sleep 的忙等**，卡在 `Connecting` 的最长 5 秒会烧满一核，与 `SqlExecutorConnectingTimeout_test.cj` 钉住的超时路径叠在一起；②`SqlExecutor.setSql(clearArgsAfterExec: false)` 会把 `clearArgsAfterExec_`（`SqlExecutor.cj:57/872`）留在 `false`，`clearSql()` 的默认参数因此长期偏"不清参数"，`selectPage` 靠显式 `clearSql(clearArgsAfterExec: true)` 兜住——这两处都在第 4 部分的文件里，留给该部分与主 Agent 复核。

**第 6 部分**：本部分代码分两块，质量差异很大。

`src/exception`（14 个文件）是纯样板：13 个异常类各 4 个转发构造，层次清楚，`imports.cj` 的整包重导出只为 `SqlArgException` 服务、且该类越级继承了 `BaseException`，是仅有的两处口径不一致，属可排期的小整理。

`src/macros` 的四条宏是本模块抽象度最高的地方，能跑通「内层 `@ORMField` 先展开 → 外层 `@QueryMappersGenerator` 收消息」的正确链路（符合 `implementation_of_macros.md:532-537` 的由内向外展开顺序），但**失败路径几乎全靠静默**：属性缺值抛越界、`dirty` 注入吞异常、多 token 类型静默不打脏标记、非法列名把错误推到生成代码里。这些不阻塞主流程，但让误用极难定位，建议统一走 `diagReport`。

真正需要优先处理的是 `src/migro` 两个方言实现——它们承载 README §16 承诺的整套迁移能力，却**没有任何连库测试**（`migro_test.cj` 只断言 DDL 字符串，`listTables`/`findTableSchema`/`findIndexes` 零覆盖）。四条严重问题全在这里：查询 PO 与结果集列集/类型不对齐（6 个取库方法必然抛异常）、`resource` 内交出懒迭代器导致结果集在关闭后被消费、列改名同时生成 `rename` 与 `add column` 的自相矛盾 DDL、Postgres 新索引 `def` 恒空只产出 `";"`（唯一约束静默不建立）。四者叠加意味着这条迁移链路当前不可用，且其中最后两条会**静默**产出错误/缺失的 DDL，属于阻塞项。

建议顺序：先补一条真库冒烟测试（建表 → 迁移 → 再迁移应为空 diff）把四条严重问题钉住，再统一 `esc`/`indexColumns`/`generateDropTableSql` 的重复实现，最后处理宏的静默失败与注释过期。

**第 7 部分**：本部分的风险高度集中在 `src/migro/`：**整条迁移链路当前是空转的**——入口 `groupBy` 恒返回空 map（根因在 `f_base`，已由该模块报告覆盖），导致 `dbmigro` 一条 SQL 都不生成却返回成功；就算修好这一处，`use <db>;` 也会因为逐语句新建/关闭 executor 而失效（多库场景把 DDL 打到默认库），失败语句还会被就地吞掉、退出码仍是 0。这三点构成一个完整阻塞项：迁移功能在端到端意义上不可用，且没有任何用例覆盖 `generate()` 这一层（现有 15 个用例只测 DDL 字符串生成）。建议按 #1 → #3 → #2 的顺序修，并把"`generate` 至少产出一条 SQL""失败必须非 0 退出"写成用例。

`src/wrap/` 侧质量明显更好：`QueryResultWrap` 的类型映射虽然有 700 行矩阵、且与 `toMap()` 存在已实现的漂移（`SqlByte`），但取值语义、流所有权（`hadStream`）、异常文案都有明确的 bug 编号与用例护栏；真正的结构性欠债是"同一份 typeName 在取数与 `toMap` 两处各写一遍"（设计文档自己也承认）。`ORMConfig` 的主要问题是错误处理策略不一致（一半配置项退回默认、一半直接抛），这在启动期是可观察的行为差异，但不是崩溃级缺陷。`DataType` / `ConnectionWrap` / `DummyTransaction` / `DatabasePool` 属薄壳或宏驱动，未发现问题。

死代码只有一处：`wrap/NoneConnection.cj` 与 `base/NoneConnection.cj` 逐行重复且全仓零引用（`SqlExecutor` 引用的是 base 包那份）——留在 `wrap` 包里是个隐形陷阱（同包内写 `NoneConnection.instance` 会拿到另一个类型，`is NoneConnection` 状态判断会失效）。建议直接删除该文件。

存量缺陷共 20 条（2 严重 / 6 一般 / 12 轻微），是否纳入修复、按哪个优先级排期，请用户决定；本报告不改源码、未跑构建，全部结论来自静态阅读 + 官方文档核对。

**第 8 部分**：本部分是 ORM 的「参数绑定 + 事务/语句包装」薄层，代码量不大，但**参数对象同时承担了三种角色**：绑定数据、缓存键成分、日志文本来源。三者耦合正是三个实质问题的根源：流参数按「不可比较」处理，却仍被拿去做缓存键（数据错误，唯一严重项）；可变参数对象被缓存键强引用，`refEq` 又让身份等同内容，ORM-1 的修复只在默认路径成立；`toString` 同时服务日志与异常消息，把参数原文和整块 BLOB 一起带出。

阻塞项只有第 1 条（流参数缓存命中会返回上一次的行），修法明确、改动局部（`InputStreamSqlArg` 的 `==`/`hashCode` 或给 `SqlArg` 加 cacheable 标记）。第 2 条需要在合并模块报告时与 `base/SqlExecutor.cj` 的缓存实现一起看，属「按事务边界设计的缓存」被 `clearArgsAfterExec:false` 打开的口子。其余 7 条为死代码、重复逻辑与测试质量问题，可排期。

存量 10 条（严重 1 / 一般 2 / 轻微 7），是否纳入修复待用户决定；本部分未做任何源码修改。

**范围外提示**（不占本轮统计）：①`f_orm/README.md:2190` 仍写 `SqlArgs` 有 protected `clone()` / `clear()`，源码中这两个成员已删除（`SqlArgs.cj:23-25` 注释说明删除原因）；②`f_orm/README.md:2201` 与 `README_en.md:2388` 称 `arg(...)` 即 `SqlArg.new<T>`，实际 `RootDAO.arg` 走 `SqlExecutor.add` → `SqlArgs.add` 重载，`SqlArg.new` 无任何调用；③`base/SqlExecutor.cj:907-918` 命中缓存时直接返回同一个 `ArrayList` 实例，调用方修改返回值会污染缓存（属 base 部分）。
