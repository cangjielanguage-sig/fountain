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
import std.fs.{File, Path, exists}
import std.unittest.*
import std.unittest.testmacro.*

internal let M5_SNAPSHOT_DIR = "testdata/render"

/** M5 快照路径：`<name>.svg` / `<name>.rgba`。 */
internal func m5SnapshotPath(name: String, extension: String): String {
    "${M5_SNAPSHOT_DIR}/${name}.${extension}"
}

internal func m5LoadDocument(name: String): SvgDocument {
    let path = Path(m5SnapshotPath(name, "svg"))
    if (!exists(path)) {
        @Fail("M5 场景 ${name}.svg 缺失")
    }
    SvgParser.parse(path)
}

/** 读取期望 `.rgba`；缺失时直接失败，绝不自动生成。 */
internal func m5ReadExpected(name: String): Array<Byte> {
    let path = Path(m5SnapshotPath(name, "rgba"))
    if (!exists(path)) {
        @Fail("M5 场景快照 ${name}.rgba 缺失，请从版本库恢复")
    }
    File.readFrom(path)
}

/** 逐字节比较；容差 0。返回首个差异说明，完全一致返回 `None`。 */
internal func m5ExactMismatch(bitmap: SvgBitmap, name: String): ?String {
    let expected = m5ReadExpected(name)
    if (expected.size != bitmap.pixels.size) {
        return Some("M5 快照 ${name} 尺寸不匹配：期望 ${expected.size} 字节，实际 ${bitmap.pixels.size} 字节")
    }
    for (index in 0..expected.size) {
        if (expected[index] != bitmap.pixels[index]) {
            let pixelIndex = index / 4
            let x = pixelIndex % bitmap.width
            let y = pixelIndex / bitmap.width
            return Some(
                "M5 快照 ${name} 字节漂移 (${x},${y}) 偏移 ${index}：实际 ${bitmap.pixels[index]}，期望 ${expected[index]}"
            )
        }
    }
    None
}

internal func m5CompareExact(bitmap: SvgBitmap, name: String): Unit {
    match (m5ExactMismatch(bitmap, name)) {
        case Some(message) => @Fail(message)
        case None => ()
    }
}

/** 渲染并逐字节比对；场景文件缺失或存在漂移都失败。 */
internal func m5RenderAndCompare(name: String): Unit {
    m5CompareExact(SvgRenderer().render(m5LoadDocument(name)), name)
}

/** M5 基线：17 张既有快照必须逐字节不变。 */
@Test
public class SvgSnapshotM5_test {
    private static let M1_TO_M3: Array<String> = [
        "basic", "gradient", "stroke", "clip", "text", "m3-filter", "m3-pattern",
        "m3-image", "m3-textpath", "m3-marker"
    ]

    /** M1–M3 的 10 张静态快照逐字节一致。 */
    @TestCase
    public func m1ToM3SnapshotsExact(): Unit {
        for (name in SvgSnapshotM5_test.M1_TO_M3) {
            m5RenderAndCompare(name)
        }
    }

    /** 动画的 3 张快照必须经时间线采样后比对，不能直接渲染源文档。 */
    @TestCase
    public func animationSnapshotsExact(): Unit {
        let timeline = SvgTimeline(m5LoadDocument("animation"))
        let renderer = SvgRenderer()
        m5CompareExact(renderer.render(timeline.sample(0.0)), "animation-0")
        m5CompareExact(renderer.render(timeline.sample(0.5)), "animation-05")
        m5CompareExact(renderer.render(timeline.sample(1.0)), "animation-1")
    }

    /** M4 的 4 张快照逐字节一致。 */
    @TestCase
    public func m4SnapshotsExact(): Unit {
        for (name in ["m4-clip", "m4-filter", "m4-text", "m4-view"]) {
            m5RenderAndCompare(name)
        }
    }

    /** 人为改动一个字节时辅助函数必须报告差异，避免出现「永远通过」的假绿。 */
    @TestCase
    public func mismatchIsDetected(): Unit {
        let rendered = SvgRenderer().render(m5LoadDocument("basic"))
        let mutated = SvgBitmap(rendered.width, rendered.height)
        for (index in 0..rendered.pixels.size) {
            mutated.pixels[index] = rendered.pixels[index]
        }
        let target = mutated.pixels.size / 2
        mutated.pixels[target] = UInt8((Int64(mutated.pixels[target]) + 1) % 256)
        @Assert(m5ExactMismatch(mutated, "basic").isSome())
    }
}

/** M5 新增特性场景：同输入重复渲染逐字节一致。 */
@Test
public class SvgSnapshotM5Scenes_test {
    private static let SCENES: Array<String> = [
        "m5-selector", "m5-media", "m5-blend", "m5-drop-shadow",
        "m5-transform-origin", "m5-shaping", "m5-bidi", "m5-element-api"
    ]

    @TestCase
    public func scenesExact(): Unit {
        for (name in SvgSnapshotM5Scenes_test.SCENES) {
            m5RenderAndCompare(name)
        }
    }

    @TestCase
    public func scenesAreDeterministic(): Unit {
        for (name in SvgSnapshotM5Scenes_test.SCENES) {
            let first = SvgRenderer().render(m5LoadDocument(name))
            let second = SvgRenderer().render(m5LoadDocument(name))
            @Assert(first.pixels == second.pixels)
        }
    }
}
