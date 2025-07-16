/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_util

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class CaseFormat_test {
    @TestCase
    public func test(): Unit {
        @Assert(CaseFormat.Pascal.convert("CaseFormat", CaseFormat.Camel), "caseFormat")
        @Assert(CaseFormat.Pascal.convert("CaseFormat", CaseFormat.LowerUnderScore), "case_format")
        @Assert(CaseFormat.Pascal.convert("CaseFormat", CaseFormat.UpperUnderScore), "CASE_FORMAT")
        @Assert(CaseFormat.Pascal.convert("CaseFormat", CaseFormat.LowerHyphen), "case-format")
        @Assert(CaseFormat.Pascal.convert("CaseFormat", CaseFormat.UpperHyphen), "CASE-FORMAT")

        @Assert(CaseFormat.Camel.convert("caseFormat", CaseFormat.Pascal), "CaseFormat")
        @Assert(CaseFormat.Camel.convert("caseFormat", CaseFormat.LowerUnderScore), "case_format")
        @Assert(CaseFormat.Camel.convert("caseFormat", CaseFormat.UpperUnderScore), "CASE_FORMAT")
        @Assert(CaseFormat.Camel.convert("caseFormat", CaseFormat.LowerHyphen), "case-format")
        @Assert(CaseFormat.Camel.convert("caseFormat", CaseFormat.UpperHyphen), "CASE-FORMAT")

        @Assert(CaseFormat.LowerUnderScore.convert("case_format", CaseFormat.Camel), "caseFormat")
        @Assert(CaseFormat.LowerUnderScore.convert("case_format", CaseFormat.Pascal), "CaseFormat")
        @Assert(CaseFormat.LowerUnderScore.convert("case_format", CaseFormat.UpperUnderScore), "CASE_FORMAT")
        @Assert(CaseFormat.LowerUnderScore.convert("case_format", CaseFormat.LowerHyphen), "case-format")
        @Assert(CaseFormat.LowerUnderScore.convert("case_format", CaseFormat.UpperHyphen), "CASE-FORMAT")

        @Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", CaseFormat.Camel), "caseFormat")
        @Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", CaseFormat.Pascal), "CaseFormat")
        @Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", CaseFormat.LowerUnderScore), "case_format")
        @Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", CaseFormat.LowerHyphen), "case-format")
        @Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", CaseFormat.UpperHyphen), "CASE-FORMAT")

        @Assert(CaseFormat.LowerHyphen.convert("case-format", CaseFormat.Camel), "caseFormat")
        @Assert(CaseFormat.LowerHyphen.convert("case-format", CaseFormat.Pascal), "CaseFormat")
        @Assert(CaseFormat.LowerHyphen.convert("case-format", CaseFormat.LowerUnderScore), "case_format")
        @Assert(CaseFormat.LowerHyphen.convert("case-format", CaseFormat.UpperUnderScore), "CASE_FORMAT")
        @Assert(CaseFormat.LowerHyphen.convert("case-format", CaseFormat.UpperHyphen), "CASE-FORMAT")

        @Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", CaseFormat.Camel), "caseFormat")
        @Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", CaseFormat.Pascal), "CaseFormat")
        @Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", CaseFormat.LowerUnderScore), "case_format")
        @Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", CaseFormat.UpperUnderScore), "CASE_FORMAT")
        @Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", CaseFormat.LowerHyphen), "case-format")
    }
}
