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
package fountain::fprobe.collect.proc

import std.collection.{ArrayList, HashMap, HashSet}
import std.time.DateTime
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.{ProbeAgent, ProbeErrorCode, ProbeException}
import fountain::fprobe.collect.hw.{CommandRunner, CommandResult}

/** 单个挂载点的空间与 inode 指标。 */
@DataAssist[props fields]
public class DiskMount {
    private var path: String = ""
    private var fs: String = ""
    private var totalBytes: Int64 = 0
    private var usedBytes: Int64 = 0
    private var availableBytes: Int64 = 0
    private var usedPercent: Float64 = 0.0
    private var inodesTotal: Int64 = 0
    private var inodesUsed: Int64 = 0
    private var inodesUsedPercent: Float64 = 0.0

    public init() {}

    public init(path: String, fs: String, totalBytes: Int64, usedBytes: Int64, availableBytes: Int64,
        usedPercent: Float64, inodesTotal: Int64, inodesUsed: Int64, inodesUsedPercent: Float64) {
        this.path = path
        this.fs = fs
        this.totalBytes = totalBytes
        this.usedBytes = usedBytes
        this.availableBytes = availableBytes
        this.usedPercent = usedPercent
        this.inodesTotal = inodesTotal
        this.inodesUsed = inodesUsed
        this.inodesUsedPercent = inodesUsedPercent
    }
}

/** 单个块设备的 I/O 指标；字节数为累计值，IOPS/await/util 为区间值。 */
@DataAssist[props fields]
public class DiskDevice {
    private var device: String = ""
    private var readBytes: Int64 = 0
    private var writeBytes: Int64 = 0
    private var readIops: Float64 = 0.0
    private var writeIops: Float64 = 0.0
    private var awaitMs: Float64 = 0.0
    private var utilPercent: Float64 = 0.0

    public init() {}

    public init(device: String, readBytes: Int64, writeBytes: Int64, readIops: Float64, writeIops: Float64,
        awaitMs: Float64, utilPercent: Float64) {
        this.device = device
        this.readBytes = readBytes
        this.writeBytes = writeBytes
        this.readIops = readIops
        this.writeIops = writeIops
        this.awaitMs = awaitMs
        this.utilPercent = utilPercent
    }
}

/** `disk` 监控项的数据形状。 */
@DataAssist[props fields]
public class DiskSample {
    private var mounts: Array<DiskMount> = []
    private var devices: Array<DiskDevice> = []

    public init() {}

    public init(mounts: Array<DiskMount>, devices: Array<DiskDevice>) {
        this.mounts = mounts
        this.devices = devices
    }
}

struct DfRow {
    let source: String
    let total: Int64
    let used: Int64
    let available: Int64
    let percent: Float64
    let mount: String

    init(source: String, total: Int64, used: Int64, available: Int64, percent: Float64, mount: String) {
        this.source = source
        this.total = total
        this.used = used
        this.available = available
        this.percent = percent
        this.mount = mount
    }
}

struct DfInodeRow {
    let inodes: Int64
    let used: Int64
    let free: Int64
    let percent: Float64
    let mount: String

    init(inodes: Int64, used: Int64, free: Int64, percent: Float64, mount: String) {
        this.inodes = inodes
        this.used = used
        this.free = free
        this.percent = percent
        this.mount = mount
    }
}

struct DeviceCounters {
    let name: String
    let reads: Int64
    let sectorsRead: Int64
    let msReading: Int64
    let writes: Int64
    let sectorsWritten: Int64
    let msWriting: Int64
    let ioMs: Int64

    init(name: String, reads: Int64, sectorsRead: Int64, msReading: Int64, writes: Int64, sectorsWritten: Int64,
        msWriting: Int64, ioMs: Int64) {
        this.name = name
        this.reads = reads
        this.sectorsRead = sectorsRead
        this.msReading = msReading
        this.writes = writes
        this.sectorsWritten = sectorsWritten
        this.msWriting = msWriting
        this.ioMs = ioMs
    }
}

/**
 * 磁盘空间、inode 与块设备 I/O。
 *
 * 空间/inode 来自 `df -Pk` 与 `df -Pi`，按挂载点合并；`/proc/mounts` 提供真实文件系统
 * 类型，用于 `probe_diskExcludeFs` 过滤。I/O 来自 `/proc/diskstats` 的相邻帧差分。
 */
