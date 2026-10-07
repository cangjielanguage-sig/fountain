# f_time

> Time API extensions for the standard library (`std.time` enhancements)

- Package: `fountain::f_time`
- Version: `1.2.0`
- Dependencies: `fountain::f_exception`
- Author: 吴京润
- License: Apache-2.0

## Installation

Add the following to the `cjpm.toml` of the consuming module:

```toml
[dependencies]
  "fountain::f_time" = { path = "../f_time" }   # Local dependency
  # or
  "fountain::f_time" = "1.2.0"                  # Central repository dependency
```

## Usage

```cj
import fountain::f_time.*   // Import all public declarations
```

---

## API documentation

### Type alias

#### `TU`

```cj
public type TU = TimeUnit
```

Shorthand alias of `TimeUnit`.

---

### Enum `TimeUnit`

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

Time unit enum covering 10 granularities from nanosecond to year; implements `ToString` and `Parsable<TimeUnit>`.

#### Static methods

##### `parse`

```cj
public static func parse(value: String): TimeUnit
```

Parse a string into a `TimeUnit` (case insensitive).

- **@param** `value` The string to parse (such as `"second"`, `"MINUTE"`)
- **@return** The corresponding `TimeUnit`
- **@throws** `IllegalArgumentException` —— thrown when `value` cannot be recognized

##### `tryParse`

```cj
public static func tryParse(value: String): Option<TimeUnit>
```

Try to parse a string into a `TimeUnit`; returns `None` on failure.

- **@param** `value` The string to parse
- **@return** `Some(TimeUnit)` on success, `None` on failure

#### Instance properties

##### `current`

```cj
public prop current: DateTime
```

The current instant aligned (trimmed) to the current time unit.

- **@return** The value of `DateTime.now()` after `this.trim`

#### Instance methods

##### `next`

```cj
public func next(
    datetime!: DateTime = DateTime.now(),
    duration!: Int64 = 1,
    toTrim!: Bool = true
): DateTime
```

Return the `duration`-th whole point in the future of `datetime` on the current time unit.

- **@param** `datetime` Base time (default `DateTime.now()`)
- **@param** `duration` Offset, may be negative (default `1`)
- **@param** `toTrim` Whether to align `datetime` to a whole point first (default `true`)
- **@return** The offset `DateTime`
- Example: `MINUTE.next(datetime: 2023-10-11 12:31:32.568900, duration: 1)` → `2023-10-11 12:32:00.000000`

##### `prev`

```cj
public func prev(
    datetime!: DateTime = DateTime.now(),
    duration!: Int64 = 1,
    toTrim!: Bool = true
): DateTime
```

Return the `duration`-th whole point in the past of `datetime` on the current time unit; equivalent to `next(datetime, -duration, toTrim)`.

- **@param** `datetime` Base time (default `DateTime.now()`)
- **@param** `duration` Offset, may be negative (default `1`)
- **@param** `toTrim` Whether to align to a whole point first (default `true`)
- **@return** The offset `DateTime`
- Example: `MINUTE.prev(datetime: 2023-10-11 12:31:32.568900, duration: 1)` → `2023-10-11 12:31:00.000000`

##### `since`

```cj
public func since(
    datetime!: DateTime = DateTime.now(),
    duration!: Int64 = 1
): Duration
```

Compute the length of time from `datetime` to its `duration`-th whole point of the current unit in the future.

- **@param** `datetime` Base time (default `DateTime.now()`)
- **@param** `duration` Number of units (default `1`)
- **@return** The corresponding `Duration`
- Example: `MINUTE.since(datetime: 2023-10-11 12:31:32.568900)` ≈ `Duration.minute`

##### `trim`

```cj
public func trim(t: DateTime): DateTime
```

Truncate `t` to a whole point of the current time unit: all smaller units are zeroed, `WEEK` is aligned to Monday, `MONTH` to the 1st, and `YEAR` to January 1.

- **@param** `t` The `DateTime` to truncate
- **@return** The truncated `DateTime`

##### `ago`

```cj
public func ago(duration: Int64): DateTime
```

Move `duration` units of the current unit backwards relative to the current time.

- **@param** `duration` Number of offset units
- **@return** A `DateTime` in the past

##### `later`

```cj
public func later(duration: Int64): DateTime
```

Move `duration` units of the current unit forwards relative to the current time.

- **@param** `duration` Number of offset units
- **@return** A `DateTime` in the future

##### `before`

```cj
public func before(t: DateTime, duration: Int64)
```

Move `duration` units of the current unit backwards relative to `t` (equivalent to `after(t, -duration)`).

