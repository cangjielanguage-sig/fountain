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

import std.collection.ArrayList
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.{ProbeAgent, ProbeErrorCode, ProbeException}

/** `cpu` 监控项的数据形状。 */
@DataAssist[props fields]
public class CpuSample {
    private var usagePercent: Float64 = 0.0
    private var iowaitPercent: Float64 = 0.0
    private var load1: Float64 = 0.0
    private var load5: Float64 = 0.0
    private var load15: Float64 = 0.0
    private var cores: Int64 = 0

    public init() {}

    public init(usagePercent: Float64, iowaitPercent: Float64, load1: Float64, load5: Float64, load15: Float64,
        cores: Int64) {
        this.usagePercent = usagePercent
        this.iowaitPercent = iowaitPercent
        this.load1 = load1
        this.load5 = load5
        this.load15 = load15
        this.cores = cores
    }
}

/**
 * CPU 使用率与负载。
 *
 * `/proc/stat` 是累计时间片，第一次采样只建立基线；之后按总时间片增量计算
 * 使用率，按 iowait 增量计算 iowait 占比。逻辑核数从每核 `cpuN` 行统计。
 */
public class CpuProbe <: ProbeAgent {
    private let reader: ProcReader
    private var hasBaseline = false
    private var lastTotal: Int64 = 0
    private var lastIdle: Int64 = 0
    private var lastIowait: Int64 = 0

    public init(reader: ProcReader) {
        this.reader = reader
    }

    public prop kind: String {
        get() {
            "cpu"
        }
    }

    public prop data: JsonObject {
        get() {
            let stat = requireFile(reader, "/proc/stat")
            let loadavg = requireFile(reader, "/proc/loadavg")
            let (total, idle, iowait) = parseAggregate(stat)
            let (load1, load5, load15) = parseLoad(loadavg)
            let cores = countCores(stat)

            var usage = 0.0
            var iowaitPercent = 0.0
            if (hasBaseline) {
                let totalDelta = total - lastTotal
                if (totalDelta > 0) {
                    let idleDelta = nonNegativeDelta(idle, lastIdle)
                    let iowaitDelta = nonNegativeDelta(iowait, lastIowait)
                    usage = clampPercent(100.0 * Float64(totalDelta - idleDelta - iowaitDelta) /
                        Float64(totalDelta))
                    iowaitPercent = clampPercent(100.0 * Float64(iowaitDelta) / Float64(totalDelta))
                }
            }

            hasBaseline = true
            lastTotal = total
            lastIdle = idle
            lastIowait = iowait

            let sample = CpuSample(usage, iowaitPercent, load1, load5, load15, cores)
            JsonValue.from(sample.toData()).asObject()
        }
    }
}

func requireFile(reader: ProcReader, path: String): String {
    match (reader.read(path)) {
        case Some(text) => text
        case None => throw ProbeException(ProbeErrorCode.COLLECT, '读取 ${path} 失败')
    }
}

/** 返回 (总时间片, idle, iowait)。 */
private func parseAggregate(text: String): (Int64, Int64, Int64) {
    for (line in text.split("\n")) {
        let tokens = splitWhitespace(line)
        if (tokens.size == 0 || tokens[0] != "cpu") {
            continue
        }
        if (tokens.size < 6) {
            throw ProbeException(ProbeErrorCode.COLLECT, '/proc/stat 的 cpu 行字段不足: "${line.trimAscii()}"')
        }
        let values = ArrayList<Int64>()
        let limit = if (tokens.size > 9) {
            9
        } else {
            tokens.size
        }
        var index = 1
        while (index < limit) {
            match (tryInt64(tokens[index])) {
                case Some(value) => values.add(value)
                case None => throw ProbeException(ProbeErrorCode.COLLECT,
                        '/proc/stat 的 cpu 行含有非数字字段: "${tokens[index]}"')
            }
            index += 1
        }
        if (values.size < 5) {
            throw ProbeException(ProbeErrorCode.COLLECT, "/proc/stat 的 cpu 行字段不足")
        }
        var total = 0
        for (value in values) {
            total += value
        }
        return (total, values[3], values[4])
    }
    throw ProbeException(ProbeErrorCode.COLLECT, "/proc/stat 中未找到 cpu 汇总行")
}

private func parseLoad(text: String): (Float64, Float64, Float64) {
    let tokens = splitWhitespace(text)
    if (tokens.size < 3) {
        throw ProbeException(ProbeErrorCode.COLLECT, '/proc/loadavg 字段不足: "${text.trimAscii()}"')
    }
    let one = tryFloat64(tokens[0])
    let five = tryFloat64(tokens[1])
    let fifteen = tryFloat64(tokens[2])
    match ((one, five, fifteen)) {
        case (Some(a), Some(b), Some(c)) => (a, b, c)
        case _ => throw ProbeException(ProbeErrorCode.COLLECT, '/proc/loadavg 含有非数字字段: "${text.trimAscii()}"')
    }
}

private func countCores(text: String): Int64 {
    var count = 0
    for (line in text.split("\n")) {
        let tokens = splitWhitespace(line)
        if (tokens.isEmpty()) {
            continue
        }
        let name = tokens[0]
        if (name.size > 3 && name.startsWith("cpu") && allDigits(name)) {
            count += 1
        }
    }
    count
}

private func allDigits(name: String): Bool {
    var index = 3
    let runes = name.toRuneArray()
    while (index < runes.size) {
        let value = UInt32(runes[index])
        if (value < 48 || value > 57) {
            return false
        }
        index += 1
    }
    true
}
