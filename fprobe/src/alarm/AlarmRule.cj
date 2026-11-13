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
package fountain::fprobe.alarm

import std.collection.ArrayList
import fountain::f_config.Config
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/** 规则比较运算符。 */
public enum AlarmOp <: Equatable<AlarmOp> {
    | Gt
    | Gte
    | Lt
    | Lte
    | Eq
    | Ne

    public operator func ==(other: AlarmOp): Bool {
        match ((this, other)) {
            case (Gt, Gt) | (Gte, Gte) | (Lt, Lt) | (Lte, Lte) | (Eq, Eq) | (Ne, Ne) => true
            case _ => false
        }
    }

    public static func parse(value: String): ?AlarmOp {
        match (value.trimAscii().toAsciiLower()) {
            case "gt" => Gt
            case "gte" => Gte
            case "lt" => Lt
            case "lte" => Lte
            case "eq" => Eq
            case "ne" => Ne
            case _ => None<AlarmOp>
        }
    }

    public func matches(value: Float64, threshold: Float64): Bool {
        match (this) {
            case Gt => value > threshold
            case Gte => value >= threshold
            case Lt => value < threshold
            case Lte => value <= threshold
            case Eq => value == threshold
            case Ne => value != threshold
        }
    }

    public func toString(): String {
        match (this) {
            case Gt => "gt"
            case Gte => "gte"
            case Lt => "lt"
            case Lte => "lte"
            case Eq => "eq"
            case Ne => "ne"
        }
    }
}

private let ALARM_RULE_FIELDS = ["name", "kind", "path", "op", "threshold", "forSeconds", "level"]

/**
 * `probe_alarmRules` 的一条规则。
 *
 * 用 `@DataAssist` 固定结构解析，配置阶段一次性完成字段与运算符校验；
 * 运行期只按 `DataPath` 取值，不再触碰 JSON 结构。
 */
@DataAssist[props fields]
public class AlarmRule {
    private var name: String = ""
    private var kind: String = ""
    private var path: String = ""
    private var op: String = ""
    private var threshold: Float64 = 0.0
    private var forSeconds: Int64 = 0
    private var level: String = ""

    public init() {}

    public init(name: String, kind: String, path: String, op: String, threshold: Float64,
        forSeconds: Int64, level: String) {
        this.name = name
        this.kind = kind
        this.path = path
        this.op = op
        this.threshold = threshold
        this.forSeconds = forSeconds
        this.level = level
    }

    /** 解析 JSON 数组；任何一条非法都会带序号失败，不会静默丢弃。 */
    public static func parse(text: String): Array<AlarmRule> {
        var root: JsonValue
        try {
            root = JsonValue.fromStr(text)
        } catch (_: Exception) {
            throw ProbeException(ProbeErrorCode.CONFIG, "probe_alarmRules 不是合法 JSON 数组")
        }

        let array = match (root) {
            case value: JsonArray => value
            case _ => throw ProbeException(ProbeErrorCode.CONFIG, "probe_alarmRules 必须是 JSON 数组")
        }

        let rules = ArrayList<AlarmRule>()
        let items = array.getItems()
        var index = 0
        while (index < items.size) {
            let position = index + 1
            let item = items[index]
            let object = match (item) {
                case value: JsonObject => value
                case _ => throw invalid(position, "必须是 JSON 对象")
            }
            for (field in ALARM_RULE_FIELDS) {
                if (!object.contains(field)) {
                    throw invalid(position, "缺少字段 ${field}")
                }
            }
            let rule = match (DataObject<AlarmRule>.populate(item.toData())) {
                case Some(value) => value
                case None => throw invalid(position, "无法转换为 AlarmRule")
            }
            validate(rule, position)
            rules.add(rule)
            index += 1
        }
        rules.toArray()
    }

    /** 读取 `probe_alarmRules`；未配置或空串返回空数组。 */
    public static func load(): Array<AlarmRule> {
        match (Config.getString("probe_alarmRules")) {
            case Some(text) =>
                let trimmed = text.trimAscii()
                if (trimmed.isEmpty()) {
                    []
                } else {
                    parse(trimmed)
                }
            case None => []
        }
    }

    private static func validate(rule: AlarmRule, position: Int64): Unit {
        if (rule.name.trimAscii().isEmpty()) {
            throw invalid(position, "name 不能为空")
        }
        if (rule.kind.trimAscii().isEmpty()) {
            throw invalid(position, "kind 不能为空")
        }
        if (rule.path.trimAscii().isEmpty()) {
            throw invalid(position, "path 不能为空")
        }
        if (AlarmOp.parse(rule.op).isNone()) {
            throw invalid(position, 'op "${rule.op}" 不受支持')
        }
        if (rule.forSeconds < 0) {
            throw invalid(position, "forSeconds 不能为负数")
        }
        if (rule.level.trimAscii().isEmpty()) {
            throw invalid(position, "level 不能为空")
        }
    }

    private static func invalid(position: Int64, detail: String): ProbeException {
        ProbeException(ProbeErrorCode.CONFIG, "probe_alarmRules 第 ${position} 条规则${detail}")
    }
}
