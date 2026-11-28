# f_time 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_time`（11 个源文件 + 2 个 .md）
- **基线**：工作区快照（未对照远端目标分支；`git blame` 显示全部代码来自 `4be871f2fd` 2026-10-02 与 `709e25ed5` 2026-10-15，快照模式无 diff，全部记「存量」）
- **审查重点**：时间/时区/格式解析正确性、边界与溢出、死代码、重复逻辑、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [严重][存量] `trim` / `set*` 重建 `DateTime` 时丢弃时区，非本地时区的瞬时被静默改写

- **位置**：`f_time/src/TimeUnit.cj:105`（MICROSECOND）、`:115`（MILLISECOND）、`:125`（SECOND）、`:135`（MINUTE）、`:145`（HOUR）、`:155`（DAY）、`:165`（MONTH）、`:175`（YEAR）、`:187`（WEEK）；同源位置 `f_time/src/ExtendDateTime.cj:55`（`today`）、`:75`（`setYear`）、`:89`（`setMonth(Month)`）、`:100`（`setDay`）、`:111`（`setHour`）、`:122`（`setMinute`）、`:133`（`setSecond`）、`:144`（`setMillisecond`）、`:155`（`setMicrosecond`）、`:166`（`setNanosecond`）
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符 / 语义与命名不符）+ §10 正确性（时区语义）
- **证据**：静态确定 —— `DateTime.of` 签名为 `timeZone!: TimeZone = TimeZone.Local`（`stdlib/.../time_package_structs.md:886`、`:968`），上述 19 处重建只传墙钟字段、不传 `timeZone`，等价于把 `t.zone` 下的墙钟照搬到本地时区。`trim` 的 `NANOSECOND` 分支（`TimeUnit.cj:96`）直接返回 `t`，是唯一保留时区的分支，进一步说明其余分支的丢弃是漏传而非设计。
- **描述**：`TimeUnit.HOUR.trim(DateTime.now(TimeZone.UTC))` 返回的不是「UTC 的整点」，而是「本地时区下同一墙钟值的整点」，瞬时偏移一个时区差（东八区差 8 小时，最坏 ±14 小时）。受影响面不止 `trim` 本身：`next`/`prev`（`TimeUnit.cj:61`，`toTrim` 默认 `true`）先调用 `trim`，`since`（`:91`）再由 `next` 派生，`TimeUnit.current`（`:52`）与 `ExtendDateTime.today/yesterday/tomorrow` 走同一条 `DateTime.of` 路径。UTC 调用方最直观的后果是：`TimeUnit.HOUR.since(datetime: utc 23:59)` 会算出负数（跨时区倒推 8 小时），而 `f_log` 这类调用方会把返回值直接交给定时器（`f_log/src/output/RotatableFile.cj:123`），负延迟意味着立即触发。本模块测试只用 `DateTime.parse('...')`（本地时区）构造输入（`TimeUnit_test.cj:26`），所以缺陷不可见。
- **建议**：所有重建统一补 `timeZone: t.zone`（`trim`）与 `timeZone: this.zone`（`set*`、`today`）；更彻底的做法是按 §2 合并成单个 `replaceFields` 辅助函数，只在一处传时区。回归用例补 `DateTime.now(TimeZone.UTC)` / `DateTime.of(..., timeZone: TimeZone("+08:00", 8 * Duration.hour))` 各单位的 `trim`、`next`、`setMonth` 断言（断言 `zoneId` 与 `toUnixTimeStamp()` 都不变）。

### [严重][存量] `WEEK` 截断对齐到「周日」，与 README 承诺的「对齐到周一」冲突

