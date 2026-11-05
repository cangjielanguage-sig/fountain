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
        File.writeTo(path, bitmap.pixels)
        @Fail("已生成缺失的场景快照 ${name}.rgba，请重新运行测试")
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
