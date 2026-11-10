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
import std.io.{InputStream, StringReader}
import std.env
import std.fs.{File, OpenMode}
import std.time.MonoTime

/**
 * 合成 XML 流：**不落地 50 MB 测试文件**，按需生成字节。
 *
 * 模板固定：`<root>` + N 条 `<item id="N" a="v">text-N</item>` + `</root>`。
 * 先按整条记录凑到不超过目标值的最大条数，再补 `</root>`，因此实际字节数与目标值
 * 之差小于单条记录长度（约 30–44 B），且截断永远不落在记录内部——文档始终良构。
 *
 * **零分配**（`tasks.md` 1.2）：记录按「常量段 + 十进制数字」逐段写进调用方的 `buffer`，
 * 全程不建 `String`、不建临时 `Array<Byte>`。数字写进复用字段 `digits`。
 * 旧实现每记录 `"…".toArray()` 一次（50 MB 上 125 万次），会把基准自身的分配
 * 记成解析器成本（`design.md` §3.1）。
 */
internal class SyntheticXmlStream <: InputStream {
    private static let headerText = "<root>"
    private static let footerText = "</root>"
    private static let itemOpenText = "<item id=\""
    private static let itemMidText = "\" a=\"v\">text-"
    private static let itemCloseText = "</item>"
    /** 一条记录的段数（开标签 / 数字 / 中段 / 数字 / 闭标签）。 */
    private static let segments = 5
    /** `Int64` 的十进制位数上限。 */
    private static let maxDigits = 20

    private let headerBytes: Array<Byte>
    private let footerBytes: Array<Byte>
    private let itemOpenBytes: Array<Byte>
    private let itemMidBytes: Array<Byte>
    private let itemCloseBytes: Array<Byte>
    private let recordCount: Int64
    private let total: Int64
    private let digits = Array<Byte>(SyntheticXmlStream.maxDigits, repeat: 0)
    private var sent: Int64 = 0
    private var headerPos: Int64 = 0
    private var footerPos: Int64 = 0
    private var index: Int64 = 0
    /** 当前记录内的段号（0..4）与段内偏移。 */
    private var seg: Int64 = 0
    private var segPos: Int64 = 0
    /** 当前记录的数字位数（两段数字共用，因为同一条记录的两个 `n` 相同）。 */
    private var digitLen: Int64 = 0
    private var inRecord = false

