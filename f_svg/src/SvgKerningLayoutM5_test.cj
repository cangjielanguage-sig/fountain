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

import std.collection.*
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

internal let M5_TTF_BASE_TABLES: Array<String> = ["cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp"]

internal func m5TtfHead(): Array<Byte> {
    let w = M4ByteWriter()
    w.u32(0x00010000).u32(0x00010000).u32(0)
    w.u32(0x5F0F3CF5).u16(0).u16(1000)
    w.u32(0).u32(0).u32(0).u32(0)
    w.i16(0).i16(0).i16(100).i16(100)
    w.u16(0).u16(8).i16(2).i16(0).i16(0)
    w.toArray()
}

internal func m5TtfHhea(numMetrics: Int64): Array<Byte> {
    let w = M4ByteWriter()
    w.u32(0x00010000)
    w.i16(800).i16(-200).i16(0).u16(1000)
    w.i16(0).i16(0).i16(100).i16(100)
    w.i16(1).i16(0).i16(0).i16(0).i16(0).i16(0)
    w.i16(0).u16(numMetrics)
    w.toArray()
}

internal func m5TtfMaxp(numGlyphs: Int64): Array<Byte> {
    let w = M4ByteWriter()
    w.u32(0x00010000).u16(numGlyphs)
    w.toArray()
}

internal func m5TtfHmtx(advances: Array<Int64>): Array<Byte> {
    let w = M4ByteWriter()
    for (advance in advances) {
        w.u16(advance).i16(0)
    }
    w.toArray()
}

/** U+0041 / U+0056 / U+0066 / U+0069 → 字形 1..4。 */
internal func m5TtfCmap(): Array<Byte> {
    let codes = [65, 86, 102, 105]
    let w = M4ByteWriter()
    w.u16(0).u16(1).u16(3).u16(1).u32(12)
    w.u16(4)
    w.u16(16 + 8 * Int64(codes.size + 1))
    w.u16(0)
    w.u16(2 * Int64(codes.size + 1))
    w.u16(4).u16(1).u16(0)
    for (code in codes) {
        w.u16(code)
    }
    w.u16(0xFFFF)
    w.u16(0)
    for (code in codes) {
        w.u16(code)
    }
    w.u16(0xFFFF)
    for (index in 0..codes.size) {
        w.i16((index + 1) - codes[index])
    }
    w.i16(1)
    w.u16(0)
    for (_ in codes) {
        w.u16(0)
    }
    w.u16(0)
    w.toArray()
}

internal func m5TtfLoca(glyphCount: Int64): Array<Byte> {
    let w = M4ByteWriter()
    for (_ in 0..glyphCount + 1) {
        w.u16(0)
    }
    w.toArray()
}

/** 组装含可选 OpenType 布局表的 TTF。 */
internal func m5BuildLayoutTtf(
    advances: Array<Int64>,
    kern!: ?Array<Byte> = None,
    gpos!: ?Array<Byte> = None,
    gsub!: ?Array<Byte> = None
): Array<Byte> {
    let tables = HashMap<String, Array<Byte>>()
    let order = ArrayList<String>()
    for (tag in M5_TTF_BASE_TABLES) {
        order.add(tag)
    }
    tables["head"] = m5TtfHead()
    tables["hhea"] = m5TtfHhea(advances.size)
    tables["maxp"] = m5TtfMaxp(advances.size)
    tables["hmtx"] = m5TtfHmtx(advances)
    tables["loca"] = m5TtfLoca(advances.size)
    tables["cmap"] = m5TtfCmap()
    tables["glyf"] = Array<Byte>()
    let optional = [("kern", kern), ("GPOS", gpos), ("GSUB", gsub)]
    for ((tag, data) in optional) {
        match (data) {
            case Some(bytes) =>
                tables[tag] = bytes
                order.add(tag)
            case None => ()
        }
    }
    let headerSize = 12 + 16 * Int64(order.size)
    var offset = headerSize
    let offsets = HashMap<String, Int64>()
    let lengths = HashMap<String, Int64>()
    for (tag in order) {
        offset = (offset + 3) / 4 * 4
        offsets[tag] = offset
        let data = tables.get(tag).getOrThrow()
        lengths[tag] = Int64(data.size)
        offset += Int64(data.size)
    }
    let writer = M4ByteWriter()
    writer.u32(0x00010000).u16(Int64(order.size)).u16(128).u16(3).u16(32)
    for (tag in order) {
        writer.tag(tag).u32(0).u32(offsets.get(tag).getOrThrow()).u32(lengths.get(tag).getOrThrow())
    }
    for (tag in order) {
        writer.padding(4)
        for (byte in tables.get(tag).getOrThrow()) {
            writer.data.add(byte)
        }
    }
    writer.toArray()
}

internal func m5LayoutOf(svg: String, registry: SvgFontRegistry): SvgTextLayout {
    let document = SvgParser.parse(svg)
    let tree = SvgStyleResolver().compute(document.root)
    let element = document.elementsByTag("text")[0]
    let text = match (element) {
        case value: SvgTextElement => value
        case _ => throw invalidValue("不是文本元素")
    }
    let style = tree.get(element) ?? throw invalidValue("缺少文本样式")
    let renderer = SvgTextRenderer(registry: registry)
    renderer.layout(text, style: style, root: Some(document.root), styles: tree)
}

