/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

func rfc1123(t: DateTime) {
    //Wed, 16 Nov 2022 14:57:48 +0800
    let offset = t.zoneOffset.toSeconds() / 3600
    let zoneId = if (offset == 0) {
        t.zoneId
    } else if (offset > 0) {
        if (offset < 10) {
            "+0${offset}00"
        } else {
            "+${offset}00"
        }
    } else if (offset > -10) {
        "-0${-offset}00"
    } else {
        "${offset}00"
    }
    "${t.dayOfWeek.toString()[0..3]}, ${t.dayOfMonth} ${t.month.toString()[0..3]} ${t.year} ${t.hour}:${t.minute}:${t.second} ${zoneId}"
}

func parseRfc1123(date: String): DateTime {
    let zoneIdx = date.lastIndexOf(" ").getOrThrow()
    let zoneId = date[zoneIdx + 1..zoneIdx + 3]
    let zone = if (zoneId == "GMT") {
        TimeZone(zoneId, Duration.Zero)
    } else if (zoneId.startsWith("+")) {
        TimeZone("", Duration.hour * (Int64.parse(zoneId[1..])))
    } else {
        TimeZone("", Duration.hour * (Int64.parse(zoneId)))
    }
    var start = 5
    var end = date.indexOf(" ", start).getOrThrow()
    let day = Int64.parse(date[start..end].trimAscii())
    start = end + 1
    end = date.indexOf(" ", start).getOrThrow()
    let month = match (date[start..end].trimAscii()) {
        case "Jan" => Month.January
        case "Feb" => Month.February
        case "Mar" => Month.March
        case "Apr" => Month.April
        case "May" => Month.May
        case "Jun" => Month.June
        case "Jul" => Month.July
        case "Aug" => Month.August
        case "Sep" => Month.September
        case "Oct" => Month.October
        case "Nov" => Month.November
        case "Dec" => Month.December
        case _ => throw UnreachableException()
    }
    start = end + 1
    end = date.indexOf(" ", start).getOrThrow()
    let year = Int64.parse(date[start..end])
    start = end + 1
    end = date.indexOf(":", start).getOrThrow()
    let hour = Int64.parse(date[start..end])
    start = end + 1
    end = date.indexOf(":", start).getOrThrow()
    let minute = Int64.parse(date[start..end])
    start = end + 1
    end = date.indexOf(" ", start).getOrThrow()
    let second = Int64.parse(date[start..end])

    //Wed, 16 Nov 2022 14:57:48 +0800
    //0123456789012345678901234567890
    DateTime.of(
        year: year,
        month: month,
        dayOfMonth: day,
        hour: hour,
        minute: minute,
        second: second,
        timeZone: zone
    )
}