    init(targetBytes: Int64) {
        this.headerBytes = SyntheticXmlStream.headerText.toArray()
        this.footerBytes = SyntheticXmlStream.footerText.toArray()
        this.itemOpenBytes = SyntheticXmlStream.itemOpenText.toArray()
        this.itemMidBytes = SyntheticXmlStream.itemMidText.toArray()
        this.itemCloseBytes = SyntheticXmlStream.itemCloseText.toArray()
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

    /** 把 `n` 的十进制数字写进 `out[0..len)`（高位在前），返回位数。 */
    private static func writeDigits(n: Int64, out: Array<Byte>): Int64 {
        let len = SyntheticXmlStream.digitCount(n)
        var value = n
        var i = len - 1
        while (i >= 0) {
            out[i] = UInt8(0x30 + value % 10)
            value /= 10
            i--
        }
        len
    }

    private func beginRecord(n: Int64): Unit {
        this.digitLen = SyntheticXmlStream.writeDigits(n, this.digits)
        this.seg = 0
        this.segPos = 0
    }

    private func segmentLength(): Int64 {
        match (this.seg) {
            case 0 => Int64(this.itemOpenBytes.size)
            case 1 => this.digitLen
            case 2 => Int64(this.itemMidBytes.size)
            case 3 => this.digitLen
            case _ => Int64(this.itemCloseBytes.size)
        }
    }

    private func segmentBytes(): Array<Byte> {
        match (this.seg) {
            case 0 => this.itemOpenBytes
            case 1 => this.digits
            case 2 => this.itemMidBytes
            case 3 => this.digits
            case _ => this.itemCloseBytes
        }
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
            if (this.inRecord || this.index < this.recordCount) {
                if (!this.inRecord) {
                    this.beginRecord(this.index)
                    this.inRecord = true
                }
                let segLen = this.segmentLength()
                let source = this.segmentBytes()
                var take = segLen - this.segPos
                let room = buffer.size - written
                if (take > room) {
                    take = room
                }
                let at = this.segPos
                for (i in 0..take) {
                    buffer[written + i] = source[at + i]
                }
                written += take
                this.sent += take
                this.segPos += take
                if (this.segPos >= segLen) {
                    this.seg++
                    this.segPos = 0
                    if (this.seg >= SyntheticXmlStream.segments) {
                        this.inRecord = false
                        this.index++
                    }
                }
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

/** 读一个 `/proc` 文本文件；不可用时 `None`。 */
internal func readProcText(path: String): ?String {
    try {
        let file = File(path, OpenMode.Read)
        let text = try {
            StringReader(file).readToEnd()
        } finally {
            file.close()
        }
        Some(text)
    } catch (_: Exception) {
        None
    }
}

/** `nproc`：`/proc/cpuinfo` 里 `processor` 行的条数；读不到时返回 1。 */
internal func cpuCount(): Int64 {
    let text = match (readProcText("/proc/cpuinfo")) {
        case Some(v) => v
        case None => return 1
    }
    var count: Int64 = 0
    for (line in text.split("\n")) {
        if (line.startsWith("processor")) {
            count++
        }
    }
    if (count <= 0) {
        1
    } else {
        count
    }
}

/** `/proc/loadavg` 的 1 分钟负载；读不到时返回 0。 */
internal func loadAverage1(): Float64 {
    let text = match (readProcText("/proc/loadavg")) {
        case Some(v) => v
        case None => return 0.0
    }
    parseLeadingFloat(text)
}

/** 解析串首的十进制小数（`/proc/loadavg` 的 `0.27`）。 */
internal func parseLeadingFloat(text: String): Float64 {
    var intPart: Int64 = 0
    var frac: Float64 = 0.0
    var scale: Float64 = 0.1
    var inFrac = false
    var seen = false
    for (r in text.runes()) {
        let cp = r.position()
        if (cp >= 0x30 && cp <= 0x39) {
            if (inFrac) {
                frac += scale * Float64(cp - 0x30)
                scale = scale / 10.0
            } else {
                intPart = intPart * 10 + (cp - 0x30)
            }
            seen = true
        } else if (cp == 0x2E && !inFrac && seen) {
            inFrac = true
        } else if (cp == 0x20 && !seen) {
            continue
        } else {
            break
        }
    }
    Float64(intPart) + frac
}

/** 门禁禁止出现（也不该被设置）的 GC / 运行时环境变量。 */
internal let kGcEnvNames = [
    "cjHeapSize", "cjGCInterval", "cjRegionSize", "cjLargeObjectThreshold",
    "cjExemptionThreshold", "cjAllocationProfiling", "cjAllocationSampleRate",
    "cjGarbageCollection", "cjBackupHeapSize", "cjProcessorCount", "cjStackSize"
]

/** 已设置的 GC 环境变量（`NAME=value`）；空数组表示默认运行时。 */
internal func detectedGcEnv(): Array<String> {
    let out = ArrayList<String>()
    for (name in kGcEnvNames) {
        match (env.getVariable(name)) {
            case Some(value) => out.add("${name}=${value}")
            case None => ()
        }
    }
    out.toArray()
}

/** `F_XML_PERF=1` 时才跑门禁用例。 */
internal func perfGateEnabled(): Bool {
    match (env.getVariable("F_XML_PERF")) {
        case Some(value) => value == "1"
        case None => false
    }
}

/** 环境三件套：`nproc` / 1 分钟负载 / GC 环境变量（门禁证据，必须打印）。 */
internal func environmentLine(): String {
    let nproc = cpuCount()
    let load = loadAverage1()
    let gc = detectedGcEnv()
    let gcText = if (gc.size == 0) {
        "[]"
    } else {
        "[${gc}]"
    }
    "gate: env nproc=${nproc} loadavg1=${load} load_bound=${0.5 * Float64(nproc)} gc_env=${gcText}"
}

/** 空载 + 默认运行时；不满足时门禁只打印 `invalid`，不产出假结论。 */
internal func gateEnvironmentOk(): Bool {
    detectedGcEnv().size == 0 && loadAverage1() <= 0.5 * Float64(cpuCount())
}

/** 解析一遍合成流，只对 `nextEvent()` 循环计时（10 MB / 50 MB 门禁共用）。 */
internal func runSyntheticPass(targetBytes: Int64, bufSize: Int64): (Float64, Int64) {
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

    /**
     * 零分配基准与**旧实现**（每记录 `String` + `toArray`）逐字节一致（`tasks.md` 1.1）。
     *
     * 这是「新旧代码共用同一份输入」的唯一证据：若字节流变了，`baseline.md` §3 的
     * 同轮对照就不成立。
     */
    @TestCase
    public func syntheticStreamGolden(): Unit {
        for (target in [Int64(1024), Int64(64 * 1024)]) {
            let count = referenceRecordCount(target)
            let stream = SyntheticXmlStream(target)
            assertTrue(stream.records() == count, "目标 ${target}：记录数应为 ${count}，实际 ${stream.records()}")
            this.assertSameBytes(stream, referenceSyntheticBytes(count), "target=${target}")
        }
        // 位数进位点：9→10、99→100 会让最后一条记录的两个数字各宽一位。
        for (count in [Int64(9), Int64(10), Int64(99), Int64(100)]) {
            let expected = referenceSyntheticBytes(count)
            let stream = SyntheticXmlStream(Int64(expected.size))
            assertTrue(stream.records() == count, "记录数应为 ${count}，实际 ${stream.records()}")
            assertTrue(stream.totalBytes() == Int64(expected.size), "字节数应为 ${expected.size}，实际 ${stream.totalBytes()}")
            this.assertSameBytes(stream, expected, "count=${count}")
        }
    }

    private func assertSameBytes(stream: SyntheticXmlStream, expected: Array<Byte>, label: String): Unit {
        let actual = drainStream(stream)
        assertTrue(actual.size == expected.size, "${label}：字节数 ${actual.size} ≠ ${expected.size}")
        for (i in 0..expected.size) {
            if (actual[i] != expected[i]) {
                assertTrue(false, "${label}：第 ${i} 字节 ${actual[i]} ≠ ${expected[i]}")
            }
        }
    }

    /** 1 MB 冒烟：默认执行，耗时只记录，不设上限（与 spec 一致）。 */
    @TestCase
    public func smokeOneMegabyte(): Unit {
        let sample = this.measure(1024 * 1024, 8192, runs: 1)
        println(sample.summary(8192))
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
            assertTrue(hwm50 <= 320 * 1024, "VmHWM(50) = ${hwm50} kB，超过 320 MB（-O2 档位）")
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

/** 旧基准的单条记录（golden 参照实现，与被测实现无关地由字符串模板拼出）。 */
internal func referenceRecord(n: Int64): String {
    "<item id=\"${n}\" a=\"v\">text-${n}</item>"
}

/** 旧基准产出的完整字节流：`<root>` + N 条记录 + `</root>`。 */
internal func referenceSyntheticBytes(count: Int64): Array<Byte> {
    let out = ArrayList<Byte>()
    out.add(all: "<root>".toArray())
    for (i in 0..count) {
        out.add(all: referenceRecord(i).toArray())
    }
    out.add(all: "</root>".toArray())
    out.toArray()
}

/** 旧基准的贪心条数：取「整条记录之和不超过目标值」的最大值。 */
internal func referenceRecordCount(target: Int64): Int64 {
    var size: Int64 = 13
    var count: Int64 = 0
    while (true) {
        let next = size + Int64(referenceRecord(count).size)
        if (next > target) {
            break
        }
        size = next
        count++
    }
    count
}
