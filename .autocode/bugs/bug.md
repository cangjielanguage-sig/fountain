# 代码审查报告：f_orm / f_mvc / f_bean / f_aspect

- 审查分支：`review/orm-mvc-bean-aspect`（基线 `5a5d6cf3`，即 `sts/1.3.x` 现值）
- 审查范围：4 个模块、183 个 `.cj`、19706 行（f_orm 11587 / f_mvc 5044 / f_bean 1939 / f_aspect 1136），逐文件通读
- 审查依据：`cangjie-code-review`（性能优化 14 节 / 内存优化 11 节）；结论以「瓶颈证据 + 调用频率 + 功能等价」为准，未做实测的项一律标注
- 复核口径：所有「高」级问题**已回到源码逐行复核**（行号见各条），下面每条都标了证据与影响面
- 同目录另有两份归档报告（`bug-archived-20261004-2.md`、`bug-archived-on-20261004.md`），本文件是**当前活动报告**

## 0. 摘要

| 模块 | 高 | 中 | 低/待验证 | 其中最该先动的 |
|---|---|---|---|---|
| f_orm | 2 | 5 | 11 | 结果缓存键退化为 SQL 文本（可能静默返回别的参数的结果） |
| f_mvc | 3 | 5 | 14 | 静态资源缓存无界（含 404 负缓存）；WS ping Timer 不随连接退出取消 |
| f_bean | 1 | 4 | 7 | 宏生成的 `lookupSet` 不存在（`HashSet` 形参直接编译失败） |
| f_aspect | 5 | 4 | 7 | 拦截器链把「首次调用的接收者 + 参数槽」烧进静态缓存；两条规则恒不匹配/越界崩溃 |
| 跨模块 | 1 | — | — | `f_base.TypeInfos.get(String)` 无限递归（波及 f_aspect/f_bean/f_orm 共 14 处调用） |

**建议修复顺序**（按「静默错误/崩溃 > 资源泄漏 > 热点开销」）：

1. `ORM-1` 结果缓存键退化 —— 事务内可能返回**别的参数**的查询结果（静默错数据）
2. `A-1`/`A-2` 切面链缓存绑定首次调用的 `fn` 与共享 `funcInfo.args` —— 多实例下在**错误对象**上执行方法体、并发下参数互相覆盖
3. `X-1` `TypeInfos.get(String)` 无限递归 —— 条件装配（f_bean）与 3 类切面规则（f_aspect）不可用
4. `A-4`/`A-5` 参数注解规则越界崩溃 / `ArgAnnotationsRouteRule` 恒不匹配
5. `MVC-1` 静态资源缓存无界 + 404 负缓存 —— 每个不存在的路径都建条目
6. `MVC-3` WS ping Timer 泄漏 —— 每断一条连接泄漏一个周期任务 + 捕获整条上下文
7. `MVC-4` `download` 输出整块 1024 字节缓冲 —— 下载内容带脏数据
8. `BEAN-1` 宏生成不存在的 `lookupSet` —— `HashSet`/`Set` 形参的 bean 编译失败

---

## 1. f_orm

### 1.1 结构小结

`base`（`SqlExecutor` 执行器 + SQL DSL + 分页/事务/DAO 基座）、`wrap`（驱动包装：连接/语句/事务/结果集/参数 + `DatabasePool` + `ORMConfig`）、`macros`（`@QueryMappersGenerator`/`@ORMField`/`@DAO` 代码生成）、`migro`（MySQL/PostgreSQL schema 对比迁移）。热路径：`SqlExecutor.execute` → 拼 SQL → 取连接 → `prepareStatement` → `QueryResultWrap` 逐单元格取值 → `QueryMappers` 逐行映射。

### 1.2 高危

#### ORM-1 [高｜正确性+性能] 结果缓存的键退化成「只有 SQL 文本」✓已复核

位置：`src/base/SqlExecutor.cj:25-39, 840-849`、`src/wrap/SqlArgs.cj:106-120`

```cangjie
// SqlExecutor.cj:48    private var args: SqlArgs = SqlArgs()     // executor 自己的字段
// SqlExecutor.cj:841   let key = SqlCacheKey(sql, args)            // 存/取用的是同一个实例
// SqlExecutor.cj:28    h = HashBuilder().append(sql).append(args).build()   // 只在构造时算一次
// SqlArgs.cj:106-117   private var h = 0; public func hashCode() { if (h == 0) {...} h }   // h 被记忆，clear()/add() 后不复位
// SqlArgs.cj:118-120   operator func ==(other) { refEq(this, other) || args == other.args }  // 同一实例恒等
```

影响：同一个 executor 上，**SQL 文本相同、参数不同**的两次查询会被判为同一个缓存键。

- 事务内执行器**不关闭**（`SqlExecutor.cj:830-832` 在事务分支直接 `return executor()`，不走 `close()`）⇒ 缓存不失效 ⇒ 一个事务里同一 SQL 文本的第二次调用**直接返回第一次的结果**（静默错数据）；若两次期望的 `T` 不同，则抛 `type of cached data with key ... does not match`（`844`）。
- `orm_useCache` 默认 `true`（`SqlExecutor.cj:62`），即默认路径就有这个风险；典型触发是「事务里按不同 id 循环取数」。
- `README.md:384-389` 写的是「键基于 SQL 与参数」，实现与文档不符。
- 附带：`h` 记忆 + `clear()` 只换内部 list（`SqlArgs.cj:23-25`）⇒ 哈希桶也可能长期落在陈旧值上。

修法：`clear()`/`add()` 时把 `h` 复位为 0（或改为不缓存的增量哈希）；`SqlCacheKey` 应保存**参数快照**（不可变值列表）而不是活的 `SqlArgs` 引用。修完补一条 DT：同一 executor 上两次「同 SQL 不同参数」的查询结果必须不同。

#### ORM-2 [高｜性能] 逐单元格做运行时类型分派 + 字符串 `typeName` 匹配

位置：`src/wrap/QueryResultWrap.cj:46-107`（配合 `base/QueryMappers.cj:76-82`）

