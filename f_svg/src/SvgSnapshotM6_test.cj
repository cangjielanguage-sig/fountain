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
import std.unittest.*
import std.unittest.testmacro.*

/** M6 快照场景；`m6-animation-control` 经固定时间采样后再渲染。 */
internal func m6RenderScene(name: String): SvgBitmap {
    let document = m5LoadDocument(name)
    if (name == "m6-interaction") {
        return SvgRenderer(
            options: SvgRenderOptions(hoveredIds: ["a"], focusedIds: ["b"])
        ).render(document)
    }
    if (name == "m6-foreign-object") {
        let bitmap = SvgBitmap(2, 2)
        bitmap.fill(SvgColor(204, 51, 0))
        let renderer = M6ForeignSolidRenderer(bitmap: Some(bitmap))
        return SvgRenderer(
            options: SvgRenderOptions(foreignObjectRenderer: renderer)
        ).render(document)
    }
    if (name == "m6-initial-view") {
        return SvgRenderer(options: SvgRenderOptions(initialView: "#detail")).render(document)
    }
    if (name == "m6-animation-control") {
        return SvgRenderer().render(SvgTimeline(document).sample(2.0))
    }
    if (name == "m6-hit-queries") {
        let styles = SvgStyleResolver().compute(document.root)
        let viewport = SvgViewport(64.0, 64.0)
        let points = [SvgPoint(18.0, 18.0), SvgPoint(42.0, 18.0), SvgPoint(46.0, 44.0)]
        let ids = ArrayList<String>()
        for (point in points) {
            for (element in SvgHitTest().elementsAt(document.root, point, viewport, styles)) {
                match (element.attr("id")) {
                    case Some(id) => if (!ids.contains(id)) {
                        ids.add(id)
                    }
                    case None => ()
                }
            }
        }
        return SvgRenderer(options: SvgRenderOptions(hoveredIds: ids.toArray())).render(document)
    }
    SvgRenderer().render(document)
}

/** M6 新增的 9 个场景。 */
@Test
public class SvgSnapshotM6Scenes_test {
    private static let SCENES: Array<String> = [
        "m6-interaction", "m6-foreign-object", "m6-initial-view", "m6-rendering-hints",
        "m6-color-interpolation", "m6-font-details", "m6-animation-control",
        "m6-hit-queries", "m6-svg2"
    ]

    /** 9 张 M6 场景快照逐字节一致。 */
    @TestCase
    public func scenesExact(): Unit {
        for (name in SvgSnapshotM6Scenes_test.SCENES) {
            m5CompareExact(m6RenderScene(name), name)
        }
    }

    /** 同输入重复渲染逐字节一致。 */
    @TestCase
    public func scenesAreDeterministic(): Unit {
        for (name in SvgSnapshotM6Scenes_test.SCENES) {
            let first = m6RenderScene(name)
            let second = m6RenderScene(name)
            @Assert(first.pixels == second.pixels)
        }
    }
}

/** M6 回归：M1–M5 的 25 张快照必须逐字节不变。 */
@Test
public class SvgSnapshotM6_test {
    private static let M1_TO_M3: Array<String> = [
        "basic", "gradient", "stroke", "clip", "text", "m3-filter", "m3-pattern",
        "m3-image", "m3-textpath", "m3-marker"
    ]

    private static let M5_SCENES: Array<String> = [
        "m5-selector", "m5-media", "m5-blend", "m5-drop-shadow",
        "m5-transform-origin", "m5-shaping", "m5-bidi", "m5-element-api"
    ]

    /** M1–M3 的 10 张静态快照逐字节一致。 */
    @TestCase
    public func m1ToM3SnapshotsExact(): Unit {
        for (name in SvgSnapshotM6_test.M1_TO_M3) {
            m5RenderAndCompare(name)
        }
    }

    /** 动画的 3 张快照必须经时间线采样后比对。 */
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

    /** M5 的 8 张快照逐字节一致。 */
    @TestCase
    public func m5SnapshotsExact(): Unit {
        for (name in SvgSnapshotM6_test.M5_SCENES) {
            m5CompareExact(m5RenderScene(name), name)
        }
    }
}
