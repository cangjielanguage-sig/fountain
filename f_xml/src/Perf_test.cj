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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import fountain::f_base.StringGenerator
import std.io.{InputStream, StringReader}
import std.env
import std.fs.{File, OpenMode}
import std.time.MonoTime

/**
 * 合成 XML 流：**不落地 50 MB 测试文件**，按需生成字节。
 *
 * 模板固定：`<root>` + N 条 `<item id="N" a="v">text-N</item>` + `</root>`。
 * 先按整条记录凑到不超过目标值的最大条数，再补 `</root>`，因此实际字节数与目标值
 * 之差小于单条记录长度（约 32–44 B），且截断永远不落在记录内部——文档始终良构。
 */
internal class SyntheticXmlStream <: InputStream {
    private static let headerText = "<root>"
    private static let footerText = "</root>"

    private let headerBytes: Array<Byte>
    private let footerBytes: Array<Byte>
    private let recordCount: Int64
    private let total: Int64
    private var sent: Int64 = 0
    private var headerPos: Int64 = 0
    private var footerPos: Int64 = 0
    private var index: Int64 = 0
    private var record: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var recordPos: Int64 = 0

    init(targetBytes: Int64) {
        this.headerBytes = SyntheticXmlStream.headerText.toArray()
        this.footerBytes = SyntheticXmlStream.footerText.toArray()
        let base = Int64(this.headerBytes.size + this.footerBytes.size)
        var count: Int64 = 0
        var size = base
        while (true) {
            let next = size + SyntheticXmlStream.recordLength(count)
            if (next > targetBytes) {
                break
            }
            size = next
            count++
        }
        this.recordCount = count
        this.total = size
    }

    /** 第 `n` 条记录的字节长度：`<item id="N" a="v">text-N</item>`。 */
    private static func recordLength(n: Int64): Int64 {
        30 + 2 * digitCount(n)
    }

    private static func digitCount(n: Int64): Int64 {
        var value = n
        var digits: Int64 = 1
        while (value >= 10) {
            value /= 10
            digits++
        }
        digits
    }

    private static func recordText(n: Int64): String {
        "<item id=\"${n}\" a=\"v\">text-${n}</item>"
    }

    /** 实际产出的字节数（用例用来断言与目标值的误差）。 */
    func totalBytes(): Int64 {
        this.total
    }

    /** 记录条数：事件数应为 `3 * recordCount + 4`。 */
    func records(): Int64 {
        this.recordCount
    }

    public func read(buffer: Array<Byte>): Int64 {
        var written: Int64 = 0
        while (written < buffer.size && this.sent < this.total) {
            if (this.headerPos < this.headerBytes.size) {
                buffer[written] = this.headerBytes[this.headerPos]
                this.headerPos++
                written++
                this.sent++
                continue
            }
            if (this.recordPos < this.record.size || this.index < this.recordCount) {
                if (this.recordPos >= this.record.size) {
                    this.record = SyntheticXmlStream.recordText(this.index).toArray()
                    this.recordPos = 0
                    this.index++
                }
                buffer[written] = this.record[this.recordPos]
                this.recordPos++
                written++
                this.sent++
                continue
            }
            if (this.footerPos < this.footerBytes.size) {
                buffer[written] = this.footerBytes[this.footerPos]
                this.footerPos++
                written++
                this.sent++
                continue
            }
            break
        }
        written
    }

    public func close(): Unit {}
}

/** 一次计时结果。 */
internal struct PerfSample {
    let bytes: Int64
    let events: Int64
    let runs: Array<Float64>
    let minMs: Float64
    let rssKb: Int64
    let hwmKb: Int64

    init(bytes: Int64, events: Int64, runs: Array<Float64>, minMs: Float64, rssKb: Int64, hwmKb: Int64) {
        this.bytes = bytes
        this.events = events
        this.runs = runs
        this.minMs = minMs
        this.rssKb = rssKb
        this.hwmKb = hwmKb
    }