@Test
public class SvgKerningLayoutM5_test {
    /** kern 表按 unitsPerEm 换算到字号。 */
    @TestCase
    public func kernReducesAdvance(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf([500, 500, 500, 500, 500], kern: m5KernTable([(1, 2, -80)]))
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">AV</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 9.2) < 0.001)
    }

    /** font-kerning: none 关闭字距。 */
    @TestCase
    public func kerningNoneDisables(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf([500, 500, 500, 500, 500], kern: m5KernTable([(1, 2, -80)]))
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\" font-kerning=\"none\">AV</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 10.0) < 0.001)
    }

    /** GPOS 优先于 kern。 */
    @TestCase
    public func gposWinsOverKern(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500],
                kern: m5KernTable([(1, 2, -80)]),
                gpos: m5GposFormat1(1, 2, -200)
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">AV</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 8.0) < 0.001)
    }

    /** GPOS 存在但没有 `kern` 特性时回退 kern 表。 */
    @TestCase
    public func gposWithoutKernFallsBackToKern(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500],
                kern: m5KernTable([(1, 2, -80)]),
                gpos: m5GposFormat1Tagged("vkrn", 1, 2, -200)
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">AV</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 9.2) < 0.001)
    }

    /** GSUB 存在 Type 4 lookup 但没有 `liga` 特性时不替换。 */
    @TestCase
    public func gsubWithoutLigaDoesNotApply(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5GsubTagged("dlig", 3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">fi</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 10.0) < 0.001)
        @Assert(layout.glyphs.size == 2)
    }

    /** 跨 tspan 字号变化不配对。 */
    @TestCase
    public func crossTspanNoKerning(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf([500, 500, 500, 500, 500], kern: m5KernTable([(1, 2, -80)]))
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" font-size=\"10\">A" +
            "<tspan font-size=\"20\">V</tspan></text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 15.0) < 0.001)
    }

    /** GSUB liga：连字簇输出单个字形。 */
    @TestCase
    public func ligatureReplacesAdvance(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">fi</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 7.0) < 0.001)
        @Assert(layout.glyphs.size == 1)
        @Assert(abs(layout.glyphs[0].advance - 7.0) < 0.001)
    }

    /** 连字簇只消费簇首的 dx 列表项。 */
    @TestCase
    public func ligatureConsumesDxList(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\" dx=\"5 9\">fi</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 1)
        @Assert(abs(layout.advance - 12.0) < 0.001)
        @Assert(abs(layout.glyphs[0].x - 5.0) < 0.001)
    }

    /** 连字簇只消费簇首的 x 列表项，后续字形按逻辑位置定位。 */
    @TestCase
    public func ligatureConsumesXList(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\" x=\"10 20 30\">fiA</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 2)
        @Assert(abs(layout.glyphs[0].x - 10.0) < 0.001)
        @Assert(abs(layout.glyphs[1].x - 30.0) < 0.001)
        @Assert(abs(layout.advance - 35.0) < 0.001)
    }

    /** rotate 列表按逻辑字符绑定，连字消费簇首项。 */
    @TestCase
    public func ligatureConsumesRotateList(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\" rotate=\"10 20 30\">fiA</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 2)
        @Assert(abs(layout.glyphs[0].angle - 10.0) < 0.001)
        @Assert(abs(layout.glyphs[1].angle - 30.0) < 0.001)
    }

    /** 连字在逻辑序列上匹配，之后才做双向重排。 */
    @TestCase
    public func ligatureAppliedBeforeBidi(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\" direction=\"rtl\">fi</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 1)
        @Assert(abs(layout.advance - 7.0) < 0.001)
    }

    /** 字距作用于整形后的字形，不作用于被连字消费的字形。 */
    @TestCase
    public func kerningUsesShapedGlyphs(): Unit {
        let ignoredPairFont = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                kern: m5KernTable([(4, 1, -80)]),
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let ignoredRegistry = SvgFontRegistry()
        ignoredRegistry.register("Test", ignoredPairFont)
        let ignored = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">fiA</text></svg>",
            ignoredRegistry
        )
        @Assert(abs(ignored.advance - 12.0) < 0.001)

        let shapedPairFont = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                kern: m5KernTable([(10, 1, -100)]),
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let shapedRegistry = SvgFontRegistry()
        shapedRegistry.register("Test", shapedPairFont)
        let shaped = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">fiA</text></svg>",
            shapedRegistry
        )
        @Assert(abs(shaped.advance - 11.0) < 0.001)
    }

    /** 连字不跨 tspan 的字体 / 字号边界。 */
    @TestCase
    public func ligatureDoesNotCrossTspanBoundary(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Test\" " +
            "font-size=\"10\">f<tspan font-size=\"20\">i</tspan></text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 2)
        @Assert(abs(layout.advance - 15.0) < 0.001)
    }

    /** 非整形字体（Hershey）输出与 M4 一致。 */
    @TestCase
    public func nonShapingFontUnchanged(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Hershey\" " +
            "font-size=\"10\">fi</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 2)
        @Assert(layout.advance > 0.0)
    }
}