- **位置**：`f_time/src/TimeUnit.cj:177`（`case WEEK` 分支，`:178` 取 `dayOfWeek.toInteger()`，`:179` `addDays(-weekday)`）；契约侧 `f_time/README.md:160`、`f_time/README_en.md:160`；用例侧 `f_time/src/TimeUnit_test.cj:32`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（与规格 / README 冲突）+ §10 正确性
- **证据**：静态确定 —— `DayOfWeek.toInteger()` 的官方定义是「周日 0，周一至周六 1 至 6」（`stdlib/.../time_package_enums.md:141`），`t.addDays(-weekday)` 因此得到「不晚于 `t` 的最近周日」。反证同样在 README 里：`DayOfWeek.Monday - DayOfWeek.Sunday` 标注为 `1`（`README.md:679`），与「周日 = 0」一致。
- **描述**：`WEEK.trim` 实际把周一至周六都回退到上一个周日（周二 `-2`、周六 `-6`），周一返回的是周日而不是周一；只有周日输入返回自身。按 README 的「对齐到周一」口径，除周日外全部偏 1 天（周一那一档偏整整 1 天、其余偏 1 天），按周分桶的统计会把周一的数据算进上一周。`TimeUnit_test.cj:32` 恰好只断言 2024-11-24（周日）这一种输入，而周日正是两种口径唯一重合的日子，因此用例无法暴露差异。
- **建议**：若以「周一开始」为准（README 与 ISO 周的默认口径），改为 `let back = if (weekday == 0) { 6 } else { weekday - 1 }` 再 `addDays(-back)`；同时把 `TimeUnit_test.cj:32` 的用例扩成周一/周三/周日各一条（周一必须返回自身）。若确实想「周日起」，则必须改 `README.md:160` / `README_en.md:160` 的措辞并在 README 与用例里显式声明，否则属于契约与实现相反。

### [一般][存量] `setYear` / `setMonth` / `setDay` / `set*` 在日期非法时抛 `IllegalArgumentException`，与 README 的「替换字段即返回新值」契约不符，也与 std `addMonths` 的收敛语义相反

- **位置**：`f_time/src/ExtendDateTime.cj:74`（`setYear`）、`:85`（`setMonth(Int64)`）、`:88`（`setMonth(Month)`）、`:99`（`setDay`）、`:143`（`setMillisecond`）、`:154`（`setMicrosecond`）；另 `:110`、`:121`、`:132`、`:165` 的越界入参同理；文档侧 `f_time/README.md:438`–`472`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（边界 / 错误处理缺失）+ §13（文档未声明抛出）
- **证据**：静态确定 —— `DateTime.of` 文档明确「`dayOfMonth` 最大取值需要跟 month 匹配」且「当参数值超出指定范围，抛出 IllegalArgumentException」（`stdlib/.../time_package_structs.md:896`、`:909`）；同一套 std API 的 `addMonths` 则承诺「偏移到当月最后一天」（同文件 `:1664`）。二者语义不一致，是本模块自己选的路径。
- **描述**：`2024-01-31.setMonth(February)`、`2024-02-29.setYear(2023)`、`2024-04-30.setDay(31)`、`setMillisecond(1500)` 都会直接抛异常，而不是落到当月最后一天或进位；README 对这些方法只写「返回替换字段后的新 `DateTime`」（`:445`、`:455`、`:469`），一个 `throws` 都没有。`setDay`/`setMonth` 正是「月末调度 + 换月」这类场景最常用的入口（本仓 `f_ticktock/src/TicktockUnit.cj:275` 就在做月末判定），调用方按文档写完才发现要自己兜异常。
- **建议**：`setDay` 与 `setMonth` 先按目标年月算当月天数并用 `min(day, daysInMonth)` 收敛（与 `addMonths` 口径一致），再 `DateTime.of`；确实要保留「非法即抛」语义的，就在 README 每个方法下补 `@throws IllegalArgumentException` 与触发条件，并在方法注释里写明「不做收敛」。补 `2024-01-31.setMonth(2)`、`2024-02-29.setYear(2023)` 两个用例定死行为。

### [一般][存量] 公开 API 的溢出抛异常契约完全未声明（`duration` DSL、`addMilliseconds/Microseconds`、`toUnixEpochNanos/Micros`）

- **位置**：`f_time/src/TimeUnit.cj:217`–`223`（`n * Duration.nanosecond` … `n * Duration.day`）；`f_time/src/ExtendDateTime.cj:69`（`millis * Duration.millisecond`）、`:72`（`micros * Duration.microsecond`）、`:196`（`toMilliseconds`）、`:199`（`toMicroseconds`）、`:202`（`toNanoseconds`）；文档侧 `f_time/README.md:214`、`:422`、`:498`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（边界 / 溢出）+ §13（文档未声明抛出）
- **证据**：静态确定 —— `Int64 * Duration` 与 `Duration * Int64` 文档均声明「相乘后的结果超出 Duration 的表示范围时，抛出 ArithmeticException」（`core_package_structs.md:4925`、`core_package_interfaces.md:821`）；`toNanoseconds/toMicroseconds/toMilliseconds` 亦声明超出 `Int64` 范围抛 `ArithmeticException`（`core_package_structs.md:4598`）。`Duration` 上限约 `9.2e18` 纳秒（`core_package_structs.md:3973`），换算即：`1.day.duration` 在 `n > 106_751` 时溢出、`toUnixEpochNanos` 在 2262 年之后溢出。
- **描述**：README 只写「`Some(Duration)`；WEEK/MONTH/YEAR 返回 `None`」（`:220`），读者会认为除「不定长单位」外永不失败；实际 `200_000.days.duration`、`addMilliseconds(10_000_000_000_000)`、`DateTime.of(year: 2300, ...).toUnixEpochNanos()` 都抛异常。时间库的调用方常在「设备时间异常 / 配置写了巨大间隔」时踩到，且异常类型与 `TimeUnit.parse` 的 `IllegalArgumentException` 不同，没有统一处理入口。
- **建议**：要么在 README 为上述方法补 `@throws ArithmeticException`（写清触发条件），要么把溢出改成 `Option`（`duration` 已经是 `Option`，可直接返回 `None`）；`toUnixEpoch*` 建议保留抛出但显式文档化。