```cangjie
// QueryResultWrap.cj:47    let columns = result.columnInfos
// QueryResultWrap.cj:53-75 for (i in list.size..=index) { ... match(column.typeName){ case 'SqlChar'|'SqlVarchar'|... } }
// QueryResultWrap.cj:107   match(list[index]){ case x: T => x ... }   // 未命中再进 convertFromString 的 match 链
```

影响：`QueryMappers.map()` 对**每一行每一列**调用取值路径 ⇒ 调用频率 = 行数 × 列数，是模块内最热的代码。每个单元格都要：一次 `columnInfos` 属性访问、一次大 `match`（`Any` 类型判定）、未命中时又一次 `match(None<T>)` 链。

修法：构造 `QueryResultWrap` 时按列预算好「取值函数/类型标签表」，行循环里只做一次数组查表 + 一次 `as T`；把 `columnInfos` 在构造时取一次存字段（同时消掉 `L3` 的 O(n²) 风险）。

### 1.3 中危

- **ORM-3 [性能]** 每条**非事务** SQL 的 `close()` 都会全量清扫脏字段注册表：`SqlExecutor.cj:153` → `DirtyTag.clearAll()`（`DirtyTag.cj:66-79`）遍历**所有已注册 PO 类型**并逐个新建 `DirtyTag` 写回 `ConcurrentHashMap`。成本 = O(已注册类型数) 次哈希查找 + 等量分配，PO 越多单次查询固定开销越大（`SqlExecutor.cj:836` 每次执行都走 `close()`）。修法：只清「本轮被标记过」的类型，或把 `clearAll` 移出每条 SQL 的执行路径。
- **ORM-4 [性能]** 每次执行都重新 `prepareStatement`，且默认配置下每次借连接还额外执行一次 `select 1`：`SqlExecutor.cj:398`（`stmt.close()` 于 `878`，无语句复用）、`DatabasePool.cj:111-125` + `ORMConfig.cj:201-203`（`getCheckOnBorrowing` 默认 `true`）。修法：按 SQL 文本缓存 `Statement`；文档推荐 `orm_databasePoolCheckOnBorrowing=false`。
- **ORM-5 [性能]** 每次拼条件片段都「动态构造正则 key + 查缓存 + 生成临时串」：`Condition.cj:65-67`（`'^\\s*(${prefix})\\s*|...'.regex(flags:[IgnoreCase]).replaceAll(...)`）、`TableClause.cj:39-49`、`imports.cj:35-37`。这些函数被 `WHERE/AND/OR/NOT/HAVING/ORDER_BY/GROUP_BY/SET` 每次调用，即每构造一次动态 SQL 触发数次。修法：固定模式用 `static let` 的 `Regex` 常量；`trim` 用 `trimAscii` 手工裁剪。
- **ORM-6 [性能]** 批量条件 DSL 的循环体里按元素做大 `match` + `SqlArg` 分配 + 字符串拼接：`LoopCondition.cj:85-113`、`MeetCondition.cj:41-111`、`ChooseCondition.cj:76-116`；`IN`/批量 insert 的参数规模就是业务集合大小（可上千）。另见 `C7` 的安全面。
- **ORM-7 [性能]** `RootDAO.arg<I,T>(value)` 逐元素进入 40+ 分支 `match`：`RootDAO.cj:319-377`（`IN`/`NOT_IN` 于 `435-448`，`LogicalExpr.InExpr` 于 `175-181`）。上千 id 的 `IN` 就是上千次大 `match` + 两次对象分配。修法：把类型判定收敛为一次（或按静态类型分派）。

### 1.4 低危 / 待验证

- `ORM-L1` `SqlExecutor.cj:71-81`：`setSql` 每次做全串正则替换 + 两次 `trimAscii` + `[0..6]` 子串（见 `C5` 的越界），可换 `startsWithIgnoreAscii`。
- `ORM-L2` `SqlExecutor.cj:386-393, 859, 866`：每次执行都 `args.clone()`（实为共享，见 `C4`）并分配日志闭包，即使日志级别不输出。
- `ORM-L3` `QueryResultWrap.cj:26-32, 970-973`：`columnInfos` 在构造与 `toMap()` 中被重复访问（宽表 + `mapList` 放大）。**待验证**：各驱动 `columnInfos` 是否已是缓存数组。
- `ORM-L4` `SchemaFinderMediator.cj:30-36`：构造了从未使用的 `existingTableNames`（`67-70` 又建了 `knownNames`），死代码。
- `ORM-L5` `SqlDSL.cj:148-151`：`let fields = T.dataFields()` 求值后未使用。
- `ORM-L6` `SqlArg.cj:502-504`：`ByteArraySqlArg.hashCode` 用 `value.toString()` 格式化整个字节数组（BLOB 参数一次性等量大字符串峰值）。修法：长度 + 抽样字节。
- `ORM-L7` `DirtyTag.cj:26, 72-79` + `SqlExecutor.cj:44-45`：`clearAll()` 只清**调用线程**的 `dirtyFields`；`currents/current` 只在 `close()` 时 `remove`，异常路径不 close 时保留到下一次覆盖。线程池 + 多 PO 类型下 ThreadLocal 持有整组字段名集合。
- `ORM-L8` `DatabasePool.cj:210-228`（配合 `f_pool/BasePool.cj:44-46`）：`PooledConnection.close()` 不校验 `assigned`，无条件 `returnFn(this)`，**待验证**池是否有身份去重（若无，重复 close 会让两个借用者拿到同一连接）。修法：`close()` 首行 `if(!assigned){ return }`。
- `ORM-L9` `SqlExecutor.cj:366-385`：`connection` getter 在 `Connecting` 状态用 `while ... continue` 忙等（无 sleep/yield/超时），**待验证**驱动是否会出现长时间异步建连。
- `ORM-L10` `TrsactionHooks.cj:53-58`：每次注册都对整个列表 `sort`，且只增不减、无注销 API（启动期调用，影响有限）。
- `ORM-L11` `ORMConfig.cj:94-113`：`getOption/getAllOptions` 每次复制一份全局配置 Map 并对每个 key 做 `replace`（启动路径）。

