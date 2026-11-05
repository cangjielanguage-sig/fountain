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
import std.fs.*
import std.time.MonoTime

private let ROUND_TRIP_FILES = [
    "basic-shapes.svg",
    "text.svg",
    "gradient.svg",
    "namespaces.svg",
    "comments.svg",
    "unsafe.svg"
]

@Test
public class SvgRoundTrip_test {
    /** 六个样本：parse → write → parse 结构等价。 */
    @TestCase
    public func sampleStructuralEquivalence(): Unit {
        for (name in ROUND_TRIP_FILES) {
            let original = SvgParser.parse(Path("testdata/" + name))
            let written = writeSvgString(original)
            let reparsed = SvgParser.parse(written)
            let before = documentSnapshot(original)
            let after = documentSnapshot(reparsed)
            if (before != after) {
                throw Exception("样本 ${name} 往返不一致\n原始=${before}\n重解析=${after}")
            }
        }
    }

    /** 六个样本：紧凑模式二次写入字节稳定。 */
    @TestCase
    public func sampleByteStability(): Unit {
        for (name in ROUND_TRIP_FILES) {
            let first = writeSvgString(SvgParser.parse(Path("testdata/" + name)))
            let second = writeSvgString(SvgParser.parse(first))
            @Assert(first == second)
        }
    }

    /**
     * 大样本冒烟：存在则往返 + 计时，不存在则跳过。
     *
     * 性能目标（仅参考、不作门禁）：解析 ≤ 25 ms、序列化 ≤ 20 ms、峰值内存 ≤ 8× 输入。
     */
    @TestCase
    public func largeSampleSmoke(): Unit {
        let path = Path("../.assets/README/module-dependencies.svg")
        if (!exists(path)) {
            println("已跳过：大样本 .assets/README/module-dependencies.svg 不存在")
            return
        }
        let parseStart = MonoTime.now()
        let document = SvgParser.parse(path)
        let parseMs = (MonoTime.now() - parseStart) / Duration.millisecond
        let writeStart = MonoTime.now()
        let written = writeSvgString(document)
        let writeMs = (MonoTime.now() - writeStart) / Duration.millisecond
        let reparsed = SvgParser.parse(written)
        @Assert(documentSnapshot(reparsed) == documentSnapshot(document))
        @Assert(writeSvgString(reparsed) == written)
        // 参考上限，避免明显退化；正式目标见 doc/README。
        @Assert(parseMs < 5_000.0)
        @Assert(writeMs < 5_000.0)
        println("大样本：解析 ${parseMs} ms，序列化 ${writeMs} ms")
    }
}