- **@param** `t` Base time
- **@param** `duration` Number of offset units
- **@return** A `DateTime` in the past

##### `after`

```cj
public func after(t: DateTime, duration: Int64): DateTime
```

Move `duration` units of the current unit forwards relative to `t`.

- **@param** `t` Base time
- **@param** `duration` Number of offset units
- **@return** A `DateTime` in the future

##### `duration`

```cj
public func duration(n: Int64): Option<Duration>
```

Convert `n` units of the current unit into a `Duration`.

- **@param** `n` Number of units
- **@return** `Some(Duration)`; returns `None` when the unit is `WEEK`/`MONTH`/`YEAR` (which cannot be expressed as a fixed-length `Duration`)

##### `name`

```cj
public func name(): String
```

Return the upper-case string name of the current unit; equivalent to `toString()`.

- **@return** Such as `"NANOSECOND"`, `"MINUTE"`

##### `toString`

```cj
public func toString(): String
```

Return the upper-case string name of the current unit.

- **@return** Such as `"SECOND"`, `"HOUR"`

---

### Class `TimeDuration`

```cj
public class TimeDuration {
    public TimeDuration(
        public let value: Int64,
        public let timeunit: TimeUnit
    ) {}
    // ...
}
```

A "time amount" wrapper class combining a number with a `TimeUnit`, used by the `DurationCategory` extension chain DSL.

#### Constructor

```cj
public TimeDuration(
    public let value: Int64,
    public let timeunit: TimeUnit
)
```

- **@param** `value` The amount
- **@param** `timeunit` The time unit

#### Instance properties

##### `duration`

```cj
public prop duration: Option<Duration>
```

- **@return** The `Duration` corresponding to this `TimeDuration`; returns `None` if the unit does not support fixed-length conversion (`WEEK`/`MONTH`/`YEAR`)

##### `ago`

```cj
public prop ago: DateTime
```

- **@return** The `DateTime` obtained by moving this `TimeDuration` backwards from the current time

##### `later`

```cj
public prop later: DateTime
```

- **@return** The `DateTime` obtained by moving this `TimeDuration` forwards from the current time

#### Instance methods

##### `before`

```cj
public func before(t: DateTime)
```

Move this `TimeDuration` backwards relative to `t`.

- **@param** `t` Base time
- **@return** A `DateTime` in the past

##### `after`

```cj
public func after(t: DateTime)
```

Move this `TimeDuration` forwards relative to `t`.

- **@param** `t` Base time
- **@return** A `DateTime` in the future

---

### Interface `DurationCategory` and the `Int64` extension

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

Adds the "number + unit" DSL to `Int64`, for example `5.seconds`, `2.minutes`, `1.day`; every property returns a `TimeDuration`. Singular and plural are synonyms (`second` == `seconds`).

---

### Interface `ExtendDateTime` and the `DateTime` extension

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

Convenience methods added to `DateTime`.

#### Static properties

##### `currentDuration`

```cj
public static prop currentDuration: Duration
```

- **@return** The `Duration` corresponding to the Unix timestamp of the current instant

##### `today`

```cj
public static prop today: DateTime
```

- **@return** The `DateTime` of today 00:00:00.000000

##### `yesterday`

```cj
public static prop yesterday: DateTime
```

- **@return** The `DateTime` of yesterday 00:00:00.000000 (= `today - Duration.day`)

##### `tomorrow`

```cj
public static prop tomorrow: DateTime
```

- **@return** The `DateTime` of tomorrow 00:00:00.000000 (= `today + Duration.day`)

#### Instance methods

##### `addMilliseconds`

```cj
public func addMilliseconds(millis: Int64): DateTime
```

- **@param** `millis` Number of milliseconds
- **@return** The `DateTime` after adding `millis` milliseconds

##### `addMicroseconds`

```cj
public func addMicroseconds(micros: Int64): DateTime
```

- **@param** `micros` Number of microseconds
- **@return** The `DateTime` after adding `micros` microseconds

##### `setYear`

```cj
public func setYear(year: Int64): DateTime
```

- **@param** `year` The new year
- **@return** A new `DateTime` with the year replaced (other fields unchanged)

##### `setMonth`

```cj
public func setMonth(month: Int64): DateTime
public func setMonth(month: Month): DateTime
```

- **@param** `month` The new month (`Int64` or `Month`)
- **@return** A new `DateTime` with the month replaced

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

Return a new `DateTime` with the corresponding field replaced.

- `setMillisecond` writes `millis` multiplied by `1_000_000` into `nanosecond`
- `setMicrosecond` writes `micros` multiplied by `1_000` into `nanosecond`

