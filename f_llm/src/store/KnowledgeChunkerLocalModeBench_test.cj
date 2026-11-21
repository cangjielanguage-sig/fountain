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
package fountain::f_llm.store

import std.collection.*
import std.convert.*
import std.fs.*
import std.runtime.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * local / 堆两档的参考基准（参考值，非 CI 门禁）。
 *
 * 只为 `f_llm/doc/perf-baseline.md` 生成同一进程内的堆增量与耗时；
 * local 峰值由门限推导并用探针校准，见该文档。断言只保留「能切出块」，
 * 不把耗时或内存写成硬门禁。
 */
@Test
public class KnowledgeChunkerLocalModeBenchTest {

    @TestCase
    public func tierBenchmarks(): Unit {
        println('process baseline VmHWM=${peakRssKb()} kB')
        let asciiAtLimit = asciiOf(2 * 1024 * 1024)
        let asciiOverLimit = asciiOf(2 * 1024 * 1024 + 1)
        let asciiLarge = asciiOf(8 * 1024 * 1024)
        let chineseAtLimit = chineseOf(699_050)
        let chineseOverLimit = chineseOf(699_051)

        benchmark('ascii 2 MiB -> local', asciiAtLimit, true)
        benchmark('ascii 2 MiB -> heap (forced)', asciiAtLimit, false)
        benchmark('ascii 2 MiB+1 -> heap', asciiOverLimit, false)
        benchmark('chinese 699,050 -> local', chineseAtLimit, true)
        benchmark('chinese 699,051 -> heap', chineseOverLimit, false)
        benchmark('ascii 8 MiB -> heap', asciiLarge, false)
    }

    private func benchmark(label: String, content: String, useLocal: Bool): Unit {
        let heapBefore = getAllocatedHeapSize()
        let started = MonoTime.now()
        let chunks = KnowledgeChunker.splitImpl(content, KnowledgeChunker.DEFAULT_MAX_CHARS,
            KnowledgeChunker.DEFAULT_OVERLAP, useLocal)
        let elapsed = MonoTime.now() - started
        let heapAfter = getAllocatedHeapSize()
        println('${label}: bytes=${content.size} chunks=${chunks.size} ' +
            'heapDelta=${heapAfter - heapBefore} elapsed=${elapsed.toNanoseconds() / 1_000_000}ms ' +
            'tier=${if (useLocal) { 'local' } else { 'heap' }} vmhwm=${peakRssKb()}kB')
        @Expect(chunks.size > 0, true)
    }

    /** 读取进程 VmHWM（峰值 RSS，含测试框架基线）；非 Linux 返回 -1。 */
    private func peakRssKb(): Int64 {
        try {
            let text = String.fromUtf8(File.readFrom('/proc/self/status'))
            for (line in text.split('\n')) {
                if (line.startsWith('VmHWM:')) {
                    let value = line.split(':')[1].trimAscii().replace('kB', '').trimAscii()
                    return Int64.parse(value)
                }
            }
        } catch (_: Exception) {
            return -1
        }
        -1
    }

    private func asciiOf(bytes: Int64): String {
        let builder = StringBuilder()
        var index: Int64 = 0
        while (index < bytes) {
            builder.append('a')
            index++
        }
        builder.toString()
    }

    private func chineseOf(chars: Int64): String {
        let builder = StringBuilder()
        var index: Int64 = 0
        while (index < chars) {
            builder.append('汉')
            index++
        }
        builder.toString()
    }
}
