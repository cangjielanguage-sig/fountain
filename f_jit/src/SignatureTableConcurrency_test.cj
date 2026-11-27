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
package fountain::f_jit

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.{HostSignature, LocalType, SignatureRegistry}
import fountain::f_jit.runtime.{SignatureDescriptor, SignatureTable}

/**
 * 宿主签名两表的**语义护栏**（`optimize-signature-tables`）。
 *
 * 实现从「全局锁 + 线性扫 `sameShape`」改为「结构键 `HashMap` + 不可变快照」，
 * 语义必须逐条不变。本套**不调用任何 `resetForTest`**（避免清掉包级注册），
 * 全部用唯一类名/唯一签名，断言只依赖相对关系。
 *
 * 关键一条是 `classNameDistinguishes`：键必须包含**逐位类名**，
 * 否则 `(User) -> R` 与 `(Order) -> R` 会撞成同一个 id（历史上就是靠 `paramNames` 区分的）。
 */
@Test
public class SignatureTableConcurrency_test {
    private static func uniq(tag: String, i: Int64): String {
        'SigTableGuard::${tag}::${i}'
    }

    private static func hostSig(name: String): HostSignature {
        HostSignature(params: [LocalType.HOST_OBJECT], paramNames: [name],
            ret: LocalType.I64, retName: '', display: '(${name}) -> Int64',
            adapter: { _, _ => 0 })
    }

    /** 同结构重复注册返回同一 id（幂等）。 */
    @TestCase
    public func registerIsIdempotent(): Unit {
        let name = SignatureTableConcurrency_test.uniq('idem', 0)
        let a = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(name))
        let b = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(name))
        @Assert(a, b)
    }

    /** 不同结构 → id 互不相同且随登记递增。 */
    @TestCase
    public func idsAreDistinctAndOrdered(): Unit {
        let i0 = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(
            SignatureTableConcurrency_test.uniq('ord', 0)))
        let i1 = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(
            SignatureTableConcurrency_test.uniq('ord', 1)))
        let i2 = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(
            SignatureTableConcurrency_test.uniq('ord', 2)))
        @Assert(i0 < i1, true)
        @Assert(i1 < i2, true)
    }

    /** 类名是签名的区分维度：两个同码不同类名的签名不能撞 id。 */
    @TestCase
    public func classNameDistinguishes(): Unit {
        let n0 = SignatureTableConcurrency_test.uniq('cls', 0)
        let n1 = SignatureTableConcurrency_test.uniq('cls', 1)
        let u = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(n0))
        let o = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(n1))
        @Assert(u != o, true)
        @Assert(SignatureRegistry.find([LocalType.HOST_OBJECT], [n0], LocalType.I64, ''),
            Some(u))
        @Assert(SignatureRegistry.find([LocalType.HOST_OBJECT], [n1], LocalType.I64, ''),
            Some(o))
    }

    /** `find` / `get` / `adapterOf` 三者口径一致；未登记与越界都是 `None`。 */
    @TestCase
    public func lookupsAgree(): Unit {
        let name = SignatureTableConcurrency_test.uniq('look', 0)
        let id = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(name))
        @Assert(SignatureRegistry.find([LocalType.HOST_OBJECT], [name], LocalType.I64, ''),
            Some(id))
        @Assert(SignatureRegistry.get(id).isSome(), true)
        @Assert(SignatureRegistry.adapterOf([LocalType.HOST_OBJECT], [name], LocalType.I64,
            '').isSome(), true)
        @Assert(SignatureRegistry.find([LocalType.HOST_OBJECT],
            [SignatureTableConcurrency_test.uniq('look', 99)], LocalType.I64, '').isNone(), true)
        @Assert(SignatureRegistry.get(Int32(SignatureRegistry.count() + 1000)).isNone(), true)
    }

    /** 并发：4 线程各注册 50 个唯一签名，同时 4 线程反复读已注册 id。 */
    @TestCase
    public func concurrentRegisterAndFind(): Unit {
        let probe = ArrayList<Int32>()
        var i = 0
        while (i < 8) {
            probe.add(SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(
                SignatureTableConcurrency_test.uniq('cc-r', i))))
            i = i + 1
        }
        let base = SignatureRegistry.count()
        let bad = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            let tag = t
            fs.add(spawn {
                var k = 0
                while (k < 50) {
                    let _ = SignatureRegistry.register(SignatureTableConcurrency_test.hostSig(
                        SignatureTableConcurrency_test.uniq('cc-w${tag}-', k)))
                    k = k + 1
                }
                0
            })
            t = t + 1
        }
        var r = 0
        while (r < 4) {
            fs.add(spawn {
                var k = 0
                while (k < 2000) {
                    let id = probe[k % 8]
                    if (SignatureRegistry.get(id).isNone()) {
                        let _ = bad.fetchAdd(1)
                    }
                    if (SignatureRegistry.find([LocalType.HOST_OBJECT],
                        [SignatureTableConcurrency_test.uniq('cc-r', Int64(k % 8))],
                        LocalType.I64, '').isNone()) {
                        let _ = bad.fetchAdd(1)
                    }
                    k = k + 1
                }
                0
            })
            r = r + 1
        }
        for (f in fs) {
            @Assert(f.get(), 0)
        }
        @Assert(bad.load(), 0)
        // 200 个唯一签名，每个只登记一次 ⇒ 计数恰增 200。
        @Assert(SignatureRegistry.count(), base + 200)
    }

    /** `SignatureTable`：同签名只建一次计划。 */
    @TestCase
    public func planIsBuiltOnce(): Unit {
        // 用 5 个 Int64 形参的罕见组合，避免与既有用例/包级注册撞车。
        let sig = SignatureDescriptor([LocalType.I64, LocalType.I64, LocalType.I64,
            LocalType.I64, LocalType.I64], LocalType.I64)
        let before = SignatureTable.buildCount()
        let p1 = SignatureTable.getOrBuild(sig)
        let p2 = SignatureTable.getOrBuild(sig)
        @Assert(p1.isSome(), true)
        @Assert(p2.isSome(), true)
        @Assert(SignatureTable.buildCount(), before + 1)
    }

    /** 开关关闭 → `None`；恢复后可用（`finally` 保证不污染其它用例）。 */
    @TestCase
    public func planRespectsSwitch(): Unit {
        let sig = SignatureDescriptor([LocalType.F64, LocalType.F64, LocalType.F64], LocalType.F64)
        try {
            SignatureTable.enabled = false
            @Assert(SignatureTable.getOrBuild(sig).isNone(), true)
        } finally {
            SignatureTable.enabled = true
        }
        @Assert(SignatureTable.getOrBuild(sig).isSome(), true)
    }
}
