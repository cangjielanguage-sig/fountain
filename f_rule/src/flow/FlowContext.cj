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
package fountain::f_rule.flow

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import fountain::f_base.*
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{Fact, FactBaseView, FactBaseViewStore, FactSpaceRegistry, TypeTag}

/**
 * 会话事实的释放策略（`doc/06-flow-orchestration.md` §5.2）。
 *
 * - `Discard`（缺省）：直接丢弃会话事实；
 * - `Archive`：先交给注册的 [FactArchiver]，再丢弃；
 * - `Retain`：保留上下文，供流程重入/补偿（清理由调用方负责）。
 */
public enum Release <: ToString & Equatable<Release> {
    | Discard
    | Archive
    | Retain

    public func toString(): String {
        match (this) {
            case Discard => "Discard"
            case Archive => "Archive"
            case Retain => "Retain"
        }
    }

    public operator func ==(other: Release): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: Release): Bool {
        !(this == other)
    }
}

/** `Release.Archive` 的策略钩子；实现方决定落盘到哪里。 */
public interface FactArchiver {
    func archive(session: String, space: String, fact: Fact): Unit
}

/**
 * 一个会话在多个 `FactSpace` 上的视图集合（`doc/06-flow-orchestration.md` §5.1）。
 *
 * 视图按需惰性创建，同一 `(space, session)` 返回同一 `FactBaseView`。上下文以
 * `(ruleSetId, session)` 为键缓存；`attach`/`detach` 通过 `ThreadLocal` 绑定当前线程，
 * 供 f_jit 脚本读取。空间声明表由 [configure] 注入，未声明的空间抛 `UNKNOWN_FACT_SPACE`。
 */
public class FlowContext {
    private static let lock = Mutex()
    private static let contexts = HashMap<String, FlowContext>()
    private static let registries = HashMap<String, FactSpaceRegistry>()
    private static let current_ = ThreadLocal<FlowContext>()
    private static var archiver_: ?FactArchiver = None

    private let ruleSetId_: String
    private let session_: String
    private let spaces_: ArrayList<String>
    private var store_: ?FactBaseViewStore = None
    private let viewLock = Mutex()

    private init(ruleSetId: String, session: String) {
        this.ruleSetId_ = ruleSetId
        this.session_ = session
        this.spaces_ = ArrayList<String>()
    }

    public prop session: String {
        get() {
            session_
        }
    }

    public prop ruleSetId: String {
        get() {
            ruleSetId_
        }
    }

    /** 缺省空间 `default` 的事实视图。 */
    public prop facts: FactBaseView {
        get() {
            factsOf(TypeTag.DEFAULT_SPACE)
        }
    }

    /** 指定空间的事实视图；空间未声明时抛 `UNKNOWN_FACT_SPACE`。 */
    public func factsOf(space: String): FactBaseView {
        let registry = registryOf(ruleSetId_)
        synchronized(viewLock) {
            let store = match (store_) {
                case Some(found) => found
                case None =>
                    let created = FactBaseViewStore(registry)
                    store_ = Some(created)
                    created
            }
            let view = store.view(space, session_)
            if (!spaces_.contains(space)) {
                spaces_.add(space)
            }
            view
        }
    }

    /** 当前上下文已激活的空间 id（按首次访问顺序）。 */
    public func spaces(): Array<String> {
        synchronized(viewLock) {
            spaces_.toArray()
        }
    }

    /** 按信封建立或复用会话上下文，并绑定到当前线程。 */
    public static func attach(envelope: RuleEnvelope): FlowContext {
        let ctx = create(envelope.ruleSetId, envelope.session)
        bind(ctx)
        ctx
    }

    /** 解绑当前线程；不释放会话。 */
    public static func detach(): Unit {
        unbind()
    }

