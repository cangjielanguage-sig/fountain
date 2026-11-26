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
public class CssSelectorSpecificityM5_test {
    private func specificity(text: String): CssSpecificity {
        CssSelector.parse(text).specificity
    }

    /** 规范给出的六个基准值。 */
    @TestCase
    public func referenceValues(): Unit {
        @Assert(specificity("#a") == CssSpecificity(1, 0, 0))
        @Assert(specificity(".x.y") == CssSpecificity(0, 2, 0))
        @Assert(specificity("rect[data-x]") == CssSpecificity(0, 1, 1))
        @Assert(specificity(":first-child") == CssSpecificity(0, 0, 1))
        @Assert(specificity("*") == CssSpecificity(0, 0, 0))
        @Assert(specificity(":not(.x)") == CssSpecificity(0, 0, 1))
    }

    /** 属性选择器按类计分，各种运算符一致。 */
    @TestCase
    public func attributeOperators(): Unit {
        @Assert(specificity("[data-x]") == CssSpecificity(0, 1, 0))
        @Assert(specificity("[data-x=1]") == CssSpecificity(0, 1, 0))
        @Assert(specificity("[data-x~=1 i]") == CssSpecificity(0, 1, 0))
        @Assert(specificity("rect.a[data-x]#i") == CssSpecificity(1, 2, 1))
    }

    /** 结构伪类与否定伪类都只计 1 次类型。 */
    @TestCase
    public func pseudoCounting(): Unit {
        @Assert(specificity(":nth-child(2n+1)") == CssSpecificity(0, 0, 1))
        @Assert(specificity("rect:first-of-type") == CssSpecificity(0, 0, 2))
        @Assert(specificity(":not(#a)") == CssSpecificity(0, 0, 1))
        @Assert(specificity("#a.b[c]") == CssSpecificity(1, 2, 0))
        @Assert(specificity("rect:not(.x)") == CssSpecificity(0, 0, 2))
    }

    /** 组合器与分组：取分组最高值。 */
    @TestCase
    public func combinatorsAndGroups(): Unit {
        @Assert(specificity("g > rect + circle ~ #x") == CssSpecificity(1, 0, 3))
        let sheet = CssStyleSheet.parse("rect[data-x], #a.b { fill: red }")
        @Assert(sheet.rules[0].specificity() == CssSpecificity(1, 1, 0))
        let pseudo = CssStyleSheet.parse("rect:not(.x), circle { fill: red }")
        @Assert(pseudo.rules[0].specificity() == CssSpecificity(0, 0, 2))
    }
}
