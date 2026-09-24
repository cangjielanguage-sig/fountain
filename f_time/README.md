# f_time

> 标准库的时间 API 扩展（`std.time` 增强）

- 包名：`fountain::f_time`
- 版本：`1.2.0`
- 依赖：`fountain::f_exception`
- 作者：吴京润
- License：Apache-2.0

## 安装

在消费模块的 `cjpm.toml` 中添加：

```toml
[dependencies]
  "fountain::f_time" = { path = "../f_time" }   # 本地依赖
  # 或
  "fountain::f_time" = "1.2.0"                  # 中心仓依赖
```

## 使用

```cj
import fountain::f_time.*   // 引入所有公共声明
```

---

## API 文档

### 类型别名

#### `TU`

```cj
public type TU = TimeUnit
```

`TimeUnit` 的简写别名。

---

### 枚举 `TimeUnit`

```cj
public enum TimeUnit <: ToString & Parsable<TimeUnit> {
    | NANOSECOND
    | MICROSECOND
    | MILLISECOND
    | SECOND
    | MINUTE
    | HOUR
    | DAY
    | WEEK
    | MONTH
    | YEAR
}
```

时间单位枚举，覆盖从纳秒到年的 10 个粒度，实现 `ToString` 与 `Parsable<TimeUnit>`。

#### 静态方法

##### `parse`

```cj
public static func parse(value: String): TimeUnit
```

将字符串解析为 `TimeUnit`（大小写不敏感）。

- **@param** `value` 待解析的字符串（如 `"second"`、`"MINUTE"`）
- **@return** 对应的 `TimeUnit`
- **@throws** `IllegalArgumentException` — 当 `value` 无法识别时抛出

##### `tryParse`

```cj
public static func tryParse(value: String): Option<TimeUnit>
```

尝试将字符串解析为 `TimeUnit`，失败返回 `None`。

- **@param** `value` 待解析的字符串
- **@return** 成功返回 `Some(TimeUnit)`，失败返回 `None`

#### 实例属性

##### `current`

```cj
public prop current: DateTime
```

以当前时间单位对齐（trim）后的当前时刻。

- **@return** `DateTime.now()` 经 `this.trim` 处理后的值

#### 实例方法

##### `next`

```cj
public func next(
    datetime!: DateTime = DateTime.now(),
    duration!: Int64 = 1,
    toTrim!: Bool = true
): DateTime
```

返回 `datetime` 在当前时间单位上未来 `duration` 个整点。

- **@param** `datetime` 基准时间（默认 `DateTime.now()`）
- **@param** `duration` 偏移量，可为负数（默认 `1`）
- **@param** `toTrim` 是否先对 `datetime` 做整点对齐（默认 `true`）
- **@return** 偏移后的 `DateTime`
- 示例：`MINUTE.next(datetime: 2023-10-11 12:31:32.568900, duration: 1)` → `2023-10-11 12:32:00.000000`

##### `prev`

```cj
public func prev(
    datetime!: DateTime = DateTime.now(),
    duration!: Int64 = 1,
    toTrim!: Bool = true
): DateTime
```

返回 `datetime` 在当前时间单位上过去 `duration` 个整点，等价于 `next(datetime, -duration, toTrim)`。

- **@param** `datetime` 基准时间（默认 `DateTime.now()`）
- **@param** `duration` 偏移量，可为负数（默认 `1`）
- **@param** `toTrim` 是否先做整点对齐（默认 `true`）
- **@return** 偏移后的 `DateTime`
- 示例：`MINUTE.prev(datetime: 2023-10-11 12:31:32.568900, duration: 1)` → `2023-10-11 12:31:00.000000`

##### `since`

```cj
public func since(
    datetime!: DateTime = DateTime.now(),
    duration!: Int64 = 1
): Duration
```

计算 `datetime` 距离其未来 `duration` 个当前单位整点的时间长度。

- **@param** `datetime` 基准时间（默认 `DateTime.now()`）
- **@param** `duration` 单位数（默认 `1`）
- **@return** 对应的 `Duration`
- 示例：`MINUTE.since(datetime: 2023-10-11 12:31:32.568900)` ≈ `Duration.minute`

##### `trim`

```cj
public func trim(t: DateTime): DateTime
```