    func summary(bufSize: Int64): String {
        "perf: bytes=${this.bytes} events=${this.events} ms=${this.runs} min=${this.minMs} rss_kb=${this.rssKb} hwm_kb=${this.hwmKb} buf=${bufSize}"
    }
}

/** `/proc/self/status` 的内存读数（kB）；文件不可用时为 `None`。 */
internal struct ProcMem {
    let rssKb: Int64
    let hwmKb: Int64

    init(rssKb: Int64, hwmKb: Int64) {
        this.rssKb = rssKb
        this.hwmKb = hwmKb
    }
}

internal func readProcMem(): ?ProcMem {
    try {
        let file = File("/proc/self/status", OpenMode.Read)
        let text = try {
            StringReader(file).readToEnd()
        } finally {
            file.close()
        }
        var rss: Int64 = -1
        var hwm: Int64 = -1
        for (line in text.split("\n")) {
            if (line.startsWith("VmRSS:")) {
                rss = firstNumber(line)
            } else if (line.startsWith("VmHWM:")) {
                hwm = firstNumber(line)
            }
        }
        if (rss < 0 || hwm < 0) {
            None
        } else {
            Some(ProcMem(rss, hwm))
        }
    } catch (_: Exception) {
        None
    }
}

/** 取一行里的第一个十进制数（`VmRSS:   12345 kB` → 12345）。 */
internal func firstNumber(line: String): Int64 {
    var value: Int64 = -1
    var started = false
    for (r in line.runes()) {
        let cp = r.position()
        if (cp >= 0x30 && cp <= 0x39) {
            if (!started) {
                value = 0
                started = true
            }
            value = value * 10 + (cp - 0x30)
        } else if (started) {
            break
        }
    }
    value
}

@Test
public class Perf_test {
    private func perfEnabled(): Bool {
        match (env.getVariable("F_XML_PERF")) {
            case Some(value) => value == "1"
            case None => false
        }
    }

    /** 解析一遍合成流，只对 `nextEvent()` 循环计时。 */
    private func runOnce(targetBytes: Int64, bufSize: Int64): (Float64, Int64) {
        let stream = SyntheticXmlStream(targetBytes)
        let parser = XmlPullParser(stream, options: XmlParserOptions(bufSize: bufSize))
        var events: Int64 = 0
        let start = MonoTime.now()
        while (parser.nextEvent().isSome()) {
            events++
        }
        let elapsed = (MonoTime.now() - start) / Duration.millisecond
        (elapsed, events)
    }

    /** 每档 3 次（每次新建流与 parser），取最小。 */
    private func measure(targetBytes: Int64, bufSize: Int64, runs!: Int64 = 3): PerfSample {
        let times = Array<Float64>(runs, repeat: 0.0)
        var minMs: Float64 = 0.0
        var events: Int64 = 0
        var index: Int64 = 0
        while (index < runs) {
            let result = this.runOnce(targetBytes, bufSize)
            times[index] = result[0]
            events = result[1]
            if (index == 0 || result[0] < minMs) {
                minMs = result[0]
            }
            index++
        }
        let mem = readProcMem()
        let rss = match (mem) {
            case Some(value) => value.rssKb
            case None => -1
        }
        let hwm = match (mem) {
            case Some(value) => value.hwmKb
            case None => -1
        }
        PerfSample(SyntheticXmlStream(targetBytes).totalBytes(), events, times, minMs, rss, hwm)
    }

    private func disabled(): Unit {
        println("perf: disabled (set F_XML_PERF=1)")
    }

    /** 合成流实际字节数与目标值之差小于单条记录，且文档可完整解析。 */
    @TestCase
    public func syntheticStreamByteCount(): Unit {
        let target: Int64 = 10 * 1024 * 1024
        let stream = SyntheticXmlStream(target)
        var counted: Int64 = 0
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let n = stream.read(buffer)
            if (n <= 0) {
                break
            }
            counted += n
        }
        assertTrue(counted == stream.totalBytes(), "读出 ${counted} 字节，声明 ${stream.totalBytes()}")
        let gap = target - counted
        assertTrue(gap >= 0 && gap <= 64, "与目标值相差 ${gap} 字节，应 ≤ 64")

