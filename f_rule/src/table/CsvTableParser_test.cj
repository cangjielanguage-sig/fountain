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
package fountain::f_rule.table

import std.fs.{File, Path}
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * CSV 载体解析（`doc/07-decision-table.md` §5，用例 T-01~T-04）。
 *
 * 覆盖 RFC 4180 引号/换行、`#` 注释与元数据、行号定位、BOM 与非 UTF-8。
 */
@Test
class CsvTableParser_test {
    private func csv(lines: Array<String>): String {
        var out = ""
        for (line in lines) {
            out += line + "\n"
        }
        out
    }

    private func sample(lines: Array<String>): String {
        csv(lines)
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        try {
            action()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** T-01：元数据、表头、数据行与物理行号。 */
    @TestCase
    public func parsesBasicTable(): Unit {
        let text = csv([
            "# f_rule decision table v1",
            "# id: pricing",
            "# name: 订单折扣",
            "# version: v1",
            "# factSpace: orders",
            "# factType: Order",
            "# hitPolicy: First",
            "# salience: 100",
            "id,name,when.order.level,when.order.amount,then.discount,then.event",
            "R1,VIP,>=3,>200,0.85,order.discounted",
            "R2,普通,>=1,>500,0.90,order.discounted",
            "R3,兜底,,,1.0,order.discounted"
        ])
        let table = CsvTableParser.parse(text)

        @Assert(table.id, "pricing")
        @Assert(table.name, "订单折扣")
        @Assert(table.version, "v1")
        @Assert(table.factSpace, "orders")
        @Assert(table.factType, "Order")
        @Expect(table.hitPolicy, HitPolicy.First)
        @Expect(table.salience, 100)
        @Assert(table.columns.size, 6)
        @Expect(table.columns[0].kind, ColumnKind.Metadata)
        @Expect(table.columns[2].kind, ColumnKind.When)
        @Assert(table.columns[2].binding, "order")
        @Expect(table.columns[4].kind, ColumnKind.Then)
        @Assert(table.rows.size, 3)
        @Assert(table.rows[0].ruleId, "R1")
        @Assert(table.rows[0].line, 10)
        @Assert(table.rows[2].ruleId, "R3")
        @Assert(table.rows[2].line, 12)
        @Expect(table.rows[2].values[2].isNone(), true)
        @Expect(table.rows[2].values[2].isNone(), true)
        @Expect(table.rows[1].values[3].getOrThrow(), ">500")
    }

    /** T-03：无冒号的 `#` 行是注释；键大小写不敏感。 */
    @TestCase
    public func skipsCommentsAndParsesMetadata(): Unit {
        let text = csv([
            "# just a comment, with comma",
            "# ID: users",
            "# HitPolicy: Collect",
            "when.level,then.tier",
            ">=3,gold"
        ])
        let table = CsvTableParser.parse(text)
        @Assert(table.id, "users")
        @Expect(table.hitPolicy, HitPolicy.Collect)
        @Assert(table.rows.size, 1)
        @Assert(table.rows[0].ruleId, "R1")
        @Assert(table.rows[0].line, 5)
    }

    /** T-02：引号包裹、`""` 转义、单元格内逗号与换行。 */
    @TestCase
    public func handlesQuotedCells(): Unit {
        let text = csv([
            "# id: quotes",
            "id,then.note",
            "R1,\"a,\"\"b\"\"\"",
            "R2,\"line1",
            "line2\""
        ])
        let table = CsvTableParser.parse(text)
        @Assert(table.rows.size, 2)
        @Expect(table.rows[0].values[1].getOrThrow(), "a,\"b\"")
        @Expect(table.rows[1].values[1].getOrThrow(), "line1\nline2")
        // 多行单元格占两个物理行，后续行号随之顺延
        @Assert(table.rows[1].line, 4)
    }

    /** `\r\n` 行尾等价于 `\n`。 */
    @TestCase
    public func acceptsCrLf(): Unit {
        let text = "# id: crlf\r\nwhen.level,then.tier\r\n>=3,gold\r\n"
        let table = CsvTableParser.parse(text)
        @Assert(table.rows.size, 1)
        @Expect(table.rows[0].values[0].getOrThrow(), ">=3")
    }

    /** T-04：列数不一致抛 `TABLE_INVALID` 且带物理行号。 */
    @TestCase
    public func rejectsColumnCountMismatch(): Unit {
        let text = csv([
            "# id: broken",
            "when.a,then.b,then.c",
            "x,y" // 第 3 行
        ])
        var message = ""
        try {
            let _ = CsvTableParser.parse(text)
        } catch (e: RuleException) {
            @Expect(e.code, RuleErrorCode.TABLE_INVALID)
            message = e.message
        }
        @Expect(message.contains("line=3"), true)
    }

    /** 未知表头列抛 `TABLE_INVALID` 并指出列名。 */
    @TestCase
    public func rejectsUnknownHeader(): Unit {
        var message = ""
        try {
            let _ = CsvTableParser.parse(csv(["# id: bad", "mystery.col,then.a", "1,x"]))
        } catch (e: RuleException) {
            message = e.message
        }
        @Expect(message.contains("mystery.col"), true)
    }

    /** 缺 `# id` 元数据无法建表。 */
    @TestCase
    public func requiresIdMetadata(): Unit {
        @Expect(codeOf({ => CsvTableParser.parse(csv(["when.a,then.b", "1,x"])) }),
            RuleErrorCode.TABLE_INVALID)
    }

    /** BOM 被跳过，首列名不带 BOM 字符。 */
    @TestCase
    public func stripsUtf8Bom(): Unit {
        let text = String.fromUtf8([0xEFu8, 0xBBu8, 0xBFu8]) + csv(["# id: bom", "when.a,then.b", "1,x"])
        let table = CsvTableParser.parse(text)
        @Assert(table.columns[0].name, "when.a")
        @Assert(table.rows.size, 1)
    }

    /** 空表（只有表头）可以解析，编译期再拒绝（T-15）。 */
    @TestCase
    public func parsesHeaderOnlyTable(): Unit {
        let table = CsvTableParser.parse(csv(["# id: empty", "when.a,then.b"]))
        @Assert(table.rows.size, 0)
    }

    /** `parseFile` 读取 UTF-8 文件。 */
    @TestCase
    public func parsesFile(): Unit {
        let path = tempPath("valid")
        File.writeTo(path, csv(["# id: fromfile", "when.a,then.b", "1,x"]).toArray())
        let table = CsvTableParser.parseFile(Path(path))
        @Assert(table.id, "fromfile")
        @Assert(table.rows.size, 1)
    }

    /** 非 UTF-8 字节序列抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsNonUtf8File(): Unit {
        let path = tempPath("binary")
        File.writeTo(path, [0xFFu8, 0xFEu8, 0x00u8, 0x41u8])
        @Expect(codeOf({ => CsvTableParser.parseFile(Path(path)) }), RuleErrorCode.TABLE_INVALID)
    }

    private func tempPath(name: String): String {
        let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        "/tmp/f_rule_table_${name}_${stamp}.csv"
    }
}