### [一般][存量] `yesterday` / `tomorrow` 用固定 24 小时时长加减，DST 时区拿到的不是 00:00

- **位置**：`f_time/src/ExtendDateTime.cj:60`（`today - Duration.day`）、`:65`（`today + Duration.day`）；文档侧 `f_time/README.md:408`、`:416`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符）+ §10 正确性（时区）
- **证据**：静态确定（机制确定，触发条件是时区有 DST）—— `Duration.day` 是定长 `24 * 60 * 60` 秒（`core_package_structs.md:4002`），`DateTime ± Duration` 是瞬时加减；DST 切换日当地一天只有 23 或 25 小时，因此结果落在 01:00 或 23:00。
- **描述**：README 承诺「昨日 00:00:00.000000」（`:408`）与「明日 00:00:00.000000」（`:416`）。在 `America/New_York`、`Europe/London` 这类时区，切换日的 `tomorrow` 会返回 01:00（春季）或 23:00（秋季），`yesterday` 对称出错。中国时区无 DST，所以本仓自用与现有用例（`ExtendDuration_test.cj`）都碰不到，但这是对外库 API，`TimeZone.Z` 的存在说明本模块确实打算服务非本地时区。
- **建议**：改成 `today.addDays(-1)` / `today.addDays(1)`（日历加法，保留墙钟 00:00），并补一条 `TimeZone("America/New_York", ...)` 下跨 DST 的用例；README 顺带把公式改成 `= today.addDays(±1)`。

### [一般][存量] README 的 `since` 示例数值错误（写「≈ Duration.minute」，实际约 27.4 秒）

- **位置**：`f_time/README.md:152`、`f_time/README_en.md:152`；实现侧 `f_time/src/TimeUnit.cj:91`–`93`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §13（示例不可用 / 与实现不符）
- **证据**：静态确定 —— `since` = `next(datetime, duration) - datetime`，`next` 默认 `toTrim = true`：先 `trim` 到 12:31:00，再 `+1` 分钟 = 12:32:00，减去未截断的 12:31:32.568900 = **27.4311 秒**，不是 60 秒。
- **描述**：示例给了读者「`since` 返回一个完整单位」的错误预期；按此写「用 `since` 算轮询间隔」的代码会得到比预期短一半的间隔（`f_log/src/output/RotatableFile.cj:123` 正是这种用法，只是它传入的已是截断值才恰好正确）。
- **建议**：改成 `MINUTE.since(datetime: 2023-10-11 12:31:00)` ≈ `Duration.minute`，或把注释改为「≈ 27.4311s（到下一个整分钟的距离）」，两版 README 同步改。

### [一般][存量] README 使用示例引用了不存在的 DSL `1.month.duration`

- **位置**：`f_time/README.md:665`、`f_time/README_en.md:665`；实现侧 `f_time/src/DurationCategory.cj:18`–`35`（接口只到 `weeks`/`week`）
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §13（示例引用不存在的 API）
- **证据**：静态确定 —— `DurationCategory` 声明 16 个属性，粒度为 `nanosecond` … `week`，没有 `month`/`months`（`DurationCategory.cj:18`–`35`，`extend Int64` 同样只实现到 `:114`–`123` 的 `weeks`/`week`）。
- **描述**：`let bad = 1.month.duration` 直接编译失败；读者会误以为 `Int64` DSL 支持月/年，也会误以为「`WEEK` 返回 `None`」可以通过 DSL 触发，实际上 `1.week.duration` 才是能触发 `None` 的写法。同一段示例上方（`:664`）的 `1.day.duration` 是对的，进一步说明是漏改。
- **建议**：示例改成 `1.week.duration`（注释写「WEEK 不定长 → None」）；若要保留「按月/按年」的 DSL，就在 `DurationCategory` 里补 `month`/`months`/`year`/`years` 并让 `duration` 属性对这三者返回 `None`（与 `TimeUnit.duration` 口径一致）。

