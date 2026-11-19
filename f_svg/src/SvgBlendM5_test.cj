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
public class SvgBlendM5_test {
    private static let ALL_NAMES: Array<(String, SvgMixBlendMode)> = [
        ("normal", SvgMixBlendMode.Normal),
        ("multiply", SvgMixBlendMode.Multiply),
        ("screen", SvgMixBlendMode.Screen),
        ("overlay", SvgMixBlendMode.Overlay),
        ("darken", SvgMixBlendMode.Darken),
        ("lighten", SvgMixBlendMode.Lighten),
        ("color-dodge", SvgMixBlendMode.ColorDodge),
        ("color-burn", SvgMixBlendMode.ColorBurn),
        ("hard-light", SvgMixBlendMode.HardLight),
        ("soft-light", SvgMixBlendMode.SoftLight),
        ("difference", SvgMixBlendMode.Difference),
        ("exclusion", SvgMixBlendMode.Exclusion)
    ]

    /** 12 种模式的解析与往返。 */
    @TestCase
    public func allModesRoundTrip(): Unit {
        for ((name, mode) in SvgBlendM5_test.ALL_NAMES) {
            let parsed = SvgMixBlendMode.fromName(name)
            @Assert(parsed.isSome())
            match (parsed) {
                case Some(value) =>
                    @Assert(value == mode)
                    @Assert(value.toString() == name)
                case None => @Fail("应解析 ${name}")
            }
            @Assert(SvgMixBlendMode.fromName(name.toAsciiLower()) == Some(mode))
        }
    }

    /** 未知取值返回 `None`。 */
    @TestCase
    public func unknownMode(): Unit {
        @Assert(SvgMixBlendMode.fromName("plus-lighter").isNone())
        @Assert(SvgMixBlendMode.fromName("").isNone())
        @Assert(SvgMixBlendMode.fromName("normal ").isSome())
    }

    /** 既有 `SvgBlendMode` 保持 5 个取值，不被新枚举扩展。 */
    @TestCase
    public func legacyBlendModeUnchanged(): Unit {
        @Assert(SvgBlendMode.Multiply.toString() == "multiply")
        @Assert(SvgBlendMode.fromName("normal").isSome())
        @Assert(SvgBlendMode.fromName("multiply").isSome())
        @Assert(SvgBlendMode.fromName("screen").isSome())
        @Assert(SvgBlendMode.fromName("darken").isSome())
        @Assert(SvgBlendMode.fromName("lighten").isSome())
        @Assert(SvgBlendMode.fromName("difference").isNone())
        @Assert(SvgBlendMode.fromName("color-dodge").isNone())
    }
}
