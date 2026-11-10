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
package fountain::f_chart

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ChartException_test {
    /** 异常携带可区分的错误类别。 */
    @TestCase
    public func keepsErrorKind(): Unit {
        let e = ChartException("series 不能为空", kind: ChartErrorKind.MissingField)
        @Assert(e.kind == ChartErrorKind.MissingField)
    }

    /** 字段路径拼进消息，便于定位。 */
    @TestCase
    public func prefixesFieldPath(): Unit {
        let e = ChartException("必须是数字", kind: ChartErrorKind.InvalidValue, path: "series[0].data[2]")
        @Assert(e.path == "series[0].data[2]")
        @Assert(e.message.contains("series[0].data[2]"))
        @Assert(e.message.contains("必须是数字"))
    }

    /** 无路径时不添加前缀。 */
    @TestCase
    public func keepsMessageWithoutPath(): Unit {
        let e = ChartException("未知图类型")
        @Assert(e.path == "")
        @Assert(e.message == "未知图类型")
        @Assert(e.kind == ChartErrorKind.InvalidValue)
    }
}
