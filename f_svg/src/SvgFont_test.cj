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
public class SvgFont_test {
    /** 注册表精确匹配、family 列表回退与 weight/style 回退。 */
    @TestCase
    public func registryResolution(): Unit {
        let registry = SvgFontRegistry()
        let font = SvgHersheyFont()
        registry.register("Custom", font)
        @Assert(registry.resolve("Custom", "normal", "normal").isSome())
        @Assert(registry.resolve("Custom", "bold", "italic").isSome())
        @Assert(registry.resolve("\"Custom\"", "normal", "normal").isSome())
        @Assert(registry.resolve("Missing, Custom", "normal", "normal").isSome())
        @Assert(registry.resolve("Missing", "normal", "normal").isNone())

        let defaultRegistry = SvgFontRegistry.defaultRegistry()
        @Assert(defaultRegistry.resolve("Hershey", "normal", "normal").isSome())
        @Assert(defaultRegistry.resolve("serif", "normal", "normal").isSome())
        @Assert(defaultRegistry.resolve("sans-serif", "normal", "normal").isSome())
        @Assert(defaultRegistry.resolve("monospace", "normal", "normal").isSome())

        let second = SvgFontRegistry.defaultRegistry()
        second.register("only-second", font)
        @Assert(second.resolve("only-second", "normal", "normal").isSome())
        @Assert(defaultRegistry.resolve("only-second", "normal", "normal").isNone())
    }

    /** ASCII 32–126 全覆盖、空格空字形、非 ASCII 返回 None。 */
    @TestCase
    public func hersheyCoverage(): Unit {
        let font = SvgHersheyFont()
        let space = font.glyphPath(32, 10.0)
        @Assert(space.isSome())
        match (space) {
            case Some(path) => @Assert(path.commands.size == 0)
            case None => @Fail("空格应返回空字形路径")
        }
        @Assert(font.advance(32, 10.0) > 0.0)
        for (codePoint in 33..=126) {
            @Assert(font.glyphPath(codePoint, 10.0).isSome())
            @Assert(font.glyphBounds(codePoint, 10.0).isSome())
            @Assert(font.advance(codePoint, 10.0) > 0.0)
        }
        @Assert(font.glyphPath(0x4E2D, 10.0).isNone())
        @Assert(font.glyphBounds(0x4E2D, 10.0).isNone())
    }

    /** 字号线性缩放与 ascent / descent。 */
    @TestCase
    public func hersheyScaling(): Unit {
        let font = SvgHersheyFont()
        let small = font.glyphBounds(65, 10.0) ?? SvgBounds.empty()
        let large = font.glyphBounds(65, 20.0) ?? SvgBounds.empty()
        @Assert(near(large.width, small.width * 2.0))
        @Assert(near(large.height, small.height * 2.0))
        @Assert(near(font.advance(65, 20.0), font.advance(65, 10.0) * 2.0))
        @Assert(near(font.ascent(10.0), 10.0))
        @Assert(font.descent(10.0) > 0.0)
        @Assert(near(font.ascent(20.0), 20.0))
        @Assert(near(font.descent(20.0), font.descent(10.0) * 2.0))
    }
}