##### `toUnixEpochSeconds`

```cj
public func toUnixEpochSeconds(): Int64
```

- **@return** The Unix timestamp of the current `DateTime` (seconds)

##### `toUnixEpochMillis`

```cj
public func toUnixEpochMillis(): Int64
```

- **@return** The Unix timestamp of the current `DateTime` (milliseconds)

##### `toUnixEpochMicros`

```cj
public func toUnixEpochMicros(): Int64
```

- **@return** The Unix timestamp of the current `DateTime` (microseconds)

##### `toUnixEpochNanos`

```cj
public func toUnixEpochNanos(): Int64
```

- **@return** The Unix timestamp of the current `DateTime` (nanoseconds)

#### Instance properties

##### `isLeapYear`

```cj
public prop isLeapYear: Bool
```

- **@return** Whether the year of the current `DateTime` is a leap year

##### `isLastMonthDay`

```cj
public prop isLastMonthDay: Bool
```

- **@return** Whether the current `DateTime` is the last day of its month

---

### Interface `ExtendDayOfWeek` and the `DayOfWeek` extension

```cj
public interface ExtendDayOfWeek {
    operator func -(day: DayOfWeek): Int64
}

extend DayOfWeek <: ExtendDayOfWeek {
    public operator func -(day: DayOfWeek): Int64
}
```

Adds the `-` operator to `DayOfWeek`, returning the difference between two day-of-week ordinals.

- **@param** `day` Another `DayOfWeek`
- **@return** `this.toInteger() - day.toInteger()`

---

### Interface `ExtendDuration` and the `Duration` extension

```cj
public interface ExtendDuration {
    prop ago: DateTime
    prop later: DateTime
    func before(current: DateTime): DateTime
    func after(current: DateTime): DateTime
}

extend Duration <: ExtendDuration { ... }
```

Adds "past/future relative to the current instant" semantics to `Duration`.

#### Instance properties

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

#### Instance methods

##### `before`

```cj
public func before(current: DateTime): DateTime
```

- **@param** `current` Base time
- **@return** `current - this`

##### `after`

```cj
public func after(current: DateTime): DateTime
```

- **@param** `current` Base time
- **@return** `current + this`

---

### Interface `ExtendMonth` and the `Month` extension

```cj
public interface ExtendMonth {
    operator func -(month: Month): Int64
}

extend Month <: ExtendMonth {
    public operator func -(month: Month): Int64
}
```

Adds the `-` operator to `Month`, returning the difference between two month ordinals.

- **@param** `month` Another `Month`
- **@return** `this.toInteger() - month.toInteger()`

---

### Interface `ExtendTimeZone` and the `TimeZone` extension

```cj
public interface ExtendTimeZone {
    static prop Z: TimeZone
}

extend TimeZone <: ExtendTimeZone {
    public static prop Z: TimeZone
}
```

Adds the UTC "Z" time zone constant to `TimeZone`.

#### Static properties

##### `Z`

```cj
public static prop Z: TimeZone
```

- **@return** A UTC `TimeZone` instance with offset 0 and the name `"Z"`

---

## Usage example

```cj
import fountain::f_time.*
import std.time.*

// TimeUnit parsing
let unit = TimeUnit.parse("minute")        // MINUTE
let opt  = TimeUnit.tryParse("Foo")         // None<TimeUnit>

// Whole-point alignment and next/previous whole points
let now      = DateTime.now()
let trimmed  = TimeUnit.MINUTE.trim(now)
let nextMin  = TimeUnit.MINUTE.next()      // The next whole minute
let prevHour = TimeUnit.HOUR.prev(duration: 2)

// Int64 DSL
let d1 = 5.seconds.later                    // The DateTime 5 seconds from now
let d2 = 2.minutes.ago                     // The DateTime 2 minutes ago
let dur = 1.day.duration                   // Some(Duration.day)
let bad = 1.month.duration                 // None<Duration> (MONTH has no fixed length)

// DateTime extensions
let today    = DateTime.today
let tomorrow = DateTime.tomorrow
let leap     = today.isLeapYear
let epochSec = DateTime.now().toUnixEpochSeconds()

// Duration extensions
let past  = Duration.minute.ago
let future = Duration.hour.later
let shifted = Duration.day.before(DateTime.tomorrow)

// DayOfWeek / Month operators
let dowDiff = DayOfWeek.Monday - DayOfWeek.Sunday    // 1
let monDiff = Month.January - Month.December          // -11

// UTC time zone
let utc = TimeZone.Z
```
