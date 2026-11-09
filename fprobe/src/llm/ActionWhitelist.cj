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
package fountain::fprobe.llm

/** 运维对建议的答复。 */
public enum ReplyDecision <: Equatable<ReplyDecision> {
    | APPROVE
    | REJECT

    public operator func ==(other: ReplyDecision): Bool {
        match ((this, other)) {
            case (APPROVE, APPROVE) | (REJECT, REJECT) => true
            case _ => false
        }
    }
}

/** 白名单动作的执行结果。 */
public enum WhitelistResult <: Equatable<WhitelistResult> {
    | ACKED
    | MUTED
    | REPORTED
    | NONE
    | REJECTED
    | UNSUPPORTED

    public operator func ==(other: WhitelistResult): Bool {
        match ((this, other)) {
            case (ACKED, ACKED) | (MUTED, MUTED) | (REPORTED, REPORTED) | (NONE, NONE) |
                (REJECTED, REJECTED) | (UNSUPPORTED, UNSUPPORTED) => true
            case _ => false
        }
    }
}

/**
 * 白名单动作执行器（spec「白名单动作」）。
 *
 * 只认 `ack` / `mute` / `report` / `none`；其余动作（包括模型自由生成的
 * `restart-service`、shell 命令）一律返回 `UNSUPPORTED` 且不产生副作用。
 */
public class ActionWhitelist {
    private let ack: (String) -> Unit
    private let mute: ((String, Int64)) -> Unit
    private let report: () -> Unit
    private let nowMs: () -> Int64
    private let muteSeconds: Int64

    public init(ack!: (String) -> Unit = {_ => ()},
        mute!: ((String, Int64)) -> Unit = {pair =>
            let _ = pair
            ()
        },
        report!: () -> Unit = {=> ()},
        nowMs!: () -> Int64, muteSeconds!: Int64 = 600) {
        this.ack = ack
        this.mute = mute
        this.report = report
        this.nowMs = nowMs
        this.muteSeconds = muteSeconds
    }

    public func apply(decision: ReplyDecision, action: String, rule: String): WhitelistResult {
        if (decision == ReplyDecision.REJECT) {
            return WhitelistResult.REJECTED
        }
        match (action.trimAscii().toAsciiLower()) {
            case "ack" =>
                ack(rule)
                WhitelistResult.ACKED
            case "mute" =>
                mute((rule, nowMs() + muteSeconds * 1000))
                WhitelistResult.MUTED
            case "report" =>
                report()
                WhitelistResult.REPORTED
            case "none" => WhitelistResult.NONE
            case _ => WhitelistResult.UNSUPPORTED
        }
    }
}