### [一般][存量] README 版本号 `1.2.0` 与 `cjpm.toml` 的 `1.3.2021` 不一致，按文档安装会拉到旧制品

- **位置**：`f_time/README.md:6`、`:19`、`f_time/README_en.md:6`、`:19`；实现侧 `f_time/cjpm.toml:14`
- **来源**：存量（`cjpm.toml` 侧 `git blame` → `06ebb90eb` 2026-11-24「更新所有模块版本从 1.3.1020 到 1.3.2021」，README 仍是 2026-10-02 的版本）
- **判据**：review-checklist §13（文档过期 / 版本与命令过期）
- **证据**：静态确定 —— 文档两处写 `1.2.0`，`cjpm.toml` 为 `version = "1.3.2021"`；同仓其它模块已统一到 `1.3.2021`。
- **描述**：README 是消费方的安装入口，写 `"fountain::f_time" = "1.2.0"` 会解析到中心仓旧制品，拿不到 `isLastMonthDay`（`ExtendDateTime.cj:182`）等后续修补，且与本地 workspace 的行为不一致；排障时「文档说 1.2.0、代码是 1.3.2021」也会浪费定位时间。
- **建议**：两版 README 的版本号同步为 `1.3.2021`，并考虑把版本号从 README 正文移出（只保留 `cjpm.toml` 一处来源），避免每次发版都要改文档。

### [一般][存量] README 缺「注意事项 / 时区」段：时区语义、DST、周起始日、溢出边界都没有落笔

- **位置**：`f_time/README.md`（全文无「注意」「限制」「时区」章节；`trim` 说明在 `:154`–`163`，`set*` 在 `:438`–`472`）、`f_time/README_en.md` 同结构
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §14（缺关键段落：限制与注意事项）
- **证据**：静态确定 —— 文档侧只有一句「`WEEK` 对齐到周一」（`:160`），没有时区口径；代码侧 `trim`/`set*` 全部按 `TimeZone.Local` 重建（见第一条），`yesterday`/`tomorrow` 按定长日加减（见第五条），`toUnixEpochNanos` 2262 年溢出（见第四条）。三处行为差异都只在文档里查不到。
- **描述**：一个「时间/时区」模块的 README 没有任何时区章节，读者无法知道 `trim` 会换时区、`WEEK` 以哪天为一周起点、`Duration` 型 API 在 DST 日会偏 1 小时。上面三条缺陷（时区丢失、周起始、DST）本来都该在文档里被声明或禁止，缺这一段直接放大了它们的破坏力。
- **建议**：新增「注意事项」章节，至少写清：①`trim`/`next`/`since`/`set*`/`today` 均以 `TimeZone.Local` 重建（修好时区丢失后改为「保留输入时区」）；②`WEEK` 的起始日；③`yesterday`/`tomorrow` 在 DST 时区的偏差；④`duration`/`toUnixEpoch*` 的溢出边界。两版 README 同步。

### [轻微][存量] 公开 API 依赖返回类型推导（`TimeUnit.before`、`TimeDuration.before/after`），README 签名同样不写返回类型

- **位置**：`f_time/src/TimeUnit.cj:194`、`f_time/src/TimeDuration.cj:38`、`:41`；文档侧 `f_time/README.md:190`、`:301`、`:312`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §10（可读性 / 契约显式化）
- **证据**：静态确定 —— 语言允许省略返回类型并由函数体推导（`define_functions.md:86`、`:99`），因此 `before` 实际返回 `DateTime`、`TimeDuration.after` 同理；但源码与 README 的签名块都不写 `: DateTime`，只有 `@return` 文字提到。
- **描述**：对库的公开契约来说，「返回类型靠读函数体推断」让调用方与 IDE 提示都依赖实现细节；README 的 `public func before(t: DateTime, duration: Int64)`（`:190`）单看是 `Unit`，与下一行 `@return 过去的 DateTime` 自相矛盾，容易让读者以为该方法没有返回值。
- **建议**：三处显式写 `: DateTime`，README 签名块同步补上。

### [轻微][存量] `cjpm.toml` 声明了未使用的 `fountain::f_exception` 依赖

