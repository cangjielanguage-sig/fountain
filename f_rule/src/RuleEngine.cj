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
package fountain::f_rule

import std.collection.HashMap
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.rete.ShardedNetwork
import fountain::f_rule.rule.RuleSet

/**
 * 规则引擎门面（`doc/08-api.md` §8）。
 *
 * 一个引擎对应一个已构建的 `RuleSet`：网络结构只建一次，会话通过 `session(id)`
 * 共享结构、隔离事实与令牌。`close()` 级联关闭规则集，之后任何执行都抛 `CLOSED`。
 */
public class RuleEngine {
    private let ruleSet_: RuleSet
    private let network_: ShardedNetwork
    private let sessions_: HashMap<String, RuleSession>
    private var closed_: Bool

    /** 规则集必须是已构建且未关闭的，否则抛 `ILLEGAL_STATE`。 */
    public init(ruleSet: RuleSet) {
        if (!ruleSet.isValid()) {
            throw RuleException(
                RuleErrorCode.ILLEGAL_STATE,
                "规则集 ${ruleSet.id} 校验失败或已关闭，不能构造引擎"
            )
        }
        this.ruleSet_ = ruleSet
        this.network_ = ShardedNetwork(ruleSet)
        this.sessions_ = HashMap<String, RuleSession>()
        this.closed_ = false
    }

    public prop ruleSet: RuleSet {
        get() {
            ruleSet_
        }
    }

    public prop closed: Bool {
        get() {
            closed_
        }
    }

    /** 创建/获取会话。同 id 返回同一会话。 */
    public func session(id: String): RuleSession {
        ensureOpen()
        match (sessions_.get(id)) {
            case Some(existing) => return existing
            case None => ()
        }
        let created = RuleSession(this, id)
        sessions_[id] = created
        created
    }

    /** 释放会话及其事实、令牌、议程；不存在时返回 false。 */
    public func release(id: String): Bool {
        match (sessions_.remove(id)) {
            case Some(existing) =>
                existing.dispose()
                true
            case None => false
        }
    }

    func network(): ShardedNetwork {
        network_
    }

    /** 关闭引擎：级联关闭规则集，释放全部会话。 */
    public func close(): Unit {
        if (closed_) {
            return
        }
        closed_ = true
        for ((_, session) in sessions_) {
            session.dispose()
        }
        sessions_.clear()
        ruleSet_.close()
    }

    private func ensureOpen(): Unit {
        if (closed_) {
            throw RuleException(RuleErrorCode.CLOSED, "引擎已关闭")
        }
    }
}
