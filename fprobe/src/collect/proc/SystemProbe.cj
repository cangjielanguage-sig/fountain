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

import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.{ProbeAgent, ProbeErrorCode, ProbeException}

/** `system` 监控项的数据形状。 */
@DataAssist[props fields]
public class SystemSample {
    private var uptimeSeconds: Float64 = 0.0
    private var processCount: Int64 = 0
    private var tcpConnections: Int64 = 0

    public init() {}

    public init(uptimeSeconds: Float64, processCount: Int64, tcpConnections: Int64) {
        this.uptimeSeconds = uptimeSeconds
        this.processCount = processCount
        this.tcpConnections = tcpConnections
    }
}

/**
 * 系统概览：uptime、进程数与 TCP 连接数。
 *
 * 进程数按 `/proc` 下的纯数字目录计数；TCP 连接数统计 IPv4/IPv6 两张表的数据行。
 */
public class SystemProbe <: ProbeAgent {
    private let reader: ProcReader

    public init(reader: ProcReader) {
        this.reader = reader
    }

    public prop kind: String {
        get() {
            "system"
        }
    }

    public prop data: JsonObject {
        get() {
            let uptime = parseUptime(requireFile(reader, "/proc/uptime"))
            let processCount = countProcesses()
            let tcpConnections = countTcp()
            let sample = SystemSample(uptime, processCount, tcpConnections)
            JsonValue.from(sample.toData()).asObject()
        }
    }

    private func countProcesses(): Int64 {
        let names = match (reader.list("/proc")) {
            case Some(values) => values
            case None => throw ProbeException(ProbeErrorCode.COLLECT, "读取 /proc 目录失败")
        }
        var count = 0
        for (name in names) {
            if (isNumericName(name)) {
                count += 1
            }
        }
        count
    }

    private func countTcp(): Int64 {
        let tcp4 = reader.read("/proc/net/tcp")
        let tcp6 = reader.read("/proc/net/tcp6")
        if (tcp4.isNone() && tcp6.isNone()) {
            throw ProbeException(ProbeErrorCode.COLLECT, "读取 /proc/net/tcp 与 tcp6 失败")
        }
        var total = 0
        match (tcp4) {
            case Some(text) => total += countSocketRows(text)
            case None => ()
        }
        match (tcp6) {
            case Some(text) => total += countSocketRows(text)
            case None => ()
        }
        total
    }
}

private func parseUptime(text: String): Float64 {
    let tokens = splitWhitespace(text)
    if (tokens.isEmpty()) {
        throw ProbeException(ProbeErrorCode.COLLECT, "/proc/uptime 内容为空")
    }
    match (tryFloat64(tokens[0])) {
        case Some(value) => value
        case None => throw ProbeException(ProbeErrorCode.COLLECT, '/proc/uptime 不是数字: "${tokens[0]}"')
    }
}

private func countSocketRows(text: String): Int64 {
    var rows = 0
    var first = true
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        if (first) {
            first = false
            if (!startsWithDigit(line)) {
                // 表头 `sl local_address ...`
                continue
            }
        }
        rows += 1
    }
    rows
}

private func startsWithDigit(line: String): Bool {
    let runes = line.toRuneArray()
    if (runes.isEmpty()) {
        return false
    }
    let value = UInt32(runes[0])
    value >= 48 && value <= 57
}

private func isNumericName(name: String): Bool {
    let runes = name.toRuneArray()
    if (runes.isEmpty()) {
        return false
    }
    for (rune in runes) {
        let value = UInt32(rune)
        if (value < 48 || value > 57) {
            return false
        }
    }
    true
}