### 1.5 正确性缺陷

- **ORM-C1 [高]** `iterator`/`singleIterator` 在**返回前**就把结果集关掉了：`SqlExecutor.cj:473-482`/`533-537` 在 `execute<Iterator<T>>` 里构造迭代器，而该重载的 `finally` 是 `r?.close()`（`904-906`），同时 `activeQueryResult` 立即复位（`919`）。`f_mockdb` 的 `QueryResult.close()` 是空实现（`f_mockdb/src/QueryResult.cj:53-56`）所以单测看不出来；**待验证**：真实驱动（postgres/mysql）下 `close()` 后 `next()` 的行为。修法：`iterator*` 路径不走 `finally close`，把所有权交给返回的迭代器。
- **ORM-C2 [中]** `SingleColumnIterator` 忽略 `column` 参数：`QueryResultIterator.cj:34-46` 只用 `index` ⇒ `singleIterator<T>('name')` 实际读第 0 列（README 已记录为已知问题）。
- **ORM-C3 [低]** `SqlArgs.clone()` 不是快照：`SqlArgs.cj:26-28` 直接共享同一 `ArrayList`，日志路径之后再 `add` 会污染已传出的「副本」。
- **ORM-C4 [低]** 无长度保护的 `[0..6]` 切片：`SqlExecutor.cj:77`（SQL 短于 6 字符越界）、`DatabasePool.cj:112`（`checkSql` 配短于 6 字符越界）；对比 `SqlPartial.cj:288` 有 `size >= 8` 保护。
- **ORM-C5 [中｜安全]** `argInSql` 把任意 `ToString` 值原样拼进 SQL：`LoopCondition.cj:99`、`MeetCondition.cj:80-81/100-101/124-127`、`ChooseCondition.cj:86/97`。传 `String` 时绕过参数化 ⇒ 注入/语义错误面。修法：仅允许列名并白名单校验。
- **ORM-C6 [低｜待验证]** `InputStreamSqlArg`（`SqlArg.cj:426-448`）把流交给驱动后模块内不关闭；`QueryMapperConverter.cj:48-50` 的 `StringReader(x).readToEnd()` 未关闭。需确认所有权约定。

### 1.6 已确认「无实例」的维度

无 CFFI `malloc/free` 不对称、无 `acquireArrayRawData/releaseArrayRawData`、无 `spawn`/显式锁（并发仅靠 `ConcurrentHashMap`/`ThreadLocal`/`AtomicUInt64`，故不涉及锁范围与 spawn 粒度）、无无界对象池（`DatabasePool` 受 `maxSize`/`connectionLife` 约束）、无 Future 历史堆积、无循环内逐项 IO/日志、无循环内 `clone()`/临时大集合、无 String↔Rune/Byte 反复转换热点。资源释放总体规范（`SqlExecutor` 在 `finally` 关闭语句与结果集、`migro` 用 `resource(...)`），例外见 `ORM-C1/C6`。

---

## 2. f_mvc

### 2.1 结构小结

请求链路：`HttpRequestDistributorImpl.distribute`（`57`）→ `PathPattern` 查表 → `MultiRequestMethodHandler.handle`（method/Content-Type 两级 `HashMap`）→ 宏生成的闭包（`macros/Controller.cj:78-101`）→ `RequestMeta.checkAuth/extract/respond`。**路由表在注册期构建、请求期只查表**（`f_util/src/PathPattern.cj:153` + `MultiRequestMethodHandler.cj:37-54`），这部分设计是对的。每请求热点：路径查表、参数抽取、`AuthHandlerProxy.check`、`accessLog`、`OverallStopwatch`、`BeanFactory.getFirst`。

### 2.2 高危

#### MVC-1 [高｜内存] 静态资源缓存无界，且「不存在」也会建条目（负缓存）✓已复核

位置：`src/RequestMeta.cj:24, 96-124`

```cangjie
// RequestMeta.cj:97    staticResourceBytes.entryView(path){view => ...
// RequestMeta.cj:113-119  view.value = if(let Some((last,_)) <- view.value && last < lastModified){ (lastModified, File.readFrom(p)) } ...
// RequestMeta.cj:122  }else{ view.value = None }     // 文件不存在：照样落一个条目
```

影响：键来自**请求路径**，无容量上限、无 TTL、无淘汰；命中后整文件 `Array<Byte>` 常驻。任何扫 404 的流量（爬虫、探测）都会以「每路径一条」的速度让这张表增长，并且 404 也会建条目。修法：改成有上限的 LRU/TTL 缓存，且只在「存在且为普通文件」时写条目（不存在不要落盘）。

#### MVC-2 [高｜性能] `accessLog` 每请求无条件序列化全部参数与返回值 ✓已复核

位置：`src/RequestMeta.cj:519-553`（调用点 `macros/Controller.cj:97` 的 `finally`）

```cangjie
// RequestMeta.cj:530   case x: ToData => return f_data.convert<JsonValue>(x.toData()).getOrThrow().toString()
// RequestMeta.cj:537-545  let argGen = StringGenerator().append('['); for (arg in args) { ... anyToString(arg) ... }
// RequestMeta.cj:546-549  let result = match (returned) { case Some(x) => anyToString(x) ... }   // 返回值再来一遍 JSON
// RequestMeta.cj:550   let log = LoggerFactory.getLogger<T>()
```

影响：`argGen`/`result` 在 `logContent` 闭包**之前**就算好了（闭包只推迟最后一次拼接）⇒ 即使日志关闭，每请求也要付出：全量参数序列化 + 返回值二次 JSON 序列化（`ToData` 分支）+ 一次 `LoggerFactory.getLogger<T>()`。修法：把两段构造移进 `logContent`，或先判 `log.isInfoEnabled`；logger 用类静态字段（`RequestMeta.cj:21` 已有 `log`）。

#### MVC-3 [高｜内存] WS 的 ping `Timer` 只在收到 Close 帧时取消 ✓已复核

位置：`src/WSMeta.cj:158-168, 196-242`

