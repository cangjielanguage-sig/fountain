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

/** 单个网卡的质量指标；字节数为累计值，速率为相邻采样差分。 */
@DataAssist[props fields]
public class NetworkInterface {
    private var name: String = ""
    private var rxBytes: Int64 = 0
    private var txBytes: Int64 = 0
    private var rxBytesPerSec: Float64 = 0.0
    private var txBytesPerSec: Float64 = 0.0
    private var bandwidthPercent: Float64 = 0.0
    private var dropPercent: Float64 = 0.0
    private var errorPercent: Float64 = 0.0
    private var tcpRetransPercent: Float64 = 0.0

    public init() {}

    public init(name: String, rxBytes: Int64, txBytes: Int64, rxBytesPerSec: Float64, txBytesPerSec: Float64,
        bandwidthPercent: Float64, dropPercent: Float64, errorPercent: Float64, tcpRetransPercent: Float64) {
        this.name = name
        this.rxBytes = rxBytes
        this.txBytes = txBytes
        this.rxBytesPerSec = rxBytesPerSec
        this.txBytesPerSec = txBytesPerSec
        this.bandwidthPercent = bandwidthPercent
        this.dropPercent = dropPercent
        this.errorPercent = errorPercent
        this.tcpRetransPercent = tcpRetransPercent
    }
}

/** `network` 监控项的数据形状。 */
@DataAssist[props fields]
public class NetworkSample {
    private var interfaces: Array<NetworkInterface> = []

    public init() {}

    public init(interfaces: Array<NetworkInterface>) {
        this.interfaces = interfaces
    }
}

struct NetCounters {
    let name: String
    let rxBytes: Int64
    let rxPackets: Int64
    let rxErrs: Int64
    let rxDrop: Int64
    let txBytes: Int64
    let txPackets: Int64
    let txErrs: Int64
    let txDrop: Int64

    init(name: String, rxBytes: Int64, rxPackets: Int64, rxErrs: Int64, rxDrop: Int64, txBytes: Int64,
        txPackets: Int64, txErrs: Int64, txDrop: Int64) {
        this.name = name
        this.rxBytes = rxBytes
        this.rxPackets = rxPackets
        this.rxErrs = rxErrs
        this.rxDrop = rxDrop
        this.txBytes = txBytes
        this.txPackets = txPackets
        this.txErrs = txErrs
        this.txDrop = txDrop
    }
}

struct SnmpCounters {
    let outSegs: Int64
    let retransSegs: Int64

    init(outSegs: Int64, retransSegs: Int64) {
        this.outSegs = outSegs
        this.retransSegs = retransSegs
    }
}

/**
 * 网络质量：网卡收发速率、带宽占比、丢包/错误率与 TCP 重传率。
 *
 * 速率基于 `/proc/net/dev` 相邻帧差分；带宽来自 `/sys/class/net/<if>/speed`（Mbps），
 * 文件缺失或为 0 时带宽占比保持 0，不影响其它指标。`probe_networkInterfaces`
 * 非空时只保留白名单网卡。
 */
public class NetworkProbe <: ProbeAgent {
    private let reader: ProcReader
    private let whitelist: HashSet<String>
    private let nowMs: () -> Int64
    private var hasBaseline = false
    private var lastNowMs: Int64 = 0
    private let previous = HashMap<String, NetCounters>()
    private var hasSnmpBaseline = false
    private var previousSnmp = SnmpCounters(0, 0)

    public init(reader: ProcReader, whitelist: Array<String>) {
        this(reader, whitelist, {=> networkNowMs()})
    }

    public init(reader: ProcReader, whitelist: Array<String>, nowMs: () -> Int64) {
        this.reader = reader
        this.whitelist = HashSet<String>()
        for (name in whitelist) {
            let trimmed = name.trimAscii()
            if (!trimmed.isEmpty()) {
                this.whitelist.add(trimmed)
            }
        }
        this.nowMs = nowMs
    }

    public prop kind: String {
        get() {
            "network"
        }
    }

