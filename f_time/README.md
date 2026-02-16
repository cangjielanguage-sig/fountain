时间扩展

```cj
2.days.ago
3.hours.later
let date = DateTime.now()
3.minutes.before(date)//指定时间的3分钟前
5.weeks.after(date)//指定时间的5星期前
//支持的时间单位：nanoseconds nanosecond microseconds microsecond milliseconds millisecond seconds second minutes minute hours hour days day weeks week

DateTime.currentDuration //当前时间相对于DateTime.UnixEpoch的Duration
DateTime.yesterday //昨天零点整
DateTime.today//今天零点整
DateTime.tomorrow//明天零点整
let millis = 1000
date.addMilliseconds(millis)//为date增加millis毫秒数，millis可以是负数
let micros = 1000
date.addMicroseconds(micros)//为date增加micros微秒数，micros可以是负数
date.setYear(2026)//把date年份改为指定值
date.setMonth(1)//把date月份改为指定值
date.setDay(1)//把date日期改为指定值
date.setHour(0)//把date小时改为指定值
date.setMinute(0)//把date分钟改为指定值
date.setSecond(0)//把date秒改为指定值
date.setMillisecond(0)//把date毫秒改为指定值
date.setMicrosecond(0)//把date微秒改为指定值
date.setNanosecond(0)//把date纳秒改为指定值
date.isLeapYear //返回当前年份是否闰年
date.isLastMonthDay //返回当前时间是不是当月最后一天
date.toUnixEpochSecond() //返回当前时间相对UnixEpoch秒数
date.toUnixEpochMillis() //返回当前时间相对UnixEpoch毫秒数
date.toUnixEpochMicros() //返回当前时间相对UnixEpoch微秒数
date.toUnixEpochNanos() //返回当前时间相对UnixEpoch纳秒数
```
