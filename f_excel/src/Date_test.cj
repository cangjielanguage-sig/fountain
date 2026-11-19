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
package fountain::f_excel

import std.io.ByteBuffer
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class DateFormat_test {
    @TestCase
    public func builtinDateIds(): Unit {
        for (id in 14..=22) {
            @Assert(isBuiltinDateFormat(id), true)
        }
        for (id in 45..=47) {
            @Assert(isBuiltinDateFormat(id), true)
        }
        @Assert(isBuiltinDateFormat(0), false)
        @Assert(isBuiltinDateFormat(13), false)
        @Assert(isBuiltinDateFormat(23), false)
    }

    @TestCase
    public func customCodes(): Unit {
        @Assert(isDateFormatCode("yyyy-mm-dd"), true)
        @Assert(isDateFormatCode("m/d/yy"), true)
        @Assert(isDateFormatCode("h:mm:ss"), true)
        @Assert(isDateFormatCode("yyyy年m月d日"), true)
        @Assert(isDateFormatCode("0.00"), false)
        @Assert(isDateFormatCode("[Red]0.00"), false)
        @Assert(isDateFormatCode("General"), false)
    }

    @TestCase
    public func elapsedMarkers(): Unit {
        @Assert(hasElapsedMarker("[h]:mm:ss"), true)
        @Assert(hasElapsedMarker("[hh]:mm"), true)
        @Assert(hasElapsedMarker("[Red][h]:mm"), true)
        @Assert(hasElapsedMarker("[Blue][mm]:ss"), true)
        @Assert(hasElapsedMarker("[Red]0.00"), false)
        @Assert(hasElapsedMarker("[$-409]h:mm"), false)
        @Assert(hasElapsedMarker("[h:ss]"), false)
        @Assert(hasElapsedMarker("[Color10]"), false)
    }
}

@Test
public class DateSerial_test {
    private static func ymd(dt: DateTime): String {
        "${dt.year}-${dt.month.toInteger()}-${dt.dayOfMonth} ${dt.hour}:${dt.minute}:${dt.second}"
    }

    @TestCase
    public func knownSerials(): Unit {
        @Assert(ymd(dateTimeFromSerial(1.0, false).getOrThrow()), "1900-1-1 0:0:0")
        @Assert(ymd(dateTimeFromSerial(59.0, false).getOrThrow()), "1900-2-28 0:0:0")
        @Assert(dateTimeFromSerial(60.0, false).isNone(), true)
        @Assert(ymd(dateTimeFromSerial(61.0, false).getOrThrow()), "1900-3-1 0:0:0")
        @Assert(ymd(dateTimeFromSerial(45231.5, false).getOrThrow()), "2023-11-1 12:0:0")
    }

    @TestCase
    public func date1904Base(): Unit {
        @Assert(ymd(dateTimeFromSerial(0.0, true).getOrThrow()), "1904-1-1 0:0:0")
        @Assert(excelSerialDays(1904, 1, 1, true), 0)
    }

    @TestCase
    public func serialRoundTrip(): Unit {
        let value = DateTime.ofUTC(year: 2023, month: 11, dayOfMonth: 1, hour: 12, minute: 30, second: 15, nanosecond: 0)
        let serial = serialFromDateTime(value, false)
        @Assert(serial, 45231.0 + 45015.0 / 86400.0)
        let back = dateTimeFromSerial(serial, false).getOrThrow()
        @Assert(ymd(back), "2023-11-1 12:30:15")
    }

    @TestCase
    public func dateStyleSelection(): Unit {
        let allDay = DateTime.ofUTC(year: 2023, month: 11, dayOfMonth: 1, hour: 0, minute: 0, second: 0, nanosecond: 0)
        let withTime = DateTime.ofUTC(year: 2023, month: 11, dayOfMonth: 1, hour: 12, minute: 0, second: 0, nanosecond: 0)
        @Assert(dateStyleFor(allDay, false), 14)
        @Assert(dateStyleFor(withTime, false), 22)
        let timeOnly = DateTime.ofUTC(year: 1899, month: 12, dayOfMonth: 31, hour: 8, minute: 0, second: 0, nanosecond: 0)
        @Assert(dateStyleFor(timeOnly, false), 20)
    }
}

@Test
public class DateRead_test {
    private static func docWith(serial: String, styleIndex: Int64, options!: ExcelReadOptions = ExcelReadOptions()): ExcelDocument {
        let sheet = worksheetXml("<row r=\"1\"><c r=\"A1\" s=\"${styleIndex}\"><v>${serial}</v></c></row>")
        let bytes = buildXlsx([sheet], parts: [("xl/styles.xml", stylesXml([0, 14]))])
        ExcelDocument(ByteBuffer(bytes), options: options)
    }

    @TestCase
    public func dateDetectedByStyle(): Unit {
        let doc = docWith("45231", 1)
        let value = doc.sheet("Sheet1").getOrThrow().cell("A1").getOrThrow()
        let text = match (value) {
            case Date(dt) => "${dt.year}-${dt.month.toInteger()}-${dt.dayOfMonth}"
            case _ => "not-date"
        }
        @Assert(text, "2023-11-1")
    }

    @TestCase
    public func autoDetectDisabled(): Unit {
        let options = ExcelReadOptions()
        options.autoDetectDate = false
        let doc = docWith("45231", 1, options: options)
        @Assert(match (doc.sheet("Sheet1").getOrThrow().cell("A1").getOrThrow()) {
            case Number(v) => v
            case _ => 0.0
        }, 45231.0)
    }

    @TestCase
    public func loadStylesDisabledDegrades(): Unit {
        let options = ExcelReadOptions()
        options.loadStyles = false
        let doc = docWith("45231", 1, options: options)
        @Assert(match (doc.sheet("Sheet1").getOrThrow().cell("A1").getOrThrow()) {
            case Number(_) => true
            case _ => false
        }, true)
        @Assert(doc.warnings()[0].kind, ExcelWarningKind.AutoDetectDateDisabled)
    }

    @TestCase
    public func serial60StaysNumber(): Unit {
        let doc = docWith("60", 1)
        @Assert(match (doc.sheet("Sheet1").getOrThrow().cell("A1").getOrThrow()) {
            case Number(v) => v
            case _ => 0.0
        }, 60.0)
        @Assert(doc.warnings()[0].kind, ExcelWarningKind.DateSerial60)
    }
}
