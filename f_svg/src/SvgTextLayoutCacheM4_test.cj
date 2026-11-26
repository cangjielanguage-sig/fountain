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

/** 统计 `advance` 调用次数的字体；每次完整 layout 对每个字形调用一次。 */
private class M4CountingFont <: SvgFont {
    private let inner = SvgHersheyFont()
    var advanceCalls = 0

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        this.inner.glyphPath(codePoint, fontSize)
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        this.advanceCalls++
        this.inner.advance(codePoint, fontSize)
    }

    public func ascent(fontSize: Float64): Float64 {
        this.inner.ascent(fontSize)
    }

    public func descent(fontSize: Float64): Float64 {
        this.inner.descent(fontSize)
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        this.inner.glyphBounds(codePoint, fontSize)
    }
}

private func m4CountingOptions(font: M4CountingFont): SvgRenderOptions {
    let registry = SvgFontRegistry()
    registry.register("Hershey", font)
    SvgRenderOptions(samplesPerPixel: 1, fonts: Some(registry))
}

@Test
public class SvgTextLayoutCacheM4_test {
    /** 单个文本从构建显示列表到光栅化只布局一次。 */
    @TestCase
    public func singleTextRendersWithOneLayout(): Unit {
        let font = M4CountingFont()
        let options = m4CountingOptions(font)
        let plain = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red">A</text>',
            width: 30,
            height: 40
        )
        SvgRenderer(options: options).render(plain)
        @Assert(font.advanceCalls == 1)

        font.advanceCalls = 0
        let decorated = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration="underline">A</text>',
            width: 30,
            height: 40
        )
        SvgRenderer(options: options).render(decorated)
        @Assert(font.advanceCalls == 1)
    }

    /** 带装饰线的文本不得因为额外装饰计算放大布局次数。 */
    @TestCase
    public func decoratedTextLayoutCountStaysBounded(): Unit {
        let font = M4CountingFont()
        let options = m4CountingOptions(font)
        let plain = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red">A</text>',
            width: 30,
            height: 40
        )
        SvgRenderer(options: options).render(plain)
        let plainCalls = font.advanceCalls
        @Assert(plainCalls >= 1)

        font.advanceCalls = 0
        let decorated = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration="underline">A</text>',
            width: 30,
            height: 40
        )
        SvgRenderer(options: options).render(decorated)
        let decoratedCalls = font.advanceCalls
        @Assert(decoratedCalls * 2 <= plainCalls * 3)
    }

    /** 缓存不跨渲染：第二次渲染仍应重新布局。 */
    @TestCase
    public func layoutCacheDoesNotOutliveRender(): Unit {
        let font = M4CountingFont()
        let options = m4CountingOptions(font)
        let document = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red">A</text>',
            width: 30,
            height: 40
        )
        SvgRenderer(options: options).render(document)
        @Assert(font.advanceCalls == 1)
        font.advanceCalls = 0
        SvgRenderer(options: options).render(document)
        @Assert(font.advanceCalls == 1)
    }
}
