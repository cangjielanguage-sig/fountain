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

/** 告警事件类别；恢复与数据缺失各自独立，便于渠道决定展示语义。 */
public enum AlarmEventType <: Equatable<AlarmEventType> {
    | FIRING
    | RECOVERY
    | NODE_UNREACHABLE
    | PROBE_ERROR
    | KIND_MISSING

    public operator func ==(other: AlarmEventType): Bool {
        match ((this, other)) {
            case (FIRING, FIRING) | (RECOVERY, RECOVERY) | (NODE_UNREACHABLE, NODE_UNREACHABLE) |
                (PROBE_ERROR, PROBE_ERROR) | (KIND_MISSING, KIND_MISSING) => true
            case _ => false
        }
    }
}

/**
 * 一条待分发的告警事件。
 *
 * [message] 是一行摘要；[format] 生成渠道消息（标题 + `key: value` 行），
 * 邮件渠道据此把字段渲染成 HTML 表格。
 */
public class AlarmEvent {
    public let eventType: AlarmEventType
    public let node: String
    public let rule: String
    public let kind: String
    public let level: String
    public let value: ?Float64
    public let threshold: Float64
    public let timestamp: Int64
    public let message: String

    public init(eventType: AlarmEventType, node: String, rule: String, kind: String, level: String,
        value: ?Float64, threshold: Float64, timestamp: Int64, message: String) {
        this.eventType = eventType
        this.node = node
        this.rule = rule
        this.kind = kind
        this.level = level
        this.value = value
        this.threshold = threshold
        this.timestamp = timestamp
        this.message = message
    }

    public func title(): String {
        match (eventType) {
            case FIRING => "【告警】"
            case RECOVERY => "【已恢复】"
            case NODE_UNREACHABLE => "【节点不可达】"
            case PROBE_ERROR => "【采集失败】"
            case KIND_MISSING => "【缺少监控项】"
        }
    }

    public func isRecovery(): Bool {
        eventType == AlarmEventType.RECOVERY
    }

    /** 渠道消息：第一行是标题与摘要，之后是 `key: value` 字段行。 */
    public func format(): String {
        var text = "${title()}${message}"
        text += "\n节点: ${node}"
        if (!rule.isEmpty()) {
            text += "\n规则: ${rule}"
        }
        if (!kind.isEmpty()) {
            text += "\n监控项: ${kind}"
        }
        match (value) {
            case Some(current) => text += "\n当前值: ${number(current)}"
            case None => ()
        }
        if (eventType == AlarmEventType.FIRING || eventType == AlarmEventType.RECOVERY) {
            text += "\n阈值: ${number(threshold)}"
        }
        if (!level.isEmpty()) {
            text += "\n级别: ${level}"
        }
        text += "\n时间: ${timestamp}"
        text
    }

    private func number(value: Float64): String {
        value.toString()
    }
}