```cangjie
// WSMeta.cj:163-165  Timer.repeat(duration, duration, {=> ws.writePingFrame(h(endpoint, ctx, pattern, ws, []))})
// WSMeta.cj:196      while(let frame <- ws.read()){
// WSMeta.cj:231      pingTimer?.cancel()        // 只有 case CloseWebFrame 这一条路
// WSMeta.cj:234-237  case _ => log.error(...); ws.closeConn()      // 不取消
// WSMeta.cj:242      }                          // read 返回 None 时直接返回，不取消
```

影响：客户端断网/直接断 socket（不发 Close 帧）时循环退出，定时器永久存活并持续向已关闭连接写帧；闭包捕获 `endpoint/ctx/pattern/ws` ⇒ 每断一条连接泄漏一个周期任务 + 一整条请求上下文。修法：把 `pingTimer?.cancel()` 放进该函数的 `finally`（或 `while` 外层的 `try/finally`）。

#### MVC-4 [高｜正确性] `download` 写出整个缓冲，而不是实际读到的长度 ✓已复核

位置：`src/ResponseDownload.cj:44-47, 62-65`

```cangjie
// ResponseDownload.cj:44-47
let buf = Array<Byte>(1024, repeat: 0)
while(let bytes <- d[0].read(buf) && bytes > 0){
    fd.write(buf)          // ← bytes 只用于判断，写的是全部 1024 字节
}
```

影响：多文件/多流下载时，除最后一块外的每一块都会多输出「脏尾部」（`read` 只填充 `bytes` 字节，其余是 0 或上一轮残留）⇒ 下载内容长度与内容都错。同文件 `src/FileDownload.cj:57-59` 是正确的 `buf[0..len]` 写法，可直接对齐。修法：`fd.write(buf[0..bytes])`，并把缓冲分配移到循环外、改用 `MVCConfig.downloadBufferSize`。

### 2.3 中危

- **MVC-5 [性能]** 每个 `@PathVariable` 参数都做一次全路径解析 + 全量 `HashMap` 构造：`ControllerFuncParam.cj:125` → `f_util/src/PathPattern.cj:173-195`。N 个 path 变量就重复 N 次切分。（`f_util` 属跨模块，可加单变量轻量查找。）
- **MVC-6 [内存]** WS continuation 帧累积无上限：`WSMeta.cj:169-173`（`bytes.add(all: payload)`，只有 fin 才清空）。客户端持续发 continuation 不发 fin 即可打爆单连接内存。修法：累积时校验总长上限，超限关连接。
- **MVC-7 [性能]** 路由热路径每请求多次字符串分配：`MultiRequestMethodHandler.cj:60` + `RequestMethod.cj:28-30, 55, 67-69`（`hashCode = toString().hashCode()`、`compare` 也走 `toString`）。修法：用 enum ordinal/常量名做哈希与比较。
- **MVC-8 [内存｜正确性]** 请求级 ThreadLocal 不清理：`RequestMeta.cj:25-35, 552`（`currentResponseStatus` 只 set 不清 ⇒ `accessLog` 的 status 会沿用上一个请求，如 401 后记成 401，见 `MVC-C4`）、`OverallStopwatch.cj:29-39`（404/405/OPTIONS 路径不调用 `elapsed` ⇒ 线程继续持有上个请求的 path 字符串）。修法：请求 `finally` 统一清理。
- **MVC-9 [性能]** 每请求一次反射式 bean 查找：`RequestMeta.cj:191`（`BeanFactory.instance.getFirst<T>().getOrThrow()`）——与 `BEAN-2/BEAN-3` 是同一成本的两端，建议注册期解析一次并缓存实例。

### 2.4 低危 / 待验证

- `MVC-L1` `MultiRequestMethodHandler.cj:90-97`：OPTIONS 每次重建 Allow 字符串（`metas` 注册后不变，可预生成）；另有死变量 `let last = metas.size`。
- `MVC-L2` `FileDownload.cj:56` / `ResponseDownload.cj:44, 62`：每次下载重新分配缓冲并每次读配置（`MVCConfig.cj:257-261`）。
- `MVC-L3` `RequestMeta.cj:161-175, 298-302`：多值 `Accept` 每请求构造 `AcceptQueue`（内含 `PriorityQueue` + 比较闭包），浏览器默认多值 Accept 命中率极高。
- `MVC-L4` `RequestCondition.cj:154-170`：每次条件检查新建 `HashSet<String>(currentValues)`。
- `MVC-L5` `HttpRequestDistributorImpl.cj:57-63`：未命中路径每请求新建 `RequestMeta`（含闭包）⇒ 建议复用单例 404 handler。
- `MVC-L6` `global_func.cj:69-147`：数组参数解析用 `split`（无逗号也会切出 1 元素数组），可先判 `indexOf(',')` 或 `lazySplit`。
- `MVC-L7` `RequestMeta.cj:76-92`：比较器内构造两个 `TreeSet`（注册期 O(N log N) 次，可预算排序键）。
- `MVC-L8` `RequestMeta.cj:71`：404 日志用非惰性插值（`'...${path}'`），改 `log.warn{...}`。
- `MVC-L9` `HttpStatus.cj:806-878` / `Series.cj:38-42`：`values` 属性每次访问重建数组（模块内只用于 `static init`，影响为 0，但属公开 API 易误用）。
- `MVC-L10` `RequestArgMeta.cj:21, 39`：同一次写入用 `[]` + `get` 双查表，可合并为一次 `get`。
- `MVC-L11` **待验证**：`RequestMeta.cj:303-318` 空结果 + `Accept` 不含 `*/*` ⇒ 406 而非 200 空体（设计意图待确认）。
- `MVC-L12` **待验证**：`RequestMethod.cj:32-38` `operator ==` 的分支里没有 `WS`，`(WS, WS)` 落到 `case _ => false`，而 `hashCode` 由 `toString` 生成 ⇒ 若 `HashMap` 不做引用短路，WS 路由查不到。

### 2.5 正确性缺陷