public class DiskProbe <: ProbeAgent {
    private let reader: ProcReader
    private let runner: CommandRunner
    private let excludeFs: Array<String>
    private let nowMs: () -> Int64
    private var hasBaseline = false
    private var lastNowMs: Int64 = 0
    private let previous = HashMap<String, DeviceCounters>()

    public init(reader: ProcReader, runner: CommandRunner, excludeFs: Array<String>) {
        this(reader, runner, excludeFs, {=> systemNowMs()})
    }

    public init(reader: ProcReader, runner: CommandRunner, excludeFs: Array<String>, nowMs: () -> Int64) {
        this.reader = reader
        this.runner = runner
        this.excludeFs = excludeFs
        this.nowMs = nowMs
    }

    public prop kind: String {
        get() {
            "disk"
        }
    }

    public prop data: JsonObject {
        get() {
            let spaceText = runDf("-Pk")
            let inodeText = runDf("-Pi")
            let spaceRows = parseSpaceDf(spaceText)
            let inodeRows = parseInodeDf(inodeText)
            let fsTypes = parseMountTypes(readOptional("/proc/mounts"))
            let mounts = mergeMounts(spaceRows, inodeRows, fsTypes, excludeFs)
            let devices = collectDevices()
            let sample = DiskSample(mounts, devices)
            JsonValue.from(sample.toData()).asObject()
        }
    }

    private func readOptional(path: String): String {
        match (reader.read(path)) {
            case Some(text) => text
            case None => ""
        }
    }

    private func runDf(option: String): String {
        let result = runner.run(["df", option], timeoutMs: 3000)
        if (!result.succeeded()) {
            throw ProbeException(ProbeErrorCode.COLLECT,
                'df ${option} 执行失败: exit=${result.exitCode} timedOut=${result.timedOut} ' +
                'error=${result.error} stderr=${result.stderr.trimAscii()}')
        }
        result.stdout
    }

    private func collectDevices(): Array<DiskDevice> {
        let text = readOptional("/proc/diskstats")
        let counters = parseDiskstats(text)
        let now = nowMs()
        let elapsed = if (hasBaseline) {
            now - lastNowMs
        } else {
            0
        }
        let devices = ArrayList<DiskDevice>()
        for (current in counters) {
            var readIops = 0.0
            var writeIops = 0.0
            var awaitMs = 0.0
            var utilPercent = 0.0
            match (previous.get(current.name)) {
                case Some(last) =>
                    if (elapsed > 0) {
                        let readDelta = nonNegativeDelta(current.reads, last.reads)
                        let writeDelta = nonNegativeDelta(current.writes, last.writes)
                        let completed = readDelta + writeDelta
                        let latencyDelta = nonNegativeDelta(current.msReading, last.msReading) +
                            nonNegativeDelta(current.msWriting, last.msWriting)
                        readIops = Float64(readDelta) * 1000.0 / Float64(elapsed)
                        writeIops = Float64(writeDelta) * 1000.0 / Float64(elapsed)
                        if (completed > 0) {
                            awaitMs = Float64(latencyDelta) / Float64(completed)
                        }
                        utilPercent = clampPercent(100.0 * Float64(nonNegativeDelta(current.ioMs, last.ioMs)) /
                            Float64(elapsed))
                    }
                case None => ()
            }
            previous[current.name] = current
            devices.add(DiskDevice(current.name, current.sectorsRead * 512, current.sectorsWritten * 512, readIops,
                writeIops, awaitMs, utilPercent))
        }
        lastNowMs = now
        hasBaseline = true
        devices.toArray()
    }
}

private func systemNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func parseSpaceDf(text: String): Array<DfRow> {
    let rows = ArrayList<DfRow>()
    var first = true
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        if (first) {
            first = false
            if (line.startsWith("Filesystem")) {
                continue
            }
        }
        let tokens = splitWhitespace(line)
        if (tokens.size < 6) {
            throw ProbeException(ProbeErrorCode.COLLECT, 'df -Pk 输出缺少列: "${line}"')
        }
        rows.add(DfRow(tokens[0], requireInt(tokens[1], "df -Pk"), requireInt(tokens[2], "df -Pk"),
            requireInt(tokens[3], "df -Pk"), requirePercent(tokens[4], "df -Pk"), joinFrom(tokens, 5)))
    }
    rows.toArray()
}