将 `t` 截断到当前时间单位的整点：所有更小单位清零，`WEEK` 对齐到周一，`MONTH` 对齐到 1 号，`YEAR` 对齐到 1 月 1 日。

- **@param** `t` 待截断的 `DateTime`
- **@return** 截断后的 `DateTime`

##### `ago`

```cj
public func ago(duration: Int64): DateTime
```

以当前时间为基准，向前回退 `duration` 个当前单位。

- **@param** `duration` 偏移单位数
- **@return** 过去的 `DateTime`

##### `later`

```cj
public func later(duration: Int64): DateTime
```

以当前时间为基准，向后推进 `duration` 个当前单位。

- **@param** `duration` 偏移单位数
- **@return** 未来的 `DateTime`

##### `before`

```cj
public func before(t: DateTime, duration: Int64)
```

以 `t` 为基准，向前回退 `duration` 个当前单位（等价于 `after(t, -duration)`）。

- **@param** `t` 基准时间
- **@param** `duration` 偏移单位数
- **@return** 过去的 `DateTime`

##### `after`

```cj
public func after(t: DateTime, duration: Int64): DateTime
```

以 `t` 为基准，向后推进 `duration` 个当前单位。

- **@param** `t` 基准时间
- **@param** `duration` 偏移单位数
- **@return** 未来的 `DateTime`

##### `duration`

```cj
public func duration(n: Int64): Option<Duration>
```

将 `n` 个当前单位转换为 `Duration`。

- **@param** `n` 单位数
- **@return** `Some(Duration)`；当单位为 `WEEK`/`MONTH`/`YEAR`（无法表示为定长 `Duration`）时返回 `None`

##### `name`

```cj
public func name(): String
```

返回当前单位的大写字符串名，等价于 `toString()`。

- **@return** 如 `"NANOSECOND"`、`"MINUTE"`

##### `toString`

```cj
public func toString(): String
```

返回当前单位的大写字符串名。

- **@return** 如 `"SECOND"`、`"HOUR"`

---

### 类 `TimeDuration`

```cj
public class TimeDuration {
    public TimeDuration(
        public let value: Int64,
        public let timeunit: TimeUnit
    ) {}
    // ...
}
```

将一个数值与 `TimeUnit` 组合的"时间量"包装类，用于 `DurationCategory` 扩展链式 DSL。

#### 构造器

```cj
public TimeDuration(
    public let value: Int64,
    public let timeunit: TimeUnit
)
```

- **@param** `value` 数量
- **@param** `timeunit` 时间单位

#### 实例属性

##### `duration`

```cj
public prop duration: Option<Duration>
```

- **@return** 该 `TimeDuration` 对应的 `Duration`；若单位不支持定长换算（`WEEK`/`MONTH`/`YEAR`）则返回 `None`

##### `ago`

```cj
public prop ago: DateTime
```

- **@return** 以当前时间为基准，向前回退该 `TimeDuration` 得到的 `DateTime`

##### `later`

```cj
public prop later: DateTime
```

- **@return** 以当前时间为基准，向后推进该 `TimeDuration` 得到的 `DateTime`

#### 实例方法

##### `before`

```cj
public func before(t: DateTime)
```

以 `t` 为基准向前回退该 `TimeDuration`。

- **@param** `t` 基准时间
- **@return** 过去的 `DateTime`

##### `after`

```cj
public func after(t: DateTime)
```

以 `t` 为基准向后推进该 `TimeDuration`。

- **@param** `t` 基准时间
- **@return** 未来的 `DateTime`

---

### 接口 `DurationCategory` 与 `Int64` 扩展

```cj
public interface DurationCategory {
    prop nanoseconds: TimeDuration
    prop nanosecond:  TimeDuration
    prop microseconds: TimeDuration
    prop microsecond:  TimeDuration
    prop milliseconds: TimeDuration
    prop millisecond:  TimeDuration
    prop seconds: TimeDuration
    prop second:  TimeDuration
    prop minutes: TimeDuration
    prop minute:  TimeDuration
    prop hours: TimeDuration
    prop hour:   TimeDuration
    prop days: TimeDuration
    prop day:  TimeDuration
    prop weeks: TimeDuration
    prop week:  TimeDuration
}

extend Int64 <: DurationCategory { ... }
```

