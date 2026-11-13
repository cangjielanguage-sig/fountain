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
public class SvgRenderOptionsM4_test {
    /** languages 默认值与既有字段默认值。 */
    @TestCase
    public func defaults(): Unit {
        let options = SvgRenderOptions()
        @Assert(options.languages.size == 1)
        @Assert(options.languages[0] == "en")
        @Assert(options.width == 0)
        @Assert(options.height == 0)
        @Assert(options.background.isNone())
        @Assert(options.samplesPerPixel == 4)
        @Assert(options.maxPixels == 64 * 1024 * 1024)
        @Assert(options.fonts.isNone())
        @Assert(options.devicePixelRatio == 1.0)
        @Assert(options.images.isNone())
        @Assert(options.antiAlias == SvgAntiAliasMode.Supersample)
    }

    /** 既有命名参数调用保持编译与语义。 */
    @TestCase
    public func existingNamedArguments(): Unit {
        let options = SvgRenderOptions(
            width: 10,
            height: 20,
            samplesPerPixel: 1,
            devicePixelRatio: 2.0,
            antiAlias: SvgAntiAliasMode.Analytic
        )
        @Assert(options.width == 10)
        @Assert(options.height == 20)
        @Assert(options.samplesPerPixel == 1)
        @Assert(options.devicePixelRatio == 2.0)
        @Assert(options.antiAlias == SvgAntiAliasMode.Analytic)
        @Assert(options.languages[0] == "en")
    }

    /** 自定义语言列表。 */
    @TestCase
    public func customLanguages(): Unit {
        let options = SvgRenderOptions(languages: ["zh-CN", "en"])
        @Assert(options.languages.size == 2)
        @Assert(options.languages[0] == "zh-CN")
        @Assert(options.languages[1] == "en")
        let empty = SvgRenderOptions(languages: [])
        @Assert(empty.languages.size == 0)
    }
}
