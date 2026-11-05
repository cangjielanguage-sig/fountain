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
public class SvgViewBox_test {
    /** 四参数与分隔符。 */
    @TestCase
    public func parseForms(): Unit {
        let spaced = SvgViewBox.parse("0 0 200 100")
        @Assert(spaced.minX == 0.0 && spaced.minY == 0.0)
        @Assert(spaced.width == 200.0 && spaced.height == 100.0)
        let commas = SvgViewBox.parse("-10,-20,300,400")
        @Assert(commas.minX == -10.0 && commas.minY == -20.0)
        @Assert(commas.width == 300.0 && commas.height == 400.0)
        let mixed = SvgViewBox.parse("  0, 0  200,100  ")
        @Assert(mixed.width == 200.0 && mixed.height == 100.0)
        let decimals = SvgViewBox.parse("0.5 0.5 1.5 2.5")
        @Assert(decimals.minX == 0.5 && decimals.height == 2.5)
    }

    /** 非法输入：个数错误、非数字、零/负宽高。 */
    @TestCase
    public func invalidInputs(): Unit {
        let bad = ["", "0 0 0", "0 0 100", "0 0 100 50 1", "a b c d", "0 0 -100 50", "0 0 100 -50", "0 0 0 50", "0 0 100 0"]
        for (text in bad) {
            let current = text
            let error = expectSvgException({=> SvgViewBox.parse(current)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
        }
    }

    /** 规范序列化与往返。 */
    @TestCase
    public func serialization(): Unit {
        @Assert(SvgViewBox.parse("0,0,200,100").toString() == "0 0 200 100")
        @Assert(SvgViewBox.parse("-1.5 2 3 4").toString() == "-1.5 2 3 4")
        let viewBox = SvgViewBox(-1.0, 2.0, 3.0, 4.0)
        @Assert(SvgViewBox.parse(viewBox.toString()) == viewBox)
    }
}