- **位置**：`f_time/cjpm.toml:2`；文档侧 `f_time/README.md:7`、`f_time/README_en.md:7`
- **来源**：存量
- **判据**：review-checklist §14（接线缺失 / 冗余依赖）
- **证据**：静态确定 —— `f_time/src` 全目录搜 `f_exception` 零命中（`grep -rn "f_exception" f_time/` 仅命中 `cjpm.toml:2` 与两份 README 的「依赖」行），源码只依赖 `std.time` / `std.convert.Parsable`。
- **描述**：多余的模块依赖会增加构建/发布耦合（`f_exception` 换版本或不可用时 `f_time` 一并受阻），并在 README 里误导读者以为时间模块会抛 `f_exception` 体系的异常（实际抛的是 `IllegalArgumentException` / `ArithmeticException`）。
- **建议**：删掉该依赖与两份 README 的「依赖」行；若确实计划统一异常类型，则先把 `IllegalArgumentException` 换成 `f_exception` 的自有异常再保留。

### [轻微][存量] 测试覆盖偏薄，且 `ExtendDuration_test` 有一个跨零点易碎用例

- **位置**：`f_time/src/TimeUnit_test.cj:24`–`34`（只测 `trim` 的 7 个单位）、`f_time/src/ExtendDateTime_test.cj:24`–`48`（只测 `isLastMonthDay`）、`f_time/src/ExtendDuration_test.cj:24`–`31`
- **来源**：存量（`TimeUnit_test.cj` / `ExtendDuration_test.cj` → `4be871f2fd`；`ExtendDateTime_test.cj` → `709e25ed5` 2026-10-15）
- **判据**：review-checklist §10（可测试性）+ §11（用例无法覆盖已发现的边界）
- **证据**：静态确定 —— `TimeUnit_test` 无 `NANOSECOND`/`MICROSECOND`/`MILLISECOND` 的 `trim` 断言，也没有 `next`/`prev`/`since`/`parse`/`tryParse`/`duration`/`after`/`before` 用例；`ExtendDateTime_test` 没有任何 `set*`、`toUnixEpoch*`、`today/yesterday/tomorrow`、`isLeapYear` 直接用例（`isLeapYear` 只通过 `isLastMonthDay` 间接覆盖 1900/2000/2028）；`ExtendDuration_test:25`–`26` 先取 `5.days.ago` 再取 `DateTime.now()`，只比对年月日（`:30`），跨零点执行时 `current` 与 `now` 会落在不同日期而偶发失败，且 `:27`–`28` 用 `println` 输出。
- **描述**：本报告第一、二、三、五条缺陷都能被「UTC 输入 + 各 `set*` 边界 + 周一/周三的 WEEK 用例」抓到，但现有用例全部避开；`ExtendDuration_test` 的偶发失败还会污染 CI 结果。
- **建议**：补三组用例：①`DateTime.of(..., timeZone: TimeZone.UTC)` 下各单位 `trim` 与 `setMonth` 的时区/时间戳守恒；②`setMonth`/`setDay`/`setYear` 的月末与闰年边界；③`WEEK.trim` 的周一、周三、周日三档。`ExtendDuration_test` 改为只取一次 `now` 并把断言改成 `5.days.ago.addDays(5)` 与基准 `now` 的差值小于 1 秒，去掉 `println`。

### [轻微][存量] `public import std.time.*` 把整个 `std.time` 纳入本模块公开 API 面，并让同包 5 个文件隐式依赖它

- **位置**：`f_time/src/ExtendDateTime.cj:18`；隐式依赖方 `f_time/src/TimeUnit.cj:16`–`18`（用 `DateTime`/`Duration`/`Month` 但自身无 import）、`f_time/src/ExtendDayOfWeek.cj:16`–`18`（`DayOfWeek`）、`f_time/src/ExtendMonth.cj:16`–`18`（`Month`）、`f_time/src/ExtendDuration.cj:16`–`18`（`Duration`/`DateTime`）、`f_time/src/ExtendTimeZone.cj:16`–`18`（`TimeZone`/`Duration`）
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §10（依赖方向 / 可维护性）+ §14（模块 API 面）
- **证据**：静态确定（仓内可见）+ 待确认（与消费方 import 是否冲突未验证）—— 非 `private` 的 `import` 具备「包内可见」语义（`package/import.md:266`–`271`），所以这些文件能编译；但 `public import` 同时把 `std.time` 的全部名字重导出（`import.md:271`），`import fountain::f_time.*` 的消费方会连带得到 `DateTime`/`Duration`/`Month` 等。
- **描述**：两个问题叠在一起：①`f_time` 的公开 API 面被无意放大到整个 `std.time`（`README` 只声明「标准库的时间 API 扩展」，没有说要重导出标准库）；②`TimeUnit.cj` 等 5 个文件的编译依赖一个位于 `ExtendDateTime.cj` 的 import，删除或拆分该文件会让其余文件成片报错，读代码时也看不出 `DateTime` 来自哪里。README 的使用示例又同时写了 `import fountain::f_time.*` 与 `import std.time.*`（`README.md:648`–`649`），若编译器对同名重导出报冲突，示例本身就跑不通（未见构建验证，标待确认）。
- **建议**：改成各文件按需 `import std.time.{DateTime, Duration, Month, DayOfWeek, TimeZone}`（或保留一处 `internal import` 供包内共享），`public import` 只保留真正要重导出的符号（如 `ExtendDateTime` 所需的 `Month`）。

