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

@Test
public class M3Index_test {
    private static let SST: String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
        "<sst xmlns=\"${NS_MAIN}\" count=\"4\" uniqueCount=\"3\">" +
        "<si><t>alpha</t></si>" +
        "<si><r><rPr><b/></rPr><t>粗</t></r><r><t>细</t></r></si>" +
        "<si><t>beta</t></si>" +
        "</sst>"

    private static func streamBytes(): Array<Byte> {
        let rows = "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>2</v></c></row>" +
            "<row r=\"2\"><c r=\"A2\" t=\"s\"><v>1</v></c><c r=\"B2\" t=\"s\"><v>0</v></c></row>"
        let sheetXml = worksheetXml(rows)
        buildXlsx([sheetXml], parts: [("xl/sharedStrings.xml", SST)])
    }

    @TestCase
    public func indexReadsEntriesOnDemand(): Unit {
        let index = SharedStringIndex.build(SST.toArray())
        try {
            @Assert(index.size(), 3)
            @Assert(index.get(0).getOrThrow(), "alpha")
            @Assert(index.get(1).getOrThrow(), "粗细")
            @Assert(index.get(2).getOrThrow(), "beta")
            @Assert(index.get(0).getOrThrow(), "alpha")
            @Assert(index.get(99).isNone(), true)
            @Assert(index.runsAt(1).size, 2)
        } finally {
            index.close()
        }
    }

    @TestCase
    public func streamWithIndexMatchesFullTable(): Unit {
        let data = streamBytes()
        let full = ExcelSheetStream.open(ByteBuffer(data))
        let indexed = ExcelSheetStream.open(ByteBuffer(data), options: indexOptions())
        try {
            let fullReader = full.rows("Sheet1").getOrThrow()
            let indexReader = indexed.rows("Sheet1").getOrThrow()
            while (let Some(row) <- fullReader.next()) {
                let other = indexReader.next().getOrThrow()
                @Assert(row.cells.size, other.cells.size)
                for (i in 0..row.cells.size) {
                    @Assert(row.cells[i].value.toString(), other.cells[i].value.toString())
                }
            }
            @Assert(indexReader.next().isNone(), true)
        } finally {
            full.close()
            indexed.close()
        }
    }

    @TestCase
    public func indexRepeatedLookupsAreCached(): Unit {
        let index = SharedStringIndex.build(SST.toArray())
        try {
            for (_ in 0..100) {
                @Assert(index.get(2).getOrThrow(), "beta")
            }
            @Assert(index.get(0).getOrThrow(), "alpha")
        } finally {
            index.close()
        }
    }

    @TestCase
    public func streamWarningsDoNotMentionDegrade(): Unit {
        let stream = ExcelSheetStream.open(ByteBuffer(streamBytes()), options: indexOptions())
        try {
            var degraded = false
            for (warning in stream.warnings()) {
                if (warning.kind == ExcelWarningKind.IndexDegraded) {
                    degraded = true
                }
            }
            @Assert(degraded, false)
        } finally {
            stream.close()
        }
    }

    private static func indexOptions(): ExcelStreamReadOptions {
        let options = ExcelStreamReadOptions()
        options.sharedStringsIndex = true
        options
    }
}