        // 解析自检用 1 MB（默认用例不跑 10 MB 的完整解析，避免拖慢 cjpm test）。
        let small = SyntheticXmlStream(1024 * 1024)
        let parser = XmlPullParser(SyntheticXmlStream(1024 * 1024))
        var events: Int64 = 0
        while (parser.nextEvent().isSome()) {
            events++
        }
        assertTrue(events == 3 * small.records() + 4, "事件数应为 ${3 * small.records() + 4}，实际 ${events}")
    }

    /** 同一目标值两次生成的字节序列一致。 */
    @TestCase
    public func syntheticStreamIsRepeatable(): Unit {
        let target: Int64 = 64 * 1024
        let first = drainStream(SyntheticXmlStream(target))
        let second = drainStream(SyntheticXmlStream(target))
        assertTrue(first.size == second.size, "两次字节数不同：${first.size} vs ${second.size}")
        for (i in 0..first.size) {
            if (first[i] != second[i]) {
                assertTrue(false, "第 ${i} 字节不同")
            }
        }
    }

    /** 1 MB 冒烟：默认执行，耗时只记录（慢机器不判 fail，超过 2 s 视为异常）。 */
    @TestCase
    public func smokeOneMegabyte(): Unit {
        let sample = this.measure(1024 * 1024, 8192, runs: 1)
        println(sample.summary(8192))
        assertTrue(sample.minMs < 2000.0, "1 MB 耗时 ${sample.minMs} ms，超过 2 s")
    }

    /** Gate P：10 MB min(3) < 7200 ms + RSS 差值断言。 */
    @TestCase
    public func gateTenAndFiftyMegabytes(): Unit {
        if (!this.perfEnabled()) {
            this.disabled()
            return
        }
        // 预热：解析一次 1 MB，丢弃结果。
        let warmup = this.runOnce(1024 * 1024, 8192)
        println("perf: warmup min=${warmup[0]} events=${warmup[1]}")

        let ten = this.measure(10 * 1024 * 1024, 8192)
        println(ten.summary(8192))
        let hwm10 = ten.hwmKb

        let fifty = this.measure(50 * 1024 * 1024, 8192, runs: 1)
        println(fifty.summary(8192))
        let hwm50 = fifty.hwmKb

        assertTrue(ten.minMs < 7200.0, "Gate P 未达标：10 MB min=${ten.minMs} ms ≥ 7200 ms")
        if (hwm10 > 0 && hwm50 > 0) {
            let delta = hwm50 - hwm10
            println("perf: rss_delta_kb=${delta} hwm10_kb=${hwm10} hwm50_kb=${hwm50}")
            assertTrue(delta <= 24 * 1024, "VmHWM(50) - VmHWM(10) = ${delta} kB，超过 24 MB")
            assertTrue(hwm50 <= 256 * 1024, "VmHWM(50) = ${hwm50} kB，超过 256 MB")
        } else {
            println("perf: rss unavailable")
        }
    }

    /** R5：`bufSize` 矩阵（1 MB / 10 MB × 4096 / 8192 / 16384 / 65536）。 */
    @TestCase
    public func bufSizeMatrix(): Unit {
        if (!this.perfEnabled()) {
            this.disabled()
            return
        }
        for (bufSize in [4096, 8192, 16384, 65536]) {
            let one = this.measure(1024 * 1024, bufSize)
            println(one.summary(bufSize))
            let ten = this.measure(10 * 1024 * 1024, bufSize)
            println(ten.summary(bufSize))
        }
    }
}

/** 把流读成字节数组（用例自检用）。 */
internal func drainStream(stream: InputStream): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = stream.read(buffer)
        if (n <= 0) {
            break
        }
        for (i in 0..n) {
            out.add(buffer[i])
        }
    }
    out.toArray()
}