private func parseInodeDf(text: String): Array<DfInodeRow> {
    let rows = ArrayList<DfInodeRow>()
    var first = true
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        if (first) {
            first = false
            if (line.startsWith("Filesystem")) {
                continue
            }
        }
        let tokens = splitWhitespace(line)
        if (tokens.size < 6) {
            throw ProbeException(ProbeErrorCode.COLLECT, 'df -Pi 输出缺少列: "${line}"')
        }
        rows.add(DfInodeRow(requireInt(tokens[1], "df -Pi"), requireInt(tokens[2], "df -Pi"),
            requireInt(tokens[3], "df -Pi"), requirePercent(tokens[4], "df -Pi"), joinFrom(tokens, 5)))
    }
    rows.toArray()
}

private func requireInt(token: String, label: String): Int64 {
    match (tryInt64(token)) {
        case Some(value) => value
        case None => throw ProbeException(ProbeErrorCode.COLLECT, '${label} 输出含有非数字字段: "${token}"')
    }
}

private func requirePercent(token: String, label: String): Float64 {
    let stripped = if (token.endsWith("%")) {
        token[0..token.size - 1]
    } else {
        token
    }
    match (tryFloat64(stripped)) {
        case Some(value) => value
        case None => throw ProbeException(ProbeErrorCode.COLLECT, '${label} 输出含有非法百分比: "${token}"')
    }
}

/** `/proc/mounts`：device mountpoint fstype options dump pass。 */
private func parseMountTypes(text: String): HashMap<String, String> {
    let types = HashMap<String, String>()
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let tokens = splitWhitespace(line)
        if (tokens.size < 3) {
            continue
        }
        types[decodeMountPath(tokens[1])] = tokens[2]
    }
    types
}

private func decodeMountPath(raw: String): String {
    raw.replace('\\040', ' ').replace('\\011', '\t').replace('\\012', '\n').replace('\\134', '\\')
}

private func mergeMounts(spaceRows: Array<DfRow>, inodeRows: Array<DfInodeRow>, fsTypes: HashMap<String, String>,
    excludeFs: Array<String>): Array<DiskMount> {
    let exclude = HashSet<String>()
    for (name in excludeFs) {
        let normalized = name.trimAscii().toAsciiLower()
        if (!normalized.isEmpty()) {
            exclude.add(normalized)
        }
    }

    let inodeByMount = HashMap<String, DfInodeRow>()
    for (row in inodeRows) {
        inodeByMount[row.mount] = row
    }

    let mounts = ArrayList<DiskMount>()
    for (row in spaceRows) {
        let fsType = match (fsTypes.get(row.mount)) {
            case Some(value) => value
            case None => row.source
        }
        if (exclude.contains(fsType.trimAscii().toAsciiLower())) {
            continue
        }
        match (inodeByMount.get(row.mount)) {
            case Some(inode) =>
                mounts.add(DiskMount(row.mount, fsType, row.total * 1024, row.used * 1024, row.available * 1024,
                    row.percent, inode.inodes, inode.used, inode.percent))
            case None =>
                mounts.add(DiskMount(row.mount, fsType, row.total * 1024, row.used * 1024, row.available * 1024,
                    row.percent, 0, 0, 0.0))
        }
    }
    mounts.toArray()
}

private func parseDiskstats(text: String): Array<DeviceCounters> {
    let counters = ArrayList<DeviceCounters>()
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let tokens = splitWhitespace(line)
        if (tokens.size < 14) {
            throw ProbeException(ProbeErrorCode.COLLECT, '/proc/diskstats 行字段不足: "${line}"')
        }
        counters.add(DeviceCounters(tokens[2], requireStat(tokens[3], "reads completed"),
            requireStat(tokens[5], "sectors read"), requireStat(tokens[6], "ms reading"),
            requireStat(tokens[7], "writes completed"), requireStat(tokens[9], "sectors written"),
            requireStat(tokens[10], "ms writing"), requireStat(tokens[12], "ms doing IO")))
    }
    counters.toArray()
}

private func requireStat(token: String, field: String): Int64 {
    match (tryInt64(token)) {
        case Some(value) => value
        case None => throw ProbeException(ProbeErrorCode.COLLECT,
                '/proc/diskstats 的 ${field} 不是数字: "${token}"')
    }
}