为 `Int64` 扩展"数字 + 单位"形式的 DSL，例如 `5.seconds`、`2.minutes`、`1.day`，每个属性返回 `TimeDuration`。单复数同义（`second` == `seconds`）。

---

### 接口 `ExtendDateTime` 与 `DateTime` 扩展

```cj
public interface ExtendDateTime {
    static prop currentDuration: Duration
    static prop yesterday: DateTime
    static prop today: DateTime
    static prop tomorrow: DateTime
    func addMilliseconds(millis: Int64): DateTime
    func addMicroseconds(micros: Int64): DateTime
    func setYear(year: Int64): DateTime
    func setMonth(month: Int64): DateTime
    func setMonth(month: Month): DateTime
    func setDay(day: Int64): DateTime
    func setHour(hour: Int64): DateTime
    func setMinute(minute: Int64): DateTime
    func setSecond(second: Int64): DateTime
    func setMillisecond(millis: Int64): DateTime
    func setMicrosecond(micros: Int64): DateTime
    func setNanosecond(nanos: Int64): DateTime
    prop isLeapYear: Bool
    prop isLastMonthDay: Bool
    func toUnixEpochSeconds(): Int64
    func toUnixEpochMillis(): Int64
    func toUnixEpochMicros(): Int64
    func toUnixEpochNanos(): Int64
}

extend DateTime <: ExtendDateTime { ... }
```

为 `DateTime` 扩展的便捷方法。

#### 静态属性

##### `currentDuration`

```cj
public static prop currentDuration: Duration
```

- **@return** 当前时刻的 Unix 时间戳对应的 `Duration`

##### `today`

```cj
public static prop today: DateTime
```

- **@return** 今日 00:00:00.000000 的 `DateTime`

##### `yesterday`

```cj
public static prop yesterday: DateTime
```

- **@return** 昨日 00:00:00.000000 的 `DateTime`（= `today - Duration.day`）

##### `tomorrow`

```cj
public static prop tomorrow: DateTime
```

- **@return** 明日 00:00:00.000000 的 `DateTime`（= `today + Duration.day`）

#### 实例方法

##### `addMilliseconds`

```cj
public func addMilliseconds(millis: Int64): DateTime
```

- **@param** `millis` 毫秒数
- **@return** 加上 `millis` 毫秒后的 `DateTime`

##### `addMicroseconds`

```cj
public func addMicroseconds(micros: Int64): DateTime
```

- **@param** `micros` 微秒数
- **@return** 加上 `micros` 微秒后的 `DateTime`

##### `setYear`

```cj
public func setYear(year: Int64): DateTime
```

- **@param** `year` 新年分
- **@return** 替换年后的新 `DateTime`（其他字段不变）

##### `setMonth`

```cj
public func setMonth(month: Int64): DateTime
public func setMonth(month: Month): DateTime
```

- **@param** `month` 新月份（`Int64` 或 `Month`）
- **@return** 替换月份后的新 `DateTime`

##### `setDay` / `setHour` / `setMinute` / `setSecond` / `setMillisecond` / `setMicrosecond` / `setNanosecond`

```cj
public func setDay(day: Int64): DateTime
public func setHour(hour: Int64): DateTime
public func setMinute(minute: Int64): DateTime
public func setSecond(second: Int64): DateTime
public func setMillisecond(millis: Int64): DateTime
public func setMicrosecond(micros: Int64): DateTime
public func setNanosecond(nanos: Int64): DateTime
```

返回替换对应字段后的新 `DateTime`。

- `setMillisecond` 通过将 `millis` 乘以 `1_000_000` 写入 `nanosecond`
- `setMicrosecond` 通过将 `micros` 乘以 `1_000` 写入 `nanosecond`

##### `toUnixEpochSeconds`

```cj
public func toUnixEpochSeconds(): Int64
```

- **@return** 当前 `DateTime` 的 Unix 时间戳（秒）

##### `toUnixEpochMillis`

```cj
public func toUnixEpochMillis(): Int64
```

- **@return** 当前 `DateTime` 的 Unix 时间戳（毫秒）

##### `toUnixEpochMicros`

```cj
public func toUnixEpochMicros(): Int64
```

- **@return** 当前 `DateTime` 的 Unix 时间戳（微秒）

##### `toUnixEpochNanos`