- **MVC-C1** 见 `MVC-4`（高，已复核）。
- **MVC-C2 [中｜待验证]** `RequestMeta.cj:303-309`：`Resource` 只在「非空结果 + 有 Accept + `genBody`」这一条路关闭；`accept` 缺失时直接落到 `313-318`，`InputStream`/`Resource` 结果不会被 `close()` ⇒ 句柄泄漏（需确认哪些返回类型同时实现 `ToData & Resource`）。
- **MVC-C3 [中｜已复核]** `ControllerFuncParam.cj:175`：`ctx.request.headers.getFirst("Content-Type").getOrThrow()` —— 无 `Content-Type` 的 POST/PUT（空 body、仅查询参数）抛 `NoneValueException` ⇒ 500，而应 415/400。
- **MVC-C4 [低]** 见 `MVC-8`（`accessLog` 的 status 串台）。
- **MVC-C5 [中]** `FileDownload.cj:71-75` + `RequestMeta.cj:372-376`：下载在 `spawn` 内执行后立即返回，`respond` 的 `finally` 立刻调 `OverallStopwatch.elapsed` ⇒ 下载耗时统计恒为 ~0；且 `spawn` 内异常无人接收（`Future` 被丢弃），`pipe.end()` 可能永不执行 ⇒ 客户端悬挂。
- **MVC-C6 [低]** `WSMeta.cj:176, 238-240`：文本/二进制帧到达但未配置对应 meta 时，每条消息抛一次 `WSException`，并在 catch 里 `toBase64String(frame.payload)`（O(payload)）⇒ 异常驱动控制流 + 放大编码。

### 2.6 已确认「无实例」的维度

路由匹配表**不是**每请求重建（已核实注册期构建）；热点循环里无 `Array/ArrayList.contains` 存在性判断（`consumes/produces` 用 `HashSet`、`checkHeader` 用 `HashSet.contains`、`HttpStatus/Series` 用 `HashMap`）；无循环字符串 `+`/插值（统一 `StringGenerator`）；无 String↔Rune/Byte 循环转换；锁只在注册期（`RequestMetas.add`、`register`、`AuthHandlerProxy` 首次初始化）；无「spawn 后立即 get」；无循环内同步 IO；无健康检查历史/中间件链增长；无 `catch NoneValueException` 式控制流（`tryParse` 系列均正确使用）；除 WS ping Timer 外无「注册无注销」；已知上界未预分配的分配点都在注册期。

---

## 3. f_bean

### 3.1 结构小结

「启动期注册 + 运行期查找」容器：`BeanFactory`（单例；`HashMap<String,BeanManager>` 名称表 + `HashMap<TypeInfo,TreeSet<BeanManager>>` 类型/注解表）在注册期把每个 bean 的本类、`Any`、`Object`、全部 `superInterfaces/superClass`/注解递归展开入表，`afterRegistered()` 冻结注册并跑一次条件筛选。`BeanManager` 管生命周期（单例走 `AtomicOptionReference` 双检锁缓存，prototype 每次 `new()`）。元数据**没有**每请求重建（这点合格），每请求重复付出的是 `TypeInfo.of`/`isSubtypeOf`/`as` 与过滤闭包。

### 3.2 高危

#### BEAN-1 [高｜正确性] 宏生成不存在的 `lookupSet` ✓已复核

位置：`src/macros/Constructor.cj:80, 92`；`src/lookup.cj`（只有 `lookupHashSet`、`lookupTreeSet`）

```cangjie
// Constructor.cj:80   case 'HashSet' | 'Set' => quote(lookupSet<$(paramTypeTokens[2 .. paramTypeTokens.size - 1])>($cond))
// Constructor.cj:92   case 'HashSet' | 'Set' => quote(lookupSet<$(paramTypeTokens[2 .. paramTypeTokens.size - 1])>())
```

已核实：全仓 `grep 'func lookupSet'` **无任何定义**，`lookupSet<` 仅出现在这两处宏输出里。影响：任何 `@Bean` + `@Constructor` 类只要有一个 `HashSet<T>`/`Set<T>` 形参，生成代码就引用未定义符号 ⇒ **编译失败**（不是运行时问题，所以只有用到该形参形态的类才暴露）。修法：改为 `lookupHashSet`（或补 `lookupSet` 别名）。建议同时给 `@Constructor` 加一条形参形态的编译期用例（`ArrayList/Array/HashSet/Option/HashMap` 各一）。

### 3.3 中危

- **BEAN-2 [性能]** 每请求 `getFirst<T>()` 重复 2 次 `TypeInfo.of<T>()` + 2 次 `isSubtypeOf` + 1 次 `as T`：`BeanFactory.cj:201, 203-206, 226, 228`。调用方 `f_mvc/src/RequestMeta.cj:191` 每请求一次。修法：`T` 的 `TypeInfo` 提到调用方缓存，并去掉「表 key 已保证类型」后的 `matches` 复检。
- **BEAN-3 [性能]** `iterator<T>` 每次调用新建 filter 闭包并对**每个元素**重跑类型/条件判断：`BeanFactory.cj:328`（`getList/getMap/lookupHashSet/lookupTreeSet` 全走它）。默认 `IgnoreCond` 恒真时也应短路：`IgnoreCond` 直接 `tree.iterator()`。
- **BEAN-4 [性能]** 条件求值里每次现场构造通配/正则：`BeanStringCondition.cj:74-75`（`Regex.wildcard(v).matches(s)` / `v.regex().matches(s)`，前者是 6 次 `replace` + 缓存查表，`f_regex/src/ExtendRegex.cj:76-85`、`RegexFromString.cj:40-64`）。而它又被 `BEAN-3` 逐元素调用 ⇒ 每元素 ~7 次字符串分配。修法：`StringCond` 内缓存编译好的 `Regex`。
- **BEAN-5 [性能｜待验证]** 每次取 bean 都算 `scope.isSingleton`，其中 `==` 会求 `TypeInfo.of<SingletonBeanScope>()`：`BeanScope.cj:31, 38-42, 59-63` + `BeanManager.cj:90`。**待验证** `TypeInfo.of` 是否有运行时缓存（`f_base/src/TypeInfos.cj:32-36` 注释显示作者也想用静态 `INSTANCE`）。修法：`BeanManager` 构造时预存 `Bool` 字段。

