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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_zip.ZipReader

@Test
public class PackageReader_test {
    private static func infoOf(bytes: Array<Byte>): PackageInfo {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            PackageReader.read(reader)
        } finally {
            reader.close()
        }
    }

    @TestCase
    public func readsSheetNameAndPart(): Unit {
        let info = infoOf(buildXlsx([worksheetXml("")]))
        @Assert(info.sheets.size, 1)
        @Assert(info.sheets[0].name, "Sheet1")
        @Assert(info.sheets[0].partName, "xl/worksheets/sheet1.xml")
        @Assert(info.date1904, false)
    }

    @TestCase
    public func readsDate1904(): Unit {
        let info = infoOf(buildXlsx([worksheetXml("")], date1904: true))
        @Assert(info.date1904, true)
    }

    @TestCase
    public func handlesNamespacePrefix(): Unit {
        let prefixedWorkbook =
            "<?xml version=\"1.0\"?><x:workbook xmlns:x=\"${NS_MAIN}\" xmlns:r=\"${NS_REL}\">" +
                "<x:sheets><x:sheet name=\"数据\" sheetId=\"1\" r:id=\"rId1\"/></x:sheets></x:workbook>"
        let prefixedRels =
            "<?xml version=\"1.0\"?><p:Relationships xmlns:p=\"${NS_PKG_REL}\">" +
                "<p:Relationship Id=\"rId1\" Type=\"${NS_REL}/worksheet\" Target=\"worksheets/sheet1.xml\"/>" +
                "</p:Relationships>"
        let bytes = buildXlsx(
            [worksheetXml("")],
            names: ["数据"],
            parts: [("xl/workbook.xml", prefixedWorkbook), ("xl/_rels/workbook.xml.rels", prefixedRels)]
        )
        let info = infoOf(bytes)
        @Assert(info.sheets.size, 1)
        @Assert(info.sheets[0].name, "数据")
        @Assert(info.sheets[0].partName, "xl/worksheets/sheet1.xml")
    }

    @TestCase
    public func missingWorkbookThrows(): Unit {
        let bytes = buildXlsx([worksheetXml("")], includeWorkbook: false)
        var message = ""
        try {
            infoOf(bytes)
        } catch (e: ExcelException) {
            message = e.message
        }
        @Assert(message.contains("缺少 workbook.xml"), true)
    }

    @TestCase
    public func missingRelsSkipsSheetWithWarning(): Unit {
        let info = infoOf(buildXlsx([worksheetXml("")], includeRels: false))
        @Assert(info.sheets.size, 0)
        @Assert(info.warnings.size, 1)
        @Assert(info.warnings[0].kind, ExcelWarningKind.SheetEntryMissing)
    }
}
