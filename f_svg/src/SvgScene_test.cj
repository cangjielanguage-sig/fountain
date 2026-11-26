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

import std.fs.{File, Path, exists}
import std.unittest.*
import std.unittest.testmacro.*

internal let SCENE_DIR = "testdata/render"

internal func loadScene(name: String): SvgDocument {
    SvgParser.parse(Path("${SCENE_DIR}/${name}.svg"))
}

internal func compareScene(bitmap: SvgBitmap, name: String): Unit {
    let path = Path("${SCENE_DIR}/${name}.rgba")
    if (!exists(path)) {
        @Fail("场景快照 ${name}.rgba 缺失，请从版本库恢复，测试不会自动生成期望值")
    }
    let expected = File.readFrom(path)
    if (expected.size != bitmap.pixels.size) {
        @Fail("场景快照 ${name}.rgba 尺寸不匹配：期望 ${expected.size} 字节，实际 ${bitmap.pixels.size} 字节")
    }
    for (y in 0..bitmap.height) {
        for (x in 0..bitmap.width) {
            for (channel in 0..4) {
                let index = (y * bitmap.width + x) * 4 + channel
                let actual = Int64(bitmap.pixels[index])
                let wanted = Int64(expected[index])
                let difference = if (actual > wanted) { actual - wanted } else { wanted - actual }
                if (difference > 1) {
                    let pixel = bitmap.pixel(x, y)
                    @Fail(
                        "场景 ${name} 首个差异 (${x},${y}) 通道 ${channel}：" +
                        "实际 ${actual}，期望 ${wanted}；像素 ${pixel.toString()}"
                    )
                }
            }
        }
    }
}

@Test
public class SvgScene_test {
    @TestCase
    public func basic(): Unit {
        compareScene(SvgRenderer().render(loadScene("basic")), "basic")
    }

    @TestCase
    public func gradient(): Unit {
        compareScene(SvgRenderer().render(loadScene("gradient")), "gradient")
    }

    @TestCase
    public func stroke(): Unit {
        compareScene(SvgRenderer().render(loadScene("stroke")), "stroke")
    }

    @TestCase
    public func clip(): Unit {
        compareScene(SvgRenderer().render(loadScene("clip")), "clip")
    }

    @TestCase
    public func text(): Unit {
        compareScene(SvgRenderer().render(loadScene("text")), "text")
    }

    @TestCase
    public func animation(): Unit {
        let document = loadScene("animation")
        let timeline = SvgTimeline(document)
        let renderer = SvgRenderer()
        compareScene(renderer.render(timeline.sample(0.0)), "animation-0")
        compareScene(renderer.render(timeline.sample(0.5)), "animation-05")
        compareScene(renderer.render(timeline.sample(1.0)), "animation-1")
    }
}

@Test
public class SvgSceneM3_test {
    @TestCase
    public func m3Filter(): Unit {
        compareScene(SvgRenderer().render(loadScene("m3-filter")), "m3-filter")
    }

    @TestCase
    public func m3Pattern(): Unit {
        compareScene(SvgRenderer().render(loadScene("m3-pattern")), "m3-pattern")
    }

    @TestCase
    public func m3Image(): Unit {
        compareScene(SvgRenderer().render(loadScene("m3-image")), "m3-image")
    }

    @TestCase
    public func m3TextPath(): Unit {
        compareScene(SvgRenderer().render(loadScene("m3-textpath")), "m3-textpath")
    }

    @TestCase
    public func m3Marker(): Unit {
        compareScene(SvgRenderer().render(loadScene("m3-marker")), "m3-marker")
    }
}


/** 返回逐字节差异说明；完全一致返回 `None`。 */
internal func sceneExactMismatch(bitmap: SvgBitmap, name: String): ?String {
    let path = Path("${SCENE_DIR}/${name}.rgba")
    if (!exists(path)) {
        return Some("场景快照 ${name}.rgba 缺失，请从版本库恢复，测试不会自动生成期望值")
    }
    let expected = File.readFrom(path)
    if (expected.size != bitmap.pixels.size) {
        return Some("场景快照 ${name}.rgba 尺寸不匹配：期望 ${expected.size} 字节，实际 ${bitmap.pixels.size} 字节")
    }
    for (index in 0..expected.size) {
        if (expected[index] != bitmap.pixels[index]) {
            let pixelIndex = index / 4
            let x = pixelIndex % bitmap.width
            let y = pixelIndex / bitmap.width
            return Some(
                "场景 ${name} 字节漂移在 (${x},${y}) 偏移 ${index}：" +
                "实际 ${bitmap.pixels[index]}，期望 ${expected[index]}"
            )
        }
    }
    None
}

internal func compareSceneExact(bitmap: SvgBitmap, name: String): Unit {
    match (sceneExactMismatch(bitmap, name)) {
        case Some(message) => @Fail(message)
        case None => ()
    }
}

/** M1–M3 默认渲染的逐字节基线：容差 0。 */
@Test
public class SvgSceneByteBaseline_test {

    @TestCase
    public func basicExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("basic")), "basic")
    }

    @TestCase
    public func gradientExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("gradient")), "gradient")
    }

    @TestCase
    public func strokeExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("stroke")), "stroke")
    }

    @TestCase
    public func clipExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("clip")), "clip")
    }

    @TestCase
    public func textExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("text")), "text")
    }

    @TestCase
    public func animationExact(): Unit {
        let document = loadScene("animation")
        let timeline = SvgTimeline(document)
        let renderer = SvgRenderer()
        compareSceneExact(renderer.render(timeline.sample(0.0)), "animation-0")
        compareSceneExact(renderer.render(timeline.sample(0.5)), "animation-05")
        compareSceneExact(renderer.render(timeline.sample(1.0)), "animation-1")
    }

    @TestCase
    public func m3FilterExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("m3-filter")), "m3-filter")
    }

    @TestCase
    public func m3PatternExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("m3-pattern")), "m3-pattern")
    }

    @TestCase
    public func m3ImageExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("m3-image")), "m3-image")
    }

    @TestCase
    public func m3TextPathExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("m3-textpath")), "m3-textpath")
    }

    @TestCase
    public func m3MarkerExact(): Unit {
        compareSceneExact(SvgRenderer().render(loadScene("m3-marker")), "m3-marker")
    }

    /** 人为改动一个字节时，逐字节比较必须报告差异。 */
    @TestCase
    public func exactMismatchDetected(): Unit {
        let rendered = SvgRenderer().render(loadScene("m3-filter"))
        let mutated = SvgBitmap(rendered.width, rendered.height)
        for (index in 0..rendered.pixels.size) {
            mutated.pixels[index] = rendered.pixels[index]
        }
        let target = mutated.pixels.size / 2
        mutated.pixels[target] = UInt8((Int64(mutated.pixels[target]) + 1) % 256)
        @Assert(sceneExactMismatch(mutated, "m3-filter").isSome())
    }
}