> 存量缺陷共 13 条，是否纳入修复待用户决定。

## 优化可行性方案

### [CPU] 缓存 `TimeZone.Z`，避免每次访问新建 `TimeZone` 实例

- **现状**：`ExtendTimeZone.cj:23`–`27` 的 `get()` 每次执行 `TimeZone("Z", 0 * Duration.hour)`。`TimeZone` 是 class（`time_package_classes.md:263`），即每次访问都在堆上新建一个实例；调用频次取决于消费方把 `TimeZone.Z` 写在循环里还是提到常量处，仓内目前无调用（`grep -rn "TimeZone.Z" --include=*.cj .` 除本模块外零命中），因此当前收益接近 0。
- **方案**：改为 `private static let z = TimeZone("Z", Duration.Zero)`，`get()` 返回该实例；或 `static prop Z { get() { z } }` 配合惰性初始化（注意 §12：惰性初始化要么用 `static let` 的一次性初始化语义，要么显式同步）。
- **预期**：把每次访问的 1 次堆分配 + 构造校验降为 0；在「每条日志/每个请求都取 `TimeZone.Z`」的场景下可省 N 次分配（N = 调用次数），单次收益为一次对象构造，量级很小。
- **代价**：`TimeZone` 是不可变对象（`Equatable` 按 id/offset 判等），共享实例不引入语义变化；仅需确认没有调用方依赖「每次拿到不同实例」。
- **验证**：`cjpm bench -O2` 对照 1e7 次 `TimeZone.Z` 访问的耗时与分配量（`getAllocatedHeapSize()`）；若端到端占比低于噪声（约 5%）则不做。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `trim`/`set*` 的「取 7 个字段 + `DateTime.of` 重建」比 std 的 `addNanoseconds(-nanos % unit)` 截断更贵 | `f_time/src/TimeUnit.cj:94`–`190` | 单次耗时、调用频次、占端到端比例 | `cjpm bench -O2` 对照两种实现跑 1e6 次 `TU.MINUTE.trim`；`cjprof record` 看 `DateTime.of` 自耗时占比。`DateTime` 是 struct（`time_package_structs.md:9`），无堆分配，预期差异很小 |
| 2 | `TimeZone.Z` 每次新建实例构成实际分配热点 | `f_time/src/ExtendTimeZone.cj:23` | 该属性的调用次数与分配量 | 在消费方（如日志/序列化路径）加计数埋点，跑 10 分钟稳态负载，看 `getAllocatedHeapSize()` 增量与 `TimeZone` 构造次数 |
| 3 | `TimeUnit.trim` 的 `match` 分支内重复 `DateTime.of` 导致指令缓存/分支预测开销 | `f_time/src/TimeUnit.cj:95`–`189` | 分支预测失败率、函数自耗时 | `cjprof record` 跑 `trim` 混合单位（10 个单位轮转）1e7 次，与「先算字段再单次 `DateTime.of`」版本对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_time/README.md` | .md | ✅ | 与实现有 4 处不一致：见发现 #2（WEEK 周一）、#6（`since` 示例）、#7（`1.month`）、#8（版本 1.2.0）；缺时区注意事项段（#9） |
| 2 | `f_time/README_en.md` | .md | ✅ | 与 `README.md` 章节一一对应（无中英缺失）；上述 4 处问题同样存在，行号相同（`:160`、`:152`、`:665`、`:6`/`:19`） |
| 3 | `f_time/src/DurationCategory.cj` | .cj | ✅ | 接口 16 个属性 + `extend Int64` 全部为单复数委托；无 `month`/`year` DSL（见 #7）；无死代码 |
| 4 | `f_time/src/ExtendDateTime.cj` | .cj | ✅ | `today`/`set*` 丢时区（#1）、越界抛异常（#3）、溢出（#4）、DST（#5）、`public import`（#13）；`isLeapYear`/`isLastMonthDay` 逻辑正确（含 1900/2000 世纪规则） |
| 5 | `f_time/src/ExtendDateTime_test.cj` | .cj | ✅ | 只覆盖 `isLastMonthDay`；`private static func time` 被同文件 8 处调用（非死代码）；见 #12 |
| 6 | `f_time/src/ExtendDayOfWeek.cj` | .cj | ✅ | `-` 运算符实现与 README `:541` 一致；无独立 import，依赖 `ExtendDateTime.cj:18`（#13） |
| 7 | `f_time/src/ExtendDuration.cj` | .cj | ✅ | 4 个成员均为 `DateTime ± this` 一行包装，语义正确；无死代码 |
| 8 | `f_time/src/ExtendDuration_test.cj` | .cj | ✅ | 单个用例，两次取 `now`、只比日期、含 `println`，跨零点易碎（#12）；未覆盖 `Duration.ago/later/before/after` |
| 9 | `f_time/src/ExtendMonth.cj` | .cj | ✅ | 与 `ExtendDayOfWeek.cj` 同构（只换类型名），见 §2；实现正确 |
| 10 | `f_time/src/ExtendTimeZone.cj` | .cj | ✅ | `Z` 每次新建实例（优化方案）；构造函数与偏移合法（`time_package_classes.md:388`–`392`） |
| 11 | `f_time/src/TimeDuration.cj` | .cj | ✅ | 5 个成员全部委托给 `TimeUnit`；`before/after` 返回类型靠推导（#10） |
| 12 | `f_time/src/TimeUnit.cj` | .cj | ✅ | 核心文件：`trim` 丢时区（#1）与 WEEK 口径（#2）、`next`/`after` 重复映射（§2）、`duration` 溢出（#4）；`parse`/`tryParse` 大小写处理正确 |
| 13 | `f_time/src/TimeUnit_test.cj` | .cj | ✅ | 只覆盖 `trim` 的 SECOND..YEAR 7 档，WEEK 用例正好取周日（#2、#12） |

合计：`.cj` 11 个 / `.md` 2 个 / 共 13 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 5（#1 时区、#2 WEEK、#3 越界抛异常、#4 溢出、#5 DST）；设计 1（#13 `public import`）；可读性 1（#10 隐式返回类型）；语言特性 0（`Option` 未被静默丢弃，`T → Option<T>` 属语言允许的自动封装（`option_type.md:31`），`DateTime` 值语义使用正确）；安全性 0（无外部输入、无凭据、无字符串拼 SQL） |
| §1 死代码 | 0 | 已逐个核对：全模块唯一 `private` 符号 `ExtendDateTime_test.time`（`ExtendDateTime_test.cj:24`）被同文件 8 处调用；无 `internal` / `protected` 声明；`public` 声明全部位于 `public` 顶层类型/包顶层，嵌套链无 internal，均对外可达，只记信息（`TimeUnit.name`、`ExtendDateTime.currentDuration`、`TimeDuration`、`DurationCategory` 全 DSL 仓内零引用，但属对外契约，不判死代码）；`import` 逐条核对均被使用；无 `return`/`throw` 后的同层语句，无恒真恒假分支 |
| §2 重复逻辑 | 2 | ①`TimeUnit.next`（`TimeUnit.cj:61`–`79`）与 `TimeUnit.after`（`:200`–`213`）是同一套「单位 → `addX`」10 分支映射，逐行比对确认语义相同，仅差「是否先 `trim`」；建议 `next` 收敛为 `after(toTrim ? trim(datetime) : datetime, duration)`。②`trim` 的 9 个分支（`:97`–`188`）与 `setYear`…`setNanosecond` 9 个方法（`ExtendDateTime.cj:74`–`175`）各自重复「取全字段 + `DateTime.of`」的同构块，差异只有被替换的字段；这类重复已经造成行为漂移（时区只在 `trim` 的 NANOSECOND 分支幸免），建议抽 `replaceFields(...)` 并统一传 `timeZone`。`ExtendDayOfWeek`/`ExtendMonth` 属「只改类型名」，但各 3 行且语义独立，不为合并而上泛型 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`、无 `UnsupportedException`；`TimeUnit.duration` 的 `case _ => None`（`TimeUnit.cj:224`）是 WEEK/MONTH/YEAR 的正常兜底，与 README `:220` 一致 |
| §4 栈溢出 | 0 | 全模块无递归、无间接递归、无自引用结构；`trim`/`next` 都是单层 `match` |
| §5 OOM | 0 | 无容器、无按输入长度预分配、无全量物化；`DateTime` 为 struct，`trim` 不产生堆对象；唯一堆分配是 `TimeZone.Z`（见优化方案，量级为单对象） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`docs/LocalMode.md:487` 已把 f_time 判定为「格式化产生小字符串，量小」，不足以支撑热点结论，相关猜测已列入待验证假设 1–3 |
| §6.2 大粒度锁 | 0 | 全模块无 `synchronized` / `Mutex`，无临界区 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无线程池 |
| §6.4 低效算法 | 0 | 所有方法为 O(1) 字段运算或单层 `match`；无循环、无 `contains`、无字符串拼接 |
| §7 降堆内存方案 | 0 | 无长期持有结构、无缓存、无注册表；临时对象均为值类型，缩短生命周期无对象可缩 |
| §8 降 CPU 方案 | 1 | `TimeZone.Z` 每次新建实例（无基线，标「待验证」） |
| §9 local mode 可行性 | 0 | `docs/LocalMode-O2-Plan.md:124` 已判定 f_time 属「小对象（<1 KB）、local 头 16 B + 记账、收益为负」，本模块也没有函数内大临时对象；按现状不改，无峰值内存数据可证收益 |
| §11 现有代码的 BUG（存量） | 5 | #1–#5：逐个核对了 `trim` 10 分支、`next`/`prev`/`since`/`after`/`before`/`duration`、`set*` 9 个方法、`today/yesterday/tomorrow`、`isLeapYear`/`isLastMonthDay`、`toUnixEpoch*` 的边界与空值路径；`parse`/`tryParse` 空串与未知值、`Month.of`/`DateTime.of` 越界路径均已按 std 文档核对 |
| §12 并发安全与锁粒度 | 0 | 模块无共享可变状态：无 `var` 字段、无全局变量、无单例缓存；`TimeZone.Z` 每次返回新实例（不共享），`TimeUnit`/`TimeDuration` 不可变，`extend` 方法只用参数与 `this`，可安全并发调用 |
| §14 功能完备性与 README 覆盖 | 2 | ①README 缺时区/限制段（#9）；②`f_exception` 依赖声明但零使用（#11）。`src` 的 public 声明已逐个对照 README：`TU`、`TimeUnit` 全部成员、`TimeDuration` 全部成员、`DurationCategory` 16 属性、`ExtendDateTime` 全部成员、`ExtendDayOfWeek`、`ExtendDuration`、`ExtendMonth`、`ExtendTimeZone` 均有条目，无「公开 API 未文档化」；根 `README.md:381` 已登记本模块（索引不缺） |
| 文件覆盖（§13 等） | 13/13 | 13 个文件全部读完（含 2 个 `.md`）；§13 命中 3 条（#6 `since` 示例、#7 `1.month`、#8 版本号） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 7 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

