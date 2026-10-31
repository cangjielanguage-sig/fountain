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
package fountain::f_rule.rete

import std.collection.HashMap
import std.sync.Mutex
import fountain::f_rule.agenda.Bindings
import fountain::f_rule.fact.{Fact, FactHandle}

/**
 * Rete 令牌（`doc/04-rete-network.md` §5）。
 *
 * 结构共享：子令牌只保存 `(parent, handle, binding)`，绑定表沿父链展开，
 * 因此 N 个模式的规则每条令牌的内存是 O(1) 而不是 O(N)。
 *
 * 相等性只看 `(parent, handle)`：同一路径的同一事实只产生一个令牌，
 * 重复传播天然去重（R-10）。绑定名不参与判等，但同一规则内绑定名唯一，
 * 因此不会出现歧义。
 *
 * `fact` 只保存引用（事实对象由 `FactBase` 持有），供 [bindings] 展开绑定表。
 */
public class Token <: Hashable & Equatable<Token> & ToString {
    private static let idMtx = Mutex()
    private static var idCounter: Int64 = 0

    /** 进程内单调 id；范围索引用它区分同值令牌。 */
    public let id: Int64
    public let parent: ?Token
    public let handle: FactHandle
    public let binding: String
    public let fact: Fact
    private var refCount_: Int64
    private var released_: Bool

    private init(parent: ?Token, handle: FactHandle, binding: String, fact: Fact) {
        this.id = Token.nextId()
        this.parent = parent
        this.handle = handle
        this.binding = binding
        this.fact = fact
        this.refCount_ = 0
        this.released_ = false
    }

    private static func nextId(): Int64 {
        synchronized(idMtx) {
            idCounter += 1
            idCounter
        }
    }

    /** 首模式的哑令牌：没有父链。 */
    public static func root(handle: FactHandle, binding: String, fact: Fact): Token {
        Token(None, handle, binding, fact)
    }

    /** 子令牌；自动为父令牌 `retain`，保证父链在子令牌存活期间不被回收。 */
    public static func child(parent: Token, handle: FactHandle, binding: String, fact: Fact): Token {
        parent.retain()
        Token(Some(parent), handle, binding, fact)
    }

    /** 当前引用计数。 */
    public prop refCount: Int64 {
        get() {
            refCount_
        }
    }

    /** 引用计数是否已归零（父链已释放）。 */
    public func isReleased(): Bool {
        released_
    }

    /** 下游引用 +1。 */
    public func retain(): Unit {
        if (!released_) {
            refCount_ += 1
        }
    }

    /**
     * 下游引用 -1；归零时递归释放父链。
     *
     * 返回本次调用是否真的递减了计数：已释放的令牌再 `release` 返回 false，
     * 避免重复触发父链释放。
     */
    public func release(): Bool {
        if (released_) {
            return false
        }
        if (refCount_ > 0) {
            refCount_ -= 1
        }
        if (refCount_ == 0) {
            released_ = true
            match (parent) {
                case Some(upstream) => let _ = upstream.release()
                case None => ()
            }
        }
        true
    }

    /** 沿父链展开绑定表；只应在产生激活或校验 join 时调用。 */
    public func bindings(): Bindings {
        let handles = HashMap<String, FactHandle>()
        let facts = HashMap<String, Fact>()
        var cursor: ?Token = Some(this)
        while (let Some(current) <- cursor) {
            handles[current.binding] = current.handle
            facts[current.binding] = current.fact
            cursor = current.parent
        }
        Bindings.of(handles, facts)
    }

    public operator func ==(other: Token): Bool {
        leftRightEqual(this.parent, other.parent) && this.handle == other.handle
    }

    public operator func !=(other: Token): Bool {
        !(this == other)
    }

    @OverflowWrapping
    public func hashCode(): Int64 {
        var parentHash: Int64 = 17
        match (parent) {
            case Some(upstream) => parentHash = upstream.hashCode()
            case None => ()
        }
        parentHash * 31 + handle.hashCode()
    }

    public func toString(): String {
        "${binding}=${handle}"
    }

    private static func leftRightEqual(left: ?Token, right: ?Token): Bool {
        match ((left, right)) {
            case (None, None) => true
            case (Some(a), Some(b)) => a == b
            case _ => false
        }
    }
}