```cj
public func toUnixEpochNanos(): Int64
```

- **@return** 当前 `DateTime` 的 Unix 时间戳（纳秒）

#### 实例属性

##### `isLeapYear`

```cj
public prop isLeapYear: Bool
```

- **@return** 当前 `DateTime` 的年份是否为闰年

##### `isLastMonthDay`

```cj
public prop isLastMonthDay: Bool
```

- **@return** 当前 `DateTime` 是否为所在月份的最后一天

---

### 接口 `ExtendDayOfWeek` 与 `DayOfWeek` 扩展

```cj
public interface ExtendDayOfWeek {
    operator func -(day: DayOfWeek): Int64
}

extend DayOfWeek <: ExtendDayOfWeek {
    public operator func -(day: DayOfWeek): Int64
}
```

为 `DayOfWeek` 扩展 `-` 操作符，返回两个星期序号之差。

- **@param** `day` 另一个 `DayOfWeek`
- **@return** `this.toInteger() - day.toInteger()`

---

### 接口 `ExtendDuration` 与 `Duration` 扩展

```cj
public interface ExtendDuration {
    prop ago: DateTime
    prop later: DateTime
    func before(current: DateTime): DateTime
    func after(current: DateTime): DateTime
}

extend Duration <: ExtendDuration { ... }
```

为 `Duration` 扩展"以当前时刻为基准的过去/未来"语义。

#### 实例属性

##### `ago`

```cj
public prop ago: DateTime
```

- **@return** `DateTime.now() - this`

##### `later`

```cj
public prop later: DateTime
```

- **@return** `DateTime.now() + this`

#### 实例方法

##### `before`

```cj
public func before(current: DateTime): DateTime
```

- **@param** `current` 基准时间
- **@return** `current - this`

##### `after`

```cj
public func after(current: DateTime): DateTime
```

- **@param** `current` 基准时间
- **@return** `current + this`

---

### 接口 `ExtendMonth` 与 `Month` 扩展

```cj
public interface ExtendMonth {
    operator func -(month: Month): Int64
}

extend Month <: ExtendMonth {
    public operator func -(month: Month): Int64
}
```

为 `Month` 扩展 `-` 操作符，返回两个月份序号之差。

- **@param** `month` 另一个 `Month`
- **@return** `this.toInteger() - month.toInteger()`

---

### 接口 `ExtendTimeZone` 与 `TimeZone` 扩展

```cj
public interface ExtendTimeZone {
    static prop Z: TimeZone
}

extend TimeZone <: ExtendTimeZone {
    public static prop Z: TimeZone
}
```

为 `TimeZone` 扩展 UTC "Z" 时区常量。

#### 静态属性

##### `Z`

```cj
public static prop Z: TimeZone
```

- **@return** 偏移为 0、名为 `"Z"` 的 UTC `TimeZone` 实例

---

## 使用示例

```cj
import fountain::f_time.*
import std.time.*

// TimeUnit 解析
let unit = TimeUnit.parse("minute")        // MINUTE
let opt  = TimeUnit.tryParse("Foo")         // None<TimeUnit>

// 整点对齐与上下一个整点
let now      = DateTime.now()
let trimmed  = TimeUnit.MINUTE.trim(now)
let nextMin  = TimeUnit.MINUTE.next()      // 下一个整分钟
let prevHour = TimeUnit.HOUR.prev(duration: 2)

// Int64 DSL
let d1 = 5.seconds.later                    // 5 秒后的 DateTime
let d2 = 2.minutes.ago                     // 2 分钟前的 DateTime
let dur = 1.day.duration                   // Some(Duration.day)
let bad = 1.month.duration                 // None<Duration>（MONTH 不定长）

// DateTime 扩展
let today    = DateTime.today
let tomorrow = DateTime.tomorrow
let leap     = today.isLeapYear
let epochSec = DateTime.now().toUnixEpochSeconds()

// Duration 扩展
let past  = Duration.minute.ago
let future = Duration.hour.later
let shifted = Duration.day.before(DateTime.tomorrow)

// DayOfWeek / Month 操作符
let dowDiff = DayOfWeek.Monday - DayOfWeek.Sunday    // 1
let monDiff = Month.January - Month.December          // -11

// UTC 时区
let utc = TimeZone.Z
```