### 3.4 低危 / 待验证

- `BEAN-L1` `BeanFactory.cj:148-175` + `BeanDefCondition.cj:128-140`：启动期条件筛选近似 O(n²)（逐 bean 求条件、条件内再遍历该类型全部 manager；清理阶段对每个被丢弃 bean 全量遍历两张表，`161/165` 还无条件 `typeRemoved.add(t)`）。仅 `afterRegistered()` 一次。
- `BEAN-L2` `BeanManager.cj:40-44, 88-107` + `BeanFactory.cj:36-40`：容器与单例引用只增不减（`doDestroy()` 只调 `destroy()` 不清 `_bean`；三张表与 `registered` 无 reset/unregister）⇒ 已 destroy 的 bean 仍被强引用，测试/热重载受限。修法：`doDestroy` 后 `_bean.store(None)`，补 `reset()/unregister()`。
- `BEAN-L3` `BeanFactory.cj:34` + `BeanInitializer.cj:19-21`：`ExitCallbacks.atExit` 与 `InitializerCollection.register` 只注册不注销（进程级单例，构建次数 1，不构成重复泄漏）。
- `BEAN-L4` `lookup.cj:104-109`（同 `80-86`）：按 label 查单个 bean 却先全量物化 `ArrayList` 再线性扫描。修法：用 `iterator<T>(cond)` 惰性遍历，首个命中即返回。
- `BEAN-L5` `lookup.cj:56-58, 64-66`：`lookupHashSet/lookupTreeSet` 双重物化（先 `ArrayList` 再目标集合，均从 0 容量扩容）。
- `BEAN-L6` `BeanFactory.cj:63-121`：类型表 `Any`/`Object` 键使每个 bean 都入表；std 过滤只作用于 `isClass` 分支，注解分支仍展开 `superInterfaces/superClass`（注册期内存与遍历量放大）。
- `BEAN-L7` `BeanFactory.cj:109-115`：注册循环体内定义局部函数并捕获 `isClass`（每类型节点一次闭包分配，注册期，量级小）。
- `BEAN-L8` **待验证** `BeanManager.cj:59-66` vs `:88-107`：`initIfNeed()` 无条件 `_bean.store(new())` 而 `bean` getter 用双检 ⇒ 若启动初始化与首次请求并发，非 lazy 单例可能被二次创建覆盖（前一个实例的 `destroy()` 永不被触达）。正常启动流程下不触发。
- `BEAN-L9` `BeanFactory.cj:287-300`：`getFirstTuple<T>` 缺 `beanTypeIs<T>` 前置校验（`getFirst`/`iterator` 都有）⇒ 装配错误被静默吞成 `None`。

### 3.5 已确认「无实例」的维度

模块内**没有**属性拷贝/深拷贝代码（`as T`/`<-` 仅 4 处，都在查找返回路径）；无每请求重建类型元信息（注册期构建 + `registered` 冻结）；无 `ThreadLocal`；无自建缓存（唯一正则缓存来自 `f_regex`，已有界 `maxLife/maxSize`）；无异常当控制流（无 `catch NoneValueException`、无捕越界/转换失败；`getOrThrow` 只在「bean 不存在」错误路径）；无线性 `contains`（容器查找走 `HashMap.get`/`TreeSet.contains`，仅 label 类语义查找是 O(n)，已记 `BEAN-L4`）；无循环内字符串拼接热点。

---

## 4. f_aspect

### 4.1 结构小结

织入是**编译期宏**（`macros/PointCut.cj` 把每个公共实例函数体包进嵌套函数 `callee`，再调 `Aspects.proceed(info, callee)`），没有动态代理、没有运行时代码生成。运行期只有两个入口：`Aspects.proceed`（递归标志 → `doProceed` → `computeIfAbsent` 取/建拦截器链）与 `Aspect.proceed` 默认模板（before/around/after/throwing/final）。**切点匹配已按函数缓存**（`Aspects.cj:27`），匹配不在每次调用的热路径上 —— 这点是对的。每调用开销集中在：宏生成的 `InvocationFuncInfo(...)`（反射 + 两个数组 + 装箱）、`Aspects.proceed` 的 ThreadLocal 与闭包、链内按名重查切面 bean、`Any` 链装箱。

### 4.2 高危

#### ASP-1 [高｜正确性+内存] 拦截器链把「首次调用的 `fn`」永久烧进静态缓存 ✓已复核

位置：`src/Aspects.cj:25-46`（配合 `macros/PointCut.cj:109-118`）

```cangjie
// Aspects.cj:25   private static let aspects = ConcurrentHashMap<QualifiedFuncInfo, (Array<Any>) -> Any>()
// Aspects.cj:35   var f: (Array<Any>) -> Any = {args => fn(args)}     // 捕获 doProceed 的形参 fn
// Aspects.cj:39-43 f = { args => funcInfo.setArgs(args); BeanFactory.instance.get<Aspect>(aspectName)... }
// PointCut.cj:111-113  func callee(args: Array<Any>){ $argVars; $(decl.block.nodes) }   // 在被织入函数体内 ⇒ 捕获 this
```

影响：链按 (TypeInfo, InstanceFunctionInfo) 只建一次，链尾永远是最早那次调用的 `callee`；`callee` 定义在原方法体内（宏展开见 `PointCut.cj:109-118`）⇒ 捕获首个接收者 `this` ⇒ **prototype / 手工 `new` 的实例上会在错误对象上执行方法体**；同时该实例被静态 map 永久引用（无法回收）。修法：链里只保存切面名列表，把 `fn`（与 args）作为参数逐次传入。

#### ASP-2 [高｜正确性] 缓存的 `InvocationFuncInfo` 每调用被改写参数，并发下互相覆盖 ✓已复核

位置：`src/Aspects.cj:41`（配合 `:47`）

```cangjie
// Aspects.cj:41    funcInfo.setArgs(args)      // funcInfo 是 ASP-1 缓存里的同一个对象
// Aspects.cj:47    match (f(funcInfo.args)) { case x: T => x ... }
// Aspects.cj:64    case Some(_) => fn(funcInfo.args)
```

