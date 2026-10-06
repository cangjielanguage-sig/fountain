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
package fountain::f_orm.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * `Condition.trim` / `SET` / `WHERE` / `emptyLogicalExpr` 的输出契约（bug.md §2.12 / ORM-5）。
 *
 * 修复把三处「每次拼片段都插值构造正则 pattern、收集 flags、再查正则缓存」换成预编译常量
 * （`Condition` 三个、`TableClause` 两个、`imports.cj` 一个），模式文本与替换串一字未改。
 *
 * 本用例的期望值取自**修复前实测**（探针 `.autocode/tmp/orm5-probe-before.log` /
 * `-after.log`；两侧 118 行输出规范化后逐字符一致），用于把「输出不变」钉在用例里。
 */
@Test
public class ConditionTrimTest {
    /** 内部组合 (',', ',')：裁掉首尾逗号及其两侧空白，中段与关键字不动 */
    @TestCase
    public func testTrimComma(): Unit {
        @Assert('', Condition.trim(prefix: ',', suffix: ','){''})
        @Assert(' ', Condition.trim(prefix: ',', suffix: ','){' '})
        @Assert('a', Condition.trim(prefix: ',', suffix: ','){'a'})
        @Assert(' a ', Condition.trim(prefix: ',', suffix: ','){' a '})
        @Assert('and a', Condition.trim(prefix: ',', suffix: ','){'and a'})
        @Assert(' a ', Condition.trim(prefix: ',', suffix: ','){',a,'})
        @Assert(' a ', Condition.trim(prefix: ',', suffix: ','){' , a , '})
        @Assert('a and', Condition.trim(prefix: ',', suffix: ','){'a and'})
    }

    /** 内部组合 ('and|or', 'and|or')：裁掉首尾的 and/or（大小写不敏感），逗号不动 */
    @TestCase
    public func testTrimAndOr(): Unit {
        @Assert(' a', Condition.trim(prefix: 'and|or', suffix: 'and|or'){'and a'})
        @Assert('a ', Condition.trim(prefix: 'and|or', suffix: 'and|or'){'a and'})
        @Assert(' ', Condition.trim(prefix: 'and|or', suffix: 'and|or'){'and'})
        @Assert(' ', Condition.trim(prefix: 'and|or', suffix: 'and|or'){'or'})
        @Assert(' a ', Condition.trim(prefix: 'and|or', suffix: 'and|or'){' AND a OR '})
        @Assert(' a ', Condition.trim(prefix: 'and|or', suffix: 'and|or'){'and a and'})
        @Assert(',a,', Condition.trim(prefix: 'and|or', suffix: 'and|or'){',a,'})
        @Assert('x a y', Condition.trim(prefix: 'and|or', suffix: 'and|or'){'x a y'})
    }

    /** 内部组合 ('', '')（`LoopCondition` 默认）：既有口径=把首尾空白各规范化为一个空格 */
    @TestCase
    public func testTrimSpaces(): Unit {
        @Assert(' ', Condition.trim(prefix: '', suffix: ''){''})
        @Assert(' a ', Condition.trim(prefix: '', suffix: ''){'a'})
        @Assert(' a  ', Condition.trim(prefix: '', suffix: ''){' a '})
        @Assert(' and a  ', Condition.trim(prefix: '', suffix: ''){'and a'})
    }

    /** 自定义组合仍走原动态构造路径（pattern 由 prefix/suffix 插值而来），期望值取自探针矩阵实测 */
    @TestCase
    public func testTrimCustomCombination(): Unit {
        @Assert(' a ', Condition.trim(prefix: 'x|y', suffix: 'x|y'){'x a y'})
        @Assert('or a', Condition.trim(prefix: 'x|y', suffix: 'x|y'){'or a'})
    }

    /** `SET`：先按 (',', ',') 裁剪，非空才包 ` SET … ` */
    @TestCase
    public func testSetOutput(): Unit {
        @Assert('', Condition.SET{''})
        @Assert(' SET a ', Condition.SET{'a'})
        @Assert(' SET and a ', Condition.SET{'and a'})
        @Assert(' SET  a  ', Condition.SET{',a,'})
    }

    /** `WHERE`：先按 ('and|or', 'and|or') 裁剪，非空才包 ` WHERE … ` */
    @TestCase
    public func testWhereOutput(): Unit {
        @Assert('', Condition.WHERE{''})
        @Assert(' WHERE  a ', Condition.WHERE{'and a'})
        @Assert(' WHERE a  ', Condition.WHERE{'a and'})
        @Assert(' WHERE   ', Condition.WHERE{'and'})
        @Assert(' WHERE x a y ', Condition.WHERE{'x a y'})
    }

    /** `emptyLogicalExpr`：只由空白与括号组成才算空（`appendPartial` 靠它决定是否拼关键字） */
    @TestCase
    public func testEmptyLogicalExpr(): Unit {
        @Assert(true, emptyLogicalExpr(''))
        @Assert(true, emptyLogicalExpr(' '))
        @Assert(true, emptyLogicalExpr('   '))
        @Assert(true, emptyLogicalExpr('()'))
        @Assert(false, emptyLogicalExpr('a'))
        @Assert(false, emptyLogicalExpr(' a '))
        @Assert(false, emptyLogicalExpr('and'))
        @Assert(false, emptyLogicalExpr(',a,'))
    }
}
