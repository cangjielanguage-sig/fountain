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
public class ExcelDocument_test {
    @TestCase
    public func defaultDocumentHasOneSheet(): Unit {
        let doc = ExcelDocument()
        @Assert(doc.sheetCount(), 1)
        @Assert(doc.sheetAt(0).getOrThrow().name, "Sheet1")
        @Assert(doc.date1904, false)
        @Assert(doc.sheetAt(1).isNone(), true)
        @Assert(doc.sheetAt(-1).isNone(), true)
    }

    @TestCase
    public func sheetManagement(): Unit {
        let doc = ExcelDocument()
        let added = doc.addSheet("明细")
        @Assert(added.name, "明细")
        @Assert(doc.sheetCount(), 2)
        @Assert(doc.sheet("明细").isSome(), true)
        @Assert(doc.renameSheet("明细", "明细2"), true)
        @Assert(doc.sheet("明细2").isSome(), true)
        @Assert(doc.renameSheet("不存在", "x"), false)
        @Assert(doc.removeSheet("明细2"), true)
        @Assert(doc.removeSheet("明细2"), false)
        var thrown = false
        try {
            doc.addSheet("Sheet1")
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    @TestCase
    public func zeroBytesRejected(): Unit {
        var message = ""
        try {
            ExcelDocument(ByteBuffer(Array<Byte>()))
        } catch (e: ExcelException) {
            message = e.message
        }
        @Assert(message.contains("不是有效的 xlsx 文件"), true)
    }

    @TestCase
    public func readsSheetsFromPackage(): Unit {
        let bytes = buildXlsx([worksheetXml(""), worksheetXml("")], names: ["一", "二"])
        let doc = ExcelDocument(ByteBuffer(bytes))
        @Assert(doc.sheetCount(), 2)
        @Assert(doc.sheet("一").isSome(), true)
        @Assert(doc.sheet("二").isSome(), true)
    }
}