影响：两个线程调用同一织入函数时，A 的参数可能被 B 覆盖；切面在 `around` 里读 `funcInfo.args` 会拿到别人的参数（`f_orm` 的 `TransactionAspect.proceed` 正是基于 `funcInfo` 判断）。修法：去掉可变共享槽，`proceed(funcInfo, args, fn)` 显式传参。

#### ASP-3 [高｜性能] 每次调用都重建函数元信息（反射解析 + 2 个数组 + 参数装箱）

位置：`src/macros/PointCut.cj:115`、`QualifiedFuncInfo.cj:70`、`PointCut.cj:87-94`

```cangjie
// PointCut.cj:115  let info = InvocationFuncInfo(TypeInfo.of(this), $funcName, $argTypes, $args)   // 在被织入函数体开头
// PointCut.cj:87   let $paramName = (args[$(i)] as $(param.paramType)).getOrThrow()
// QualifiedFuncInfo.cj:70  this(typeInfo, typeInfo.getInstanceFunction(funcName, argTypes))
```

影响：每次调用 = `Array<Any>` + `Array<TypeInfo>` + `InvocationFuncInfo` + `QualifiedFuncInfo` 分配、每个值类型参数**装箱/解箱**（`as T` + `getOrThrow`）、一次 std.reflect 成员解析（`getInstanceFunction` 的实现不在仓库内，倍数**待验证**）。`@TransactionalService` 就是 `WeavedBean` 的别名（`f_orm/src/macros/TransactionalService.cj:19-20`），所以 ORM 的事务方法每次都付这份钱。修法：宏为每个函数生成静态元信息常量（或静态缓存 map），`args` 每调用单独传。

#### ASP-4 [高｜正确性] 前缀/后缀参数注解规则用 `params.size` 索引注解数组 ⇒ 越界崩溃 ✓已复核

位置：`src/AspectRoute.cj:290-309, 318-336`

```cangjie
// AspectRoute.cj:291  let annotations = annotationTypes.split(',')
// AspectRoute.cj:293-297  let range = if (asc) { 0..params.size } else { params.size - 1..=0 }
// AspectRoute.cj:298-299  for (i in range) { let current = annotations[i]      // ← 用 params 的长度索引 annotations
```

影响：规则项少于参数个数时抛 `IndexOutOfBoundsException`（无人捕获，直接从 `Aspects.doProceed` 冒泡到业务调用方 ⇒ 该函数**每次调用都失败**）。而 `AspectRoute.cj:311-317` 的文档示例恰好就是这个形状：`a.Annotation1,b.Annotation2` 匹配 `test2(@Annotation1 a, @Annotation2 b, c)`（3 参数 2 规则项）。修法：`range` 按 `annotations.size` 收敛（suffix 反向同理），并在长度不匹配时明确返回 `false`。

#### ASP-5 [高｜正确性] `ArgAnnotationsRouteRule` 恒返回 false（静默不织入）✓已复核

位置：`src/AspectRoute.cj:258-273`

```cangjie
// AspectRoute.cj:261-271
for (i in 0..params.size) {
    ...
    for (annotation in param.annotations where ...qualifiedName == annotationName) {
        continue        // ← 命中后只是 continue，循环正常结束后继续往下走
    }
    return false        // ← 因此任何非 '*' 项都会走到这里
}
```

影响：内层 `for ... where` 无论命中与否都正常结束，随后必然执行 `return false` ⇒ 只要规则里写了非 `*` 的注解，该规则**永不匹配**（静默失效、无任何提示）；全部写成 `*` 才会返回 `true`（`272`）。修法：命中置标志，循环结束后 `if (matched) { continue }` 再继续外层。

### 4.3 中危

- **ASP-6 [性能]** 切点匹配（遍历全部切面 bean + 注解 + 正则）在 `ConcurrentHashMap.computeIfAbsent` 的桶锁内执行：`Aspects.cj:27-34`。同桶其它函数首次调用会被阻塞。修法：锁外算好链，再 `putIfAbsent` 写入。
- **ASP-7 [性能]** 链里存的是切面**名字字符串**，每次调用都重做 `BeanFactory.get` + 子类型检查 + 日志闭包：`Aspects.cj:42`（`f_bean/src/BeanFactory.cj:208-234, 314-316`）。修法：建链时解析成 `Aspect` 实例并缓存。
- **ASP-8 [内存]** 链缓存只增不减、无失效/清空接口：`Aspects.cj:25`（全文无 `remove/clear`）。若某织入函数在切面 bean 注册完成前被调用过一次，**空链会被永久固化**（切面静默失效）；条目上界是织入函数数，但每条经 `ASP-1` 持有首个接收者。修法：暴露 `clear()/refresh()`，并在 bean 注册变更时清理。
- **ASP-9 [正确性]** `recursiveInvocationFlag` 让**嵌套**的织入方法调用整体跳过切面（不只是递归）：`Aspects.cj:63-65`。A 的织入方法调 B 的织入方法时，B 的事务/日志切面完全不生效（静默语义缺失）。修法：按 `QualifiedFuncInfo` 记调用深度，只对同一函数判定递归。

### 4.4 低危 / 待验证

