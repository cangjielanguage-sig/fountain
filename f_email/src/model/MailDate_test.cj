/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_email.model

import std.unittest.*
import std.unittest.testmacro.*
import std.time.TimeZone

@Test
public class MailDate_test {
    @TestCase
    public func twoDigitYear(): Unit {
        let date = MailDate.parse("Wed, 28 Oct 99 21:58:52 +0800")
        @Assert(date.dateTime.year, 1999)
    }

    @TestCase
    public func twoDigitYearLowerBound(): Unit {
        @Assert(MailDate.parse("1 Jan 49 00:00:00 +0000").dateTime.year, 2049)
        @Assert(MailDate.parse("1 Jan 50 00:00:00 +0000").dateTime.year, 1950)
    }

    @TestCase
    public func missingZoneDefaultsToUtcWithWarning(): Unit {
        let date = MailDate.parse("28 Oct 2026 21:58:52")
        @Assert(date.offsetMinutes, 0)
        @Assert(date.warnings.size > 0, true)
    }

    @TestCase
    public func monthIsCaseInsensitive(): Unit {
        let date = MailDate.parse("28 oCT 2026 21:58:52 +0800")
        @Assert(date.dateTime.month.toString(), "October")
    }

    @TestCase
    public func weekdayMayBeOmitted(): Unit {
        let date = MailDate.parse("28 Oct 2026 21:58:52 +0800")
        @Assert(date.dateTime.dayOfMonth, 28)
        @Assert(date.offsetMinutes, 480)
    }

    @TestCase
    public func commentsAreIgnored(): Unit {
        let date = MailDate.parse("Wed, 28 Oct 2026 21:58:52 +0800 (CST)")
        @Assert(date.dateTime.year, 2026)
        @Assert(date.offsetMinutes, 480)
    }

    @TestCase
    public func usZoneAbbreviations(): Unit {
        @Assert(MailDate.parse("28 Oct 2026 12:00:00 EST").offsetMinutes, -300)
        @Assert(MailDate.parse("28 Oct 2026 12:00:00 PDT").offsetMinutes, -420)
        @Assert(MailDate.parse("28 Oct 2026 12:00:00 GMT").offsetMinutes, 0)
    }

    @TestCase
    public func invalidDateFallsBackInLenientMode(): Unit {
        let date = MailDate.parse("not a date")
        @Assert(date.dateTime.year, 1970)
        @Assert(date.warnings.size > 0, true)
    }

    @TestCase
    public func invalidDateThrowsInStrictMode(): Unit {
        var caught = false
        try {
            MailDate.parse("not a date", strict: true)
        } catch (_: MimeException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func toStringRoundTrips(): Unit {
        let original = MailDate.parse("Wed, 28 Oct 2026 21:58:52 +0800")
        let text = original.toString()
        let again = MailDate.parse(text)
        @Assert(again.dateTime.year, 2026)
        @Assert(again.dateTime.hour, 21)
        @Assert(again.offsetMinutes, 480)
        @Assert(again.toString(), text)
    }

    @TestCase
    public func toUtcShiftsByOffset(): Unit {
        let date = MailDate.parse("28 Oct 2026 21:58:52 +0800")
        let utc = date.toUtc()
        @Assert(utc.zone.id, TimeZone.UTC.id)
        @Assert(utc.hour, 13)
    }

    @TestCase
    public func nowProducesParseableString(): Unit {
        let now = MailDate.now()
        let parsed = MailDate.parse(now.toString())
        @Assert(parsed.dateTime.year, now.dateTime.year)
        @Assert(parsed.offsetMinutes, now.offsetMinutes)
    }
}
