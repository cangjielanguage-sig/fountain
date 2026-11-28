# f_orm 模块审查报告

> **模块第 1/8 部分**（本报告只覆盖 `files/f_orm.part1.txt` 列出的 1 个文件：`f_orm/README.md`。模块内其余 111 个 `.cj` 与 10 个 `.md` 由第 2–8 部分产出；本部分为取证而抽读的实现代码不计入文件覆盖与统计。）

- **审查日期**：2026-11-28
- **模块路径**：`f_orm`（本部分 0 个 `.cj` + 1 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x` 工作区，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：README 与实现的契约一致性（executor 生命周期 / 线程内复用、连接与事务语义、参数绑定与注入口径、配置项完整性）；按要求顺带核对实现以取证，不展开源码级审查
- **报告版本**：v1（第 1/8 部分）

## 发现

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

## 优化可行性方案

本部分只有 `README.md`，不含可执行路径，因此不产出性能 / 内存优化方案（§7 / §8 / §9 的候选留给第 2–8 部分的 `.cj` 审查）。

## 待验证假设

> 本部分为文档审查，无性能测量数据可用，也没有"疑似热点"可提。下列一条是文档承诺可能带来的运行期开销线索，仅用于下一轮补数据，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README §8.1 的 DSL 编译缓存（`HeapCache(maxLife: 1 天, maxSize: 10000)`）在"动态拼接 DSL 文本"的调用方式下命中率可能很低，导致每次都重新 `cangjieLex` 解析 | `f_orm/src/base/SqlDSL.cj:45-47`、`README.md:829` | 缓存命中率、单次 `compile()` 耗时占比 | 在 `dslcache.getOrCompute` 前后加命中/未命中计数，跑 10 分钟稳态负载；`cjprof record` 看 `compile` 自耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_orm/README.md` | .md | ✅ | 2227 行全读；与实现核对后见 #1–#12（事务 false→提交、`isReadOnly` 粘滞、敏感信息取值链、SM4 配置名、DSL 路径与集合展开、两个未文档化配置项、`Nested` 语义、`Pagination` 约束、`SqlArgs` 成员、`arg`/`add` 措辞、`UPDATE` 示例注释）。注入口径（§11.5 `argInSql`）与实现一致，未计问题 |

合计：`.cj` 0 个 / `.md` 1 个 / 共 1 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分只有一个文件，但它是 `f_orm` 的"对外契约本体"——2227 行、覆盖 19 个章节，粒度细到函数签名与异常文案，绝大多数条目与源码能对上（我逐条核对了 `ORM` 的重复注册行为、`SqlExecutor` 的缓存与日志收尾、5 种事务钩子顺序、`UPDATE` 三条异常消息、`StatementWrap` 的废弃方法、异常继承树、8 个方言与 4 个 `SchemaFinder`，均一致）。这说明文档是跟着代码维护的，不是一次性产物。

问题集中在四处，且都是"文档比实现乐观"：

- **阻塞项（建议先修）**：#1 —— `execute{ (result, false) }` 在配置了 `orm_transactionRollbackFor` 的环境下会被**提交**。这是"调用方要求回滚、框架提交"的数据错误，而 README 516 行明确承诺回滚、514 行又承认提交，自相矛盾。修法应是让 `false` 走独立回滚分支，不参与异常分类。
- **口径错误（会误导运维/安全评审）**：#3 声称内嵌敏感信息运行期不用（实际 `Config.getString` 会回落到 `sensitiveMap` 并解密）；#4 的 `orm_sm4*` 键名根本不被读取、§3.5 的 `sm4*` 常量不存在、"全局名不会被原样内嵌"与宏相反。这三条合起来会让"敏感信息内嵌 + SM4"这个特性既不敢用、也不会配。
- **文档主推但实现坏掉的能力**：#5 `:{a.b.c}` 数据路径绑定（循环条件用了过期 token，必失败）、#6 `Iterable<Data>` 集合展开（占位符翻倍）。两者都在 §8「模板 SQL」的核心卖点上，建议要么修实现，要么在 README 上明确降级。
- **排期项**：#2 `isReadOnly` 粘滞（钩子拿到错误读写标记）、#8 `Nested` 无外层事务时实际开真事务、#9 `Pagination` 未声明 `size > 0` 导致除零。三条都是"平时不响、边界上错"的类型，修复成本低。

文档质量本身：注入相关的口径写得克制且正确（§5.1 全参数化、§11.5 把 `argInSql` 的风险、字符串引号、`?` 误用逐条列清），§13.6 对 BLOB 与驱动流的事实核查（标注了实测日期与驱动清单）也是同类文档里少见的严谨。真正需要的是把这四处"文档超前于实现"的地方对齐，而不是重写。

存量缺陷共 12 条（严重 1 / 一般 8 / 轻微 3），是否纳入修复待用户决定；本报告只读代码与文档，未做任何修改。