- `ASP-L1` `AspectRoute.cj:85, 139, 162, 344`：每次匹配现构造正则（`Regex.wildcard` = 6 次 `replace` + 键串 + TTL 缓存查找；`Regex('^.+::')` 每次新建）。规则实例无状态，可缓存编译结果。
- `ASP-L2` `ConfigAspectRouteRule.cj:56, 72-242`（多处）：每次匹配重新 `Config.getString` + `split` + 构造新规则对象 + 传闭包。修法：规则内惰性解析一次并 memo。
- `ASP-L3` `AspectRoute.cj:189-213, 230, 245, 260, 282, 291`：匹配辅助函数每次分配临时 `HashSet`/`ArrayList` 并对每个注解做 `ClassTypeInfo.of`（集合选型本身是哈希，没问题）。
- `ASP-L4` `Aspects.cj:52-66`：每次调用两次 ThreadLocal 访问（`get` + `set/remove`）并伴随 `?Bool` 装箱；`remove()` 实为 `set(None)`（`f_base/src/ExtendThreadLocal.cj:33-35`）。
- `ASP-L5` `Aspect.cj:55-64`：每次回调包一层 try/catch/finally；`catch (e: Exception)` 包住全部步骤，默认 `throwing` 新建异常链，`finally` 里 `final()` 抛异常会覆盖原异常。
- `ASP-L6` `macros/PointCut.cj:52-56, 86-94`：宏展开期用 `+=` 在循环里累积 Tokens（编译期平方级拼接，大函数/多参数时明显）。
- `ASP-L7` `Aspects.cj:47-50`：结果统一走 `Any` 链，值类型返回值每次调用装箱（架构取舍，优先级最低）。
- `ASP-L8` **待验证（关键假设）**：链缓存命中依赖 `QualifiedFuncInfo.hashCode`（`QualifiedFuncInfo.cj:63, 72-80`，由 `typeInfo.hashCode()` + `funcInfo.hashCode()` 预处理）。若 std.reflect 在不同调用间返回不同/非结构化哈希的 `InstanceFunctionInfo`，则缓存**永不命中** ⇒ 切点匹配、正则、建链每次调用重做，且 `aspects` 会**以每次调用一个 key 的速度无界增长**。建议加一条「同一函数多次调用命中同一链」的测试把该假设钉死。

### 4.5 已确认「无实例」的维度

无每次调用新建代理对象/动态生成代理类（编译期宏改写 AST）；无每次调用重建拦截器列表（`computeIfAbsent` 已缓存）；无热点循环内创建 Lambda（建链循环每函数只走一次）；无线性 `contains`（注解名匹配用 `HashSet`）；无「已知规模不预分配」（`AspectRoute.cj:189-190` 反而有预分配）；生成代码里无循环拼接字符串，但**每调用生成 2 个临时集合**（见 `ASP-3`）；无 `catch` 吞异常式控制流（但存在真实越界，见 `ASP-4`）；ThreadLocal 有 `finally { remove() }`（只是 `remove` 非真清除，见 `ASP-L4`）。

---

## 5. 跨模块发现

### X-1 [高｜正确性] `f_base.TypeInfos.get(String)` 无限递归 ✓已复核

位置：`f_base/src/TypeInfos.cj:37-51`

```cangjie
// TypeInfos.cj:37-48
public static func get(qualifiedName: String): TypeInfo {
    if (let Some(x) <- INFOS.get(qualifiedName)) { x }
    else { synchronized(MUTEX) {
        if (let Some(x) <- INFOS.get(qualifiedName)) { x }
        else { let info = TypeInfos.get(qualifiedName)      // ← 调用的还是这个重载（参数是 String）
               INFOS[qualifiedName] = info; info } } }
}
```

影响：`INFOS` 未命中时自调用同一重载（无参重载是 `get<T>()`，不参与重载决议）⇒ 无限递归 ⇒ `StackOverflow`（且持锁递归）。**调用方共 14 处**：

- `f_aspect/src/AspectRoute.cj:114, 116, 118, 140, 183` ⇒ `ArgsRouteRule`/`ReturnTypeRouteRule`/`TargetRouteRule` 三条规则一用就崩
- `f_bean/src/BeanDefCondition.cj:91, 93, 95, 97, 99, 122, 123, 124` ⇒ `@Bean[cond: Current("...")]` 一类的条件装配不可用
- `f_orm/src/base/SqlExecutor.cj:967`

修法：该分支应改为「按名称构造 `TypeInfo`」的实现（例如从 `qualifiedName` 解析包名/类型名后查 `TypeInfo` 注册表，或抛明确的「未注册类型」异常），绝不能回调自身；修完补一条 `TypeInfos.get("a.b.C")` 的单测（断言不递归、返回值或异常符合约定）。

---

## 6. 基线与验证状态

- 基线脚本：`cjpm build` + `cjpm test --no-capture-output`，模块顺序 `f_bean → f_aspect → f_mvc → f_orm`（日志 `/tmp/review_baseline.log`、`/tmp/bl_<模块>_{build,test}.log`）。
- 已完成：`f_bean` 的 `cjpm build` **exit 0**（0 条 error）。`f_bean` 的 `cjpm test` 运行超过 5 分钟仍未结束，其余模块尚未开始 —— 属**超长/可能卡住**，尚未拿到完整基线；本报告的结论均来自代码阅读，不依赖该基线。
- 本报告未做**运行时实测**（无 benchmark、无 heap profile）。凡标「**待验证**」的条目都给出了验证方法：
  - `ORM-1`：同一 executor 上「同 SQL、不同参数」两次查询，断言结果不同；
  - `ORM-C1`：真实驱动（postgres/mysql）下取回 `iterator` 后逐行读，观察 `close()` 后行为；
  - `BEAN-1`：写一个含 `HashSet<T>` 形参的 `@Bean`+`@Constructor` 类，编译即见未定义符号；
  - `ASP-4/ASP-5`：按 `AspectRoute.cj:311-317` 的文档示例写规则，观察崩溃/不织入；
  - `ASP-L8`：同一织入函数调用 N 次，断言 `Aspects` 内部条目数为 1；
  - `X-1`：`TypeInfos.get("a.b.C")` 单测。

## 7. 审查方法与备注

- 方法：4 个模块并行全文通读（含 `macros` 子包），按「性能（复杂度/集合/分配/字符串/闭包/同步/IO/CFFI/数据表示/背压）+ 内存（堆与 RSS/临时对象/集合容量/缓存/大对象/对象图/闭包/线程/Resource/CFFI）」两套清单取证；每条结论要求 `文件:行号` + 证据片段 + 调用频率判断 + 修法，再对全部「高」级条目回到源码逐行复核。
- 计数口径：同一处问题若同时是性能与正确性问题，只在最高危那一节详述，其它位置用编号交叉引用（如 `MVC-4` ↔ `MVC-C1`），不重复计数。
- 本次审查**只读**，未改动这 4 个模块的任何代码；报告落在本分支 `.autocode/bugs/bug.md`。
