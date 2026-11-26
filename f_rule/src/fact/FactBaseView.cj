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
package fountain::f_rule.fact

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.exception.*

/**
 * 视图隔离级别（`doc/02-fact-model.md` §6.7）。
 *
 * - `Isolated`：子视图事实对父不可见，`commitToParent` 时合并（`fork` 默认）；
 * - `Shared`：直接读写父视图，用于规则流内共享同一批事实。
 */
public enum IsolationLevel <: ToString & Equatable<IsolationLevel> {
    | Isolated
    | Shared

    public func toString(): String {
        match (this) {
            case Isolated => "Isolated"
            case Shared => "Shared"
        }
    }

    public operator func ==(other: IsolationLevel): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: IsolationLevel): Bool {
        !(this == other)
    }
}

/**
 * 会话 + 空间级事实视图（`doc/02-fact-model.md` §6.7）。
 *
 * 同一 `(space, session)` 由 [FactBaseViewStore] 保证返回同一视图；不同组合的
 * `FactBase` 互不可见。`fork` 出的 `Isolated` 视图持有独立事实库，
 * `commitToParent` 把事实以新句柄合并到父视图。
 */
public class FactBaseView {
    private let spaceRef_: FactSpace
    private let session_: String
    private let base_: FactBase
    private let parent_: ?FactBaseView
    private let level_: IsolationLevel

    init(space: FactSpace, session: String, base: FactBase, parent: ?FactBaseView, level: IsolationLevel) {
        this.spaceRef_ = space
        this.session_ = session
        this.base_ = base
        this.parent_ = parent
        this.level_ = level
    }

    public prop space: String {
        get() {
            spaceRef_.id
        }
    }

    public prop session: String {
        get() {
            session_
        }
    }

    public prop level: IsolationLevel {
        get() {
            level_
        }
    }

    public func assert(fact: Fact): FactHandle {
        base_.assert(fact)
    }

    /** 拷贝字段后插入（用于可变业务对象）。 */
    public func assertCopy(fact: Fact): FactHandle {
        base_.assertCopy(fact)
    }

    public func retract(handle: FactHandle): Bool {
        base_.retract(handle)
    }

    public func update(handle: FactHandle, fact: Fact): Bool {
        base_.update(handle, fact)
    }

    public func get(handle: FactHandle): ?Fact {
        base_.get(handle)
    }

    public func scan(typeTag: String): Array<FactHandle> {
        base_.scan(typeTag)
    }

    /**
     * 把事实复制到另一个视图（F-17/F-18）。
     *
     * 复制的是**字段快照**（`assertCopy`），目标空间生成新句柄；两边后续的撤销互不影响。
     * 跨库关联只允许这种显式物化，不存在隐式跨空间可见性。
     */
    public func copyTo(target: FactBaseView, fact: Fact): FactHandle {
        target.assertCopy(fact)
    }

    public func size(): Int64 {
        var total: Int64 = 0
        for (typeTag in spaceRef_.typeTags()) {
            total += base_.scan(typeTag).size
        }
        total
    }

    /**
     * 派生子视图。
     *
     * `Isolated`（默认）新建独立事实库；`Shared` 复用父事实库，读写立即互相可见。
     */
    public func fork(childSession: String, level!: IsolationLevel = IsolationLevel.Isolated): FactBaseView {
        match (level) {
            case Shared => FactBaseView(spaceRef_, childSession, base_, Some(this), level)
            case Isolated =>
                FactBaseView(spaceRef_, childSession, FactBase(spaceRef_, childSession), Some(this), level)
        }
    }

    /**
     * 把本视图事实合并到父视图。
     *
     * 只对 `Isolated` 生效；父视图已有同一实例时跳过（幂等）。合并后的句柄属于父视图，
     * 子视图随后的撤销不影响父视图。
     */
    public func commitToParent(): Unit {
        match (parent_) {
            case None => ()
            case Some(parent) =>
                match (level_) {
                    case Shared => ()
                    case Isolated =>
                        for (typeTag in spaceRef_.typeTags()) {
                            for (handle in base_.scan(typeTag)) {
                                match (base_.get(handle)) {
                                    case Some(fact) =>
                                        try {
                                            let _ = parent.base_.assert(fact)
                                        } catch (e: RuleException) {
                                            // 父视图已持有同一实例：提交是幂等的
                                            if (e.code != RuleErrorCode.DUPLICATE_FACT) {
                                                throw e
                                            }
                                        }
                                    case None => ()
                                }
                            }
                        }
                }
        }
    }
}

/**
 * `(space, session)` → 视图的缓存（`doc/02-fact-model.md` §6.7）。
 *
 * 视图缓存挂在引擎/会话生命周期上，不放在全局静态里，避免跨引擎串会话。
 */
public class FactBaseViewStore {
    private let registry_: FactSpaceRegistry
    private let views_: HashMap<String, FactBaseView>

    public init(registry: FactSpaceRegistry) {
        this.registry_ = registry
        this.views_ = HashMap<String, FactBaseView>()
    }

    /** 取视图；空间未声明抛 `UNKNOWN_FACT_SPACE`。 */
    public func view(space: String, session: String): FactBaseView {
        let key = FactBaseViewStore.key(space, session)
        match (views_.get(key)) {
            case Some(existing) => return existing
            case None => ()
        }
        let factSpace = match (registry_.get(space)) {
            case Some(found) => found
            case None =>
                throw RuleException(
                    RuleErrorCode.UNKNOWN_FACT_SPACE,
                    "规则集未声明事实空间 ${space}"
                )
        }
        let created = FactBaseView(factSpace, session, FactBase(factSpace, session), None, IsolationLevel.Shared)
        views_[key] = created
        created
    }

    /** 释放某个会话的全部空间视图。 */
    public func release(session: String): Unit {
        let prefix = FactBaseViewStore.key("", session)
        let victims = ArrayList<String>()
        for ((key, _) in views_) {
            if (key.endsWith(prefix)) {
                victims.add(key)
            }
        }
        for (key in victims) {
            views_.remove(key)
        }
    }

    /** 释放单个 `(space, session)` 视图。 */
    public func release(space: String, session: String): Bool {
        match (views_.remove(FactBaseViewStore.key(space, session))) {
            case Some(_) => true
            case None => false
        }
    }

    /** 分隔符不可出现在空间名/会话名里即可；用控制字符降低碰撞概率。 */
    private static func key(space: String, session: String): String {
        "${space}\u{0001}${session}"
    }
}