> 「待验证假设」3 条不计入统计，也不进 `todo.md` / `tasks.md`。

## 总评

`f_time` 的代码体量小、结构清楚：全部是不可变值/包装类型，无并发共享状态、无容器、无递归、无空实现，`parse`/`tryParse`/`isLeapYear`/`isLastMonthDay`（含 1900/2000 世纪闰年规则）这些最容易写错的点都是对的，`Duration`/`Month`/`DayOfWeek` 的运算符扩展也符合 std 语义。主要风险集中在**时区**这条主线上：只要输入不是本地时区，`trim`（以及由它派生的 `next`/`prev`/`since`）和 9 个 `set*` 方法都会静默改写瞬时，这是本轮最该先处理的阻塞项；`WEEK` 对齐到周日与 README 的「周一」相反，会让按周聚合整体偏一天，同属阻塞项。这两条当前都被测试规避（用例只用本地时区、`WEEK` 只测周日），所以一直没被发现。

可以排期的是 `set*` 的越界抛异常与各处溢出契约未文档化、`yesterday`/`tomorrow` 的 DST 偏差，以及 4 处 README 不一致（版本号会直接把读者导向旧制品，优先级最高）。README 缺时区/限制段属于同一条主线的文档面，建议与代码修复同批做。重复逻辑只有两处（`next`/`after` 的映射、`trim`/`set*` 的重建块），但后者正是时区缺陷的根因，值得一并收敛。性能面没有数据支撑任何结论，`TimeZone.Z` 的实例缓存是唯一的低风险小改动，按待验证处理即可。