    /** 显式创建（或复用）会话上下文。 */
    public static func create(ruleSetId: String, session: String): FlowContext {
        synchronized(lock) {
            let key = FlowContext.key(ruleSetId, session)
            match (contexts.get(key)) {
                case Some(existing) => return existing
                case None => ()
            }
            let created = FlowContext(ruleSetId, session)
            contexts[key] = created
            created
        }
    }

    /** 释放会话：按 [Release] 策略丢弃 / 归档 / 保留事实。 */
    public static func release(session: String, policy!: Release = Release.Discard): Unit {
        let victims = ArrayList<FlowContext>()
        synchronized(lock) {
            let keys = ArrayList<String>()
            for ((key, ctx) in contexts) {
                if (ctx.session_ == session) {
                    keys.add(key)
                    victims.add(ctx)
                }
            }
            if (policy != Release.Retain) {
                for (key in keys) {
                    contexts.remove(key)
                }
            }
        }
        for (ctx in victims) {
            match (policy) {
                case Release.Retain => ()
                case Release.Archive =>
                    archiveFacts(ctx)
                    releaseViews(ctx)
                case Release.Discard => releaseViews(ctx)
            }
        }
    }

    /** 当前线程绑定的上下文；未绑定时抛 `NO_CONTEXT`。 */
    public static func current(): FlowContext {
        match (current_.get()) {
            case Some(ctx) => ctx
            case None =>
                throw RuleException(RuleErrorCode.NO_CONTEXT, "当前线程未绑定 FlowContext")
        }
    }

    public static func bind(ctx: FlowContext): Unit {
        current_.set(Some(ctx))
    }

    public static func unbind(): Unit {
        current_.remove()
    }

    /** 注入规则集的空间声明表；同一 `ruleSetId` 后注入者生效。 */
    public static func configure(ruleSetId: String, registry: FactSpaceRegistry): Unit {
        synchronized(lock) {
            registries[ruleSetId] = registry
        }
    }

    /** 设置 `Release.Archive` 的归档器。 */
    public static func setArchiver(archiver: ?FactArchiver): Unit {
        synchronized(lock) {
            archiver_ = archiver
        }
    }

    /** 测试用：清空全部静态状态，避免用例之间串会话。 */
    static func resetForTest(): Unit {
        synchronized(lock) {
            contexts.clear()
            registries.clear()
            archiver_ = None
        }
        current_.remove()
    }

    private static func registryOf(ruleSetId: String): FactSpaceRegistry {
        synchronized(lock) {
            match (registries.get(ruleSetId)) {
                case Some(registry) => registry
                case None =>
                    throw RuleException(
                        RuleErrorCode.UNKNOWN_FACT_SPACE,
                        "规则集 ${ruleSetId} 未配置事实空间声明表"
                    )
            }
        }
    }

    private static func releaseViews(ctx: FlowContext): Unit {
        synchronized(ctx.viewLock) {
            match (ctx.store_) {
                case Some(store) => store.release(ctx.session_)
                case None => ()
            }
            ctx.spaces_.clear()
            ctx.store_ = None
        }
    }

    private static func archiveFacts(ctx: FlowContext): Unit {
        let target = synchronized(lock) {
            archiver_
        }
        match (target) {
            case None => ()
            case Some(archiver) =>
                synchronized(ctx.viewLock) {
                    match (ctx.store_) {
                        case None => ()
                        case Some(store) =>
                            let registry = registryOf(ctx.ruleSetId_)
                            for (space in ctx.spaces_.toArray()) {
                                let view = store.view(space, ctx.session_)
                                match (registry.get(space)) {
                                    case None => ()
                                    case Some(declared) =>
                                        for (typeTag in declared.typeTags()) {
                                            for (handle in view.scan(typeTag)) {
                                                match (view.get(handle)) {
                                                    case Some(fact) =>
                                                        archiver.archive(ctx.session_, space, fact)
                                                    case None => ()
                                                }
                                            }
                                        }
                                }
                            }
                    }
                }
        }
    }

    private static func key(ruleSetId: String, session: String): String {
        "${ruleSetId}\u{0001}${session}"
    }
}
