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

import std.collection.HashMap
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.{ProbeAgent, ProbeErrorCode, ProbeException}

/** `memory` 监控项的数据形状。 */
@DataAssist[props fields]
public class MemorySample {
    private var totalBytes: Int64 = 0
    private var usedBytes: Int64 = 0
    private var availableBytes: Int64 = 0
    private var freeBytes: Int64 = 0
    private var cachedBytes: Int64 = 0
    private var buffersBytes: Int64 = 0
    private var swapTotalBytes: Int64 = 0
    private var swapUsedBytes: Int64 = 0
    private var swapFreeBytes: Int64 = 0

    public init() {}

    public init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64, freeBytes: Int64, cachedBytes: Int64,
        buffersBytes: Int64, swapTotalBytes: Int64, swapUsedBytes: Int64, swapFreeBytes: Int64) {
        this.totalBytes = totalBytes
        this.usedBytes = usedBytes
        this.availableBytes = availableBytes
        this.freeBytes = freeBytes
        this.cachedBytes = cachedBytes
        this.buffersBytes = buffersBytes
        this.swapTotalBytes = swapTotalBytes
        this.swapUsedBytes = swapUsedBytes
        this.swapFreeBytes = swapFreeBytes
    }
}

/**
 * 内存使用情况。
 *
 * `usedBytes` 按 `MemTotal - MemAvailable` 计算；只看 `MemFree` 会明显高估已用内存。
 */
public class MemoryProbe <: ProbeAgent {
    private let reader: ProcReader

    public init(reader: ProcReader) {
        this.reader = reader
    }

    public prop kind: String {
        get() {
            "memory"
        }
    }

    public prop data: JsonObject {
        get() {
            let text = requireFile(reader, "/proc/meminfo")
            let values = parseMeminfo(text)
            let total = requireValue(values, "MemTotal")
            let available = requireValue(values, "MemAvailable")
            let free = values.get("MemFree") ?? 0
            let cached = values.get("Cached") ?? 0
            let buffers = values.get("Buffers") ?? 0
            let swapTotal = values.get("SwapTotal") ?? 0
            let swapFree = values.get("SwapFree") ?? 0
            let used = if (total > available) {
                total - available
            } else {
                0
            }
            let swapUsed = if (swapTotal > swapFree) {
                swapTotal - swapFree
            } else {
                0
            }
            let sample = MemorySample(total, used, available, free, cached, buffers, swapTotal, swapUsed, swapFree)
            JsonValue.from(sample.toData()).asObject()
        }
    }
}

private func parseMeminfo(text: String): HashMap<String, Int64> {
    let values = HashMap<String, Int64>()
    for (line in text.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty()) {
            continue
        }
        let separator = match (trimmed.indexOf(":")) {
            case Some(index) => index
            case None => continue
        }
        let key = trimmed[0..separator].trimAscii()
        let rest = trimmed[separator + 1..].trimAscii()
        let parts = splitWhitespace(rest)
        if (parts.isEmpty()) {
            continue
        }
        match (tryInt64(parts[0])) {
            case Some(value) => values[key] = value * 1024
            case None => throw ProbeException(ProbeErrorCode.COLLECT, '/proc/meminfo 的 ${key} 不是数字: "${parts[0]}"')
        }
    }
    values
}

private func requireValue(values: HashMap<String, Int64>, key: String): Int64 {
    match (values.get(key)) {
        case Some(value) => value
        case None => throw ProbeException(ProbeErrorCode.COLLECT, '/proc/meminfo 缺少 ${key}')
    }
}
