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
package fountain::f_svg

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgException_test {
    /** 五种类别互不相等，且 toString 与枚举名一致。 */
    @TestCase
    public func kindsAreDistinct(): Unit {
        let kinds = [
            SvgErrorKind.Syntax,
            SvgErrorKind.InvalidValue,
            SvgErrorKind.Unsupported,
            SvgErrorKind.Security,
            SvgErrorKind.Limit
        ]
        for (i in 0..kinds.size) {
            for (j in 0..kinds.size) {
                @Assert((i == j) == (kinds[i] == kinds[j]))
            }
        }
        @Assert(SvgErrorKind.InvalidValue.toString() == "InvalidValue")
        @Assert(SvgErrorKind.Security.toString() == "Security")
    }

    /** 不带位置的构造：行列均为 0，elementPath 为 None。 */
    @TestCase
    public func withoutPosition(): Unit {
        let error = SvgException("坏了", kind: SvgErrorKind.Security)
        @Assert(error.kind == SvgErrorKind.Security)
        @Assert(error.line == 0)
        @Assert(error.column == 0)
        @Assert(error.elementPath.isNone())
        @Assert(error.message == "坏了")
    }

    /** 带位置的构造：消息追加位置，字段保留原始值。 */
    @TestCase
    public func withPosition(): Unit {
        let error = SvgException("坏了", 3, 7, kind: SvgErrorKind.Syntax, elementPath: Some("/svg[1]/g[1]"))
        @Assert(error.kind == SvgErrorKind.Syntax)
        @Assert(error.line == 3)
        @Assert(error.column == 7)
        @Assert(error.elementPath == Some("/svg[1]/g[1]"))
        @Assert(error.message == "坏了（第 3 行第 7 列）")
    }

    /** 位置为 0,0 时不追加位置后缀。 */
    @TestCase
    public func zeroPositionHasNoSuffix(): Unit {
        let error = SvgException("坏了", 0, 0)
        @Assert(error.message == "坏了")
    }
}
