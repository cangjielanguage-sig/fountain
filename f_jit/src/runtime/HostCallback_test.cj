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
package fountain::f_jit.runtime

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken

/**
 * Q4.3 条目缓存 + Q4.4 `HostCallback`（m2 §1/§4）。
 *
 * `HostCallback = {fn, sig}` 是句柄表 tag=10 的载荷；`sig` 的存在性即「验签结果缓存」，
 * `cached` 只收条目、不做「对象 → 条目」定位。
 */
@Test
public class HostCallback_test {
    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
    }

    /** 条目构造 / 字段保真：fn 与 sig 原样保存。 */
    @TestCase
    public func fieldsArePreserved(): Unit {
        let f: Any = { x: Int64 => x + 1 }
        let sig = SignatureDescriptor([LocalType.I64], LocalType.I64)
        let cb = HostCallback(f, sig)
        @Assert(cb.fn is (Int64) -> Int64, true)
        match (cb.sig) {
            case Some(s) =>
                @Assert(s.params.size, 1)
                @Assert(s.params[0], LocalType.I64)
                @Assert(s.ret, LocalType.I64)
            case None => @Fail('已验签条目的 sig 不应为 None')
        }
    }

    /** 未验签条目：`sig = None`。 */
    @TestCase
    public func unverifiedEntryHasNoSig(): Unit {
        let cb = HostCallback({ x: Int64 => x })
        @Assert(cb.sig.isNone(), true)
    }

    /** `cached`：已验签 → 返回条目内的描述符（同一实例，幂等复用）。 */
    @TestCase
    public func cachedReturnsEntrySig(): Unit {
        let sig = SignatureDescriptor([LocalType.I64], LocalType.BOOL)
        let cb = HostCallback({ x: Int64 => x > 0 }, sig)
        let a = SignatureVerifier.cached(cb)
        let b = SignatureVerifier.cached(cb)
        match (a) {
            case Some(sa) =>
                @Assert(refEq(sa, sig), true)
                match (b) {
                    case Some(sb) => @Assert(refEq(sb, sa), true)
                    case None => @Fail('第二次缓存读取不应为空')
                }
            case None => @Fail('已验签条目应命中缓存')
        }
    }

    /** `cached`：未验签 → `None`（由调用方走 verify 并写回条目）。 */
    @TestCase
    public func cachedMissesUnverifiedEntry(): Unit {
        let cb = HostCallback({ x: Int64 => x })
        @Assert(SignatureVerifier.cached(cb).isNone(), true)
    }

    /** 验签 → 缓存闭环：verify 的产物写入条目后可由 cached 直接复用。 */
    @TestCase
    public func verifyThenCacheRoundTrip(): Unit {
        let value: Any = { x: Int64 => x > 0 }
        let declared = SignatureDescriptor([LocalType.I64], LocalType.BOOL)
        match (SignatureVerifier.verify(value, declared)) {
            case Some(prod) =>
                let cb = HostCallback(value, prod)
                @Assert(SignatureVerifier.cached(cb).isSome(), true)
            case None => @Fail('合法签名验签失败')
        }
    }

    /** pin 同一对象复用同 ID；不同对象不同 ID。 */
    @TestCase
    public func pinSameObjectSameId(): Unit {
        setup()
        let cb = HostCallback({ x: Int64 => x })
        let a = HandleTable.pin(cb)
        let b = HandleTable.pin(cb)
        @Assert(a, b)
        let other = HostCallback({ x: Int64 => x })
        let c = HandleTable.pin(other)
        @Assert(c == a, false)
    }

    /** 条目标签 = 10（TypeToken.HOST_CLOSURE）。 */
    @TestCase
    public func pinnedEntryUsesHostClosureTag(): Unit {
        setup()
        let cb = HostCallback({ => 1 })
        let id = HandleTable.pin(cb)
        @Assert(HandleTable.tagOf(id), TypeToken.HOST_CLOSURE)
        @Assert(HandleTable.tagOfHandle(id), TypeToken.HOST_CLOSURE)
    }

    /** 条目持强引用：pin 后经句柄表取回的仍是同一对象（GC 托管对象被条目保活）。 */
    @TestCase
    public func entryIsStronglyReferenced(): Unit {
        setup()
        let cb = HostCallback({ => 1 })
        let id = HandleTable.pin(cb)
        match (HandleTable.getAny(id)) {
            case Some(v) =>
                match (v) {
                    case back: HostCallback => @Assert(refEq(back, cb), true)
                    case _ => @Fail('取回对象类型不符')
                }
            case None => @Fail('条目丢失')
        }
    }
}