    public prop data: JsonObject {
        get() {
            let counters = parseNetDev(requireFile(reader, "/proc/net/dev"))
            let snmp = parseSnmp(readOptional(reader, "/proc/net/snmp"))
            let retrans = retransPercent(snmp)
            let now = nowMs()
            let elapsed = if (hasBaseline) {
                now - lastNowMs
            } else {
                0
            }

            let interfaces = ArrayList<NetworkInterface>()
            for (current in counters) {
                if (!whitelist.isEmpty() && !whitelist.contains(current.name)) {
                    previous[current.name] = current
                    continue
                }
                var rxPerSec = 0.0
                var txPerSec = 0.0
                var dropPercent = 0.0
                var errorPercent = 0.0
                match (previous.get(current.name)) {
                    case Some(last) =>
                        if (elapsed > 0) {
                            let seconds = Float64(elapsed) / 1000.0
                            rxPerSec = Float64(nonNegativeDelta(current.rxBytes, last.rxBytes)) / seconds
                            txPerSec = Float64(nonNegativeDelta(current.txBytes, last.txBytes)) / seconds
                            let packets = nonNegativeDelta(current.rxPackets, last.rxPackets) +
                                nonNegativeDelta(current.txPackets, last.txPackets)
                            if (packets > 0) {
                                let drops = nonNegativeDelta(current.rxDrop, last.rxDrop) +
                                    nonNegativeDelta(current.txDrop, last.txDrop)
                                let errors = nonNegativeDelta(current.rxErrs, last.rxErrs) +
                                    nonNegativeDelta(current.txErrs, last.txErrs)
                                dropPercent = clampPercent(100.0 * Float64(drops) / Float64(packets))
                                errorPercent = clampPercent(100.0 * Float64(errors) / Float64(packets))
                            }
                        }
                    case None => ()
                }
                let bandwidth = bandwidthPercent(current.name, rxPerSec, txPerSec)
                interfaces.add(NetworkInterface(current.name, current.rxBytes, current.txBytes, rxPerSec, txPerSec,
                    bandwidth, dropPercent, errorPercent, retrans))
                previous[current.name] = current
            }
            lastNowMs = now
            hasBaseline = true
            JsonValue.from(NetworkSample(interfaces.toArray()).toData()).asObject()
        }
    }

    private func bandwidthPercent(name: String, rxPerSec: Float64, txPerSec: Float64): Float64 {
        let speedMbps = readSpeed(name)
        if (speedMbps <= 0.0) {
            return 0.0
        }
        let bitsPerSecond = if (rxPerSec > txPerSec) {
            rxPerSec
        } else {
            txPerSec
        } * 8.0
        clampPercent(100.0 * bitsPerSecond / (speedMbps * 1000000.0))
    }

    private func readSpeed(name: String): Float64 {
        match (reader.read("/sys/class/net/${name}/speed")) {
            case Some(text) =>
                match (tryFloat64(text.trimAscii())) {
                    case Some(value) => if (value > 0.0) {
                        value
                    } else {
                        0.0
                    }
                    case None => 0.0
                }
            case None => 0.0
        }
    }

    private func retransPercent(current: SnmpCounters): Float64 {
        if (!hasSnmpBaseline) {
            hasSnmpBaseline = true
            previousSnmp = current
            return 0.0
        }
        let outDelta = nonNegativeDelta(current.outSegs, previousSnmp.outSegs)
        let retransDelta = nonNegativeDelta(current.retransSegs, previousSnmp.retransSegs)
        previousSnmp = current
        if (outDelta <= 0) {
            return 0.0
        }
        clampPercent(100.0 * Float64(retransDelta) / Float64(outDelta))
    }
}

private func networkNowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

private func readOptional(reader: ProcReader, path: String): String {
    match (reader.read(path)) {
        case Some(text) => text
        case None => ""
    }
}

private func parseNetDev(text: String): Array<NetCounters> {
    let counters = ArrayList<NetCounters>()
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        let colon = match (line.indexOf(':')) {
            case Some(index) => index
            case None => continue
        }
        let name = line[0..colon].trimAscii()
        if (name.isEmpty()) {
            continue
        }
        let tokens = splitWhitespace(line[colon + 1..])
        if (tokens.size < 16) {
            throw ProbeException(ProbeErrorCode.COLLECT, '/proc/net/dev 行字段不足: "${line}"')
        }
        counters.add(NetCounters(name, requireNetInt(tokens[0]), requireNetInt(tokens[1]), requireNetInt(tokens[2]),
            requireNetInt(tokens[3]), requireNetInt(tokens[8]), requireNetInt(tokens[9]), requireNetInt(tokens[10]),
            requireNetInt(tokens[11])))
    }
    counters.toArray()
}

private func requireNetInt(token: String): Int64 {
    match (tryInt64(token)) {
        case Some(value) => value
        case None => throw ProbeException(ProbeErrorCode.COLLECT, '/proc/net/dev 含有非数字字段: "${token}"')
    }
}

private func parseSnmp(text: String): SnmpCounters {
    var header = Array<String>()
    var values = Array<String>()
    for (raw in text.split("\n")) {
        let tokens = splitWhitespace(raw)
        if (tokens.size < 2 || tokens[0] != "Tcp:") {
            continue
        }
        if (header.isEmpty()) {
            if (tryInt64(tokens[1]).isNone()) {
                header = tokens[1..]
            }
            continue
        }
        if (values.isEmpty() && tryInt64(tokens[1]).isSome()) {
            values = tokens[1..]
        }
    }
    if (header.isEmpty() || values.isEmpty()) {
        return SnmpCounters(0, 0)
    }
    SnmpCounters(snmpValue(header, values, "OutSegs"), snmpValue(header, values, "RetransSegs"))
}

private func snmpValue(header: Array<String>, values: Array<String>, name: String): Int64 {
    var index = 0
    while (index < header.size) {
        if (header[index] == name && index < values.size) {
            match (tryInt64(values[index])) {
                case Some(value) => return value
                case None => return 0
            }
        }
        index += 1
    }
    0
}
