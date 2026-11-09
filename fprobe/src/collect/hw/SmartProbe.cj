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
package fountain::fprobe.collect.hw

import std.collection.ArrayList
import fountain::f_data.*
import fountain::f_data.macros.*

/** 一块磁盘的 SMART 健康摘要。 */
@DataAssist[props fields]
public class SmartReading {
    private var device: String = ""
    private var model: String = ""
    private var health: String = ""
    private var temperatureCelsius: Float64 = 0.0
    private var available: Bool = true
    private var error: String = ""

    public init() {}

    public init(device: String, model: String, health: String, temperatureCelsius: Float64, available: Bool,
        error: String) {
        this.device = device
        this.model = model
        this.health = health
        this.temperatureCelsius = temperatureCelsius
        this.available = available
        this.error = error
    }
}

/*
 * smartctl -j 的完整 JSON 很大，这里只声明本探针使用的固定子结构。
 * 未声明字段由 DataObject 的 SILENCE 默认策略忽略，不手工遍历 JsonValue。
 */
@DataAssist[props fields]
class SmartctlDeviceInfo {
    private var name: String = ""

    public init() {}
}

@DataAssist[props fields]
class SmartctlSmartStatus {
    private var passed: Bool = false

    public init() {}
}

@DataAssist[props fields]
class SmartctlTemperature {
    private var current: Int64 = 0

    public init() {}
}

@DataAssist[props fields]
class SmartctlReport {
    private var device: SmartctlDeviceInfo = SmartctlDeviceInfo()
    private var model_name: String = ""
    private var smart_status: SmartctlSmartStatus = SmartctlSmartStatus()
    private var temperature: SmartctlTemperature = SmartctlTemperature()

    public init() {}
}

/**
 * 磁盘 SMART 采集。
 *
 * 首选 `smartctl -A -j <device>` 的结构化 JSON；老版本不支持 `-j` 时回退解析文本，
 * 并在 `error` 标注降级，保证「版本差异」不会让整块磁盘的数据消失。
 * 设备路径只允许 `/dev/` 下的字母、数字与 `._-/`，避免把配置值拼进危险参数。
 */
public class SmartProbe {
    private let runner: CommandRunner
    private let devices: Array<String>
    private let timeoutMs: Int64

    public init(runner: CommandRunner, devices: Array<String>, timeoutMs!: Int64 = 3000) {
        this.runner = runner
        this.devices = devices
        this.timeoutMs = timeoutMs
    }

    public func collect(): Array<SmartReading> {
        let readings = ArrayList<SmartReading>()
        for (device in devices) {
            if (!isSafeDevice(device)) {
                readings.add(SmartReading(device, "", "UNKNOWN", 0.0, false, '非法设备路径: "${device}"'))
                continue
            }
            readings.add(collectDevice(device))
        }
        readings.toArray()
    }

    private func collectDevice(device: String): SmartReading {
        let result = runner.run(["smartctl", "-A", "-j", device], timeoutMs: timeoutMs)
        if (result.timedOut) {
            return SmartReading(device, "", "UNKNOWN", 0.0, false, 'smartctl 执行超时（${timeoutMs}ms）')
        }
        if (!result.error.isEmpty()) {
            return SmartReading(device, "", "UNKNOWN", 0.0, false, 'smartctl 不可用: ${result.error}')
        }

        let text = result.stdout.trimAscii()
        if (text.startsWith("{")) {
            match (parseJson(text)) {
                case Some(report) => return fromJson(device, report)
                case None => ()
            }
        }

        let fallback = parseText(text)
        if (fallback.isSome()) {
            return SmartReading(device, fallback.getOrThrow().model, fallback.getOrThrow().health,
                fallback.getOrThrow().temperature, true, "smartctl 不支持 JSON 输出，已降级为文本解析")
        }

        if (result.exitCode != 0) {
            return SmartReading(device, "", "UNKNOWN", 0.0, false,
                'smartctl 退出码 ${result.exitCode}: ${result.stderr.trimAscii()}')
        }
        SmartReading(device, "", "UNKNOWN", 0.0, false, "smartctl 输出无法解析")
    }
}

class TextSmart {
    let model: String
    let health: String
    let temperature: Float64

    init(model: String, health: String, temperature: Float64) {
        this.model = model
        this.health = health
        this.temperature = temperature
    }
}

private func parseJson(text: String): ?SmartctlReport {
    try {
        let data = JsonValue.fromStr(text).toData()
        match (SmartctlReport.tryFromData(data)) {
            case report: SmartctlReport => Some(report)
            case report: ?SmartctlReport => report
            case _ => None<SmartctlReport>
        }
    } catch (_: Exception) {
        None<SmartctlReport>
    }
}

private func fromJson(device: String, report: SmartctlReport): SmartReading {
    let health = if (report.smart_status.passed) {
        "PASSED"
    } else {
        "FAILED"
    }
    SmartReading(device, report.model_name, health, Float64(report.temperature.current), true, "")
}

private func parseText(text: String): ?TextSmart {
    var model = ""
    var health = ""
    var temperature = 0.0
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) {
            continue
        }
        if (line.contains("Device Model:")) {
            model = valueAfterColon(line)
        } else if (line.contains("Model Number:")) {
            model = valueAfterColon(line)
        } else if (line.contains("overall-health")) {
            health = valueAfterColon(line)
        } else if (line.contains("Temperature:")) {
            match (firstNumber(valueAfterColon(line))) {
                case Some(number) => temperature = number
                case None => ()
            }
        }
    }
    if (model.isEmpty() && health.isEmpty() && temperature == 0.0) {
        return None<TextSmart>
    }
    Some(TextSmart(model, health, temperature))
}

private func valueAfterColon(line: String): String {
    match (line.lastIndexOf(':')) {
        case Some(index) => line[index + 1..].trimAscii()
        case None => ""
    }
}

private func firstNumber(text: String): ?Float64 {
    for (token in splitTokens(text)) {
        match (tryFloat(token)) {
            case Some(number) => return Some(number)
            case None => ()
        }
    }
    None<Float64>
}

/** 设备路径白名单：必须以 `/dev/` 开头，后续只允许字母、数字与 `._-/`。 */
private func isSafeDevice(device: String): Bool {
    if (!device.startsWith("/dev/") || device.size <= 5) {
        return false
    }
    for (rune in device.toRuneArray()) {
        let value = UInt32(rune)
        let digit = value >= 48 && value <= 57
        let upper = value >= 65 && value <= 90
        let lower = value >= 97 && value <= 122
        let slash = value == 47
        let dot = value == 46
        let underscore = value == 95
        let dash = value == 45
        if (!(digit || upper || lower || slash || dot || underscore || dash)) {
            return false
        }
    }
    true
}
