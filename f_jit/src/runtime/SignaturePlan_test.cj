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
import std.collection.ArrayList
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.TCase

/**
 * M3 R4.10–R4.12：CALL_HOST 转发特化（m3 §13）。
 *
 * 口径：
 * - **验签即建**：`HostCallback` 构造时 `SignatureTable.getOrBuild`，同签名（身份无关）只建一次；
 * - **逐位一致**：开关关闭（强制通用）与开启（特化）两条路径的结果 / 错误码完全相同；
 * - **N = 4**：argc ≤ 4 展开、> 4 循环，两路同结果（阈值是性能分档，不是形参上限）。
 */
@Test
public class SignaturePlan_test {
    private var ctx: ?JitContext = None

    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
        IterTable.clearAll()
        SignatureTable.resetForTest()
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        this.ctx = Some(JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 1, dbgBase: 0))
    }

    private func teardown(): Unit {
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        this.ctx = None
        SignatureTable.resetForTest()
    }

    private func call(args: Array<Int64>): Int64 {
        match (this.ctx) {
            case Some(c) => invokeHelper(c, Int64(HelperId.HOST_CALL_TRAMPOLINE), args)
            case None => 0
        }
    }

    private func err(): Int64 {
        match (this.ctx) {
            case Some(c) => c.errCode
            case None => -99
        }
    }

    /** 验签即建 + 身份无关：同签名两次构造只建一个计划。 */
    @TestCase
    public func plansAreBuiltOncePerSignature(): Unit {
        this.setup()
        let f: (Int64) -> Int64 = { x => x + 1 }
        let sig = SignatureDescriptor([LocalType.I64], LocalType.I64)
        let _ = HostCallback(f, sig)
        let _ = HostCallback(f, sig)
        @Assert(SignatureTable.buildCount(), 1)
        @Assert(SignatureTable.entryCount(), 1)
        this.teardown()
    }

    /** 不同签名各建一份（形参码序列 / 返回码都是键的一部分）。 */
    @TestCase
    public func distinctSignaturesBuildSeparately(): Unit {
        this.setup()
        let f1: (Int64) -> Int64 = { x => x + 1 }
        let f2: (String) -> Int64 = { s => s.size }
        let f3: (String) -> String = { s => s }
        let _ = HostCallback(f1, SignatureDescriptor([LocalType.I64], LocalType.I64))
        let _ = HostCallback(f2, SignatureDescriptor([LocalType.STRING], LocalType.I64))
        let _ = HostCallback(f3, SignatureDescriptor([LocalType.STRING], LocalType.STRING))
        @Assert(SignatureTable.buildCount(), 3)
        this.teardown()
    }

    /** 开关：关闭时**不建计划**（强制通用路径）；开启后恢复。 */
    @TestCase
    public func switchDisablesSpecialization(): Unit {
        this.setup()
        SignatureTable.enabled = false
        let f: (Int64) -> Int64 = { x => x + 1 }
        let sig = SignatureDescriptor([LocalType.I64], LocalType.I64)
        let h = HandleTable.pin(HostCallback(f, sig))
        @Assert(SignatureTable.buildCount(), 0)
        @Assert(SignatureTable.getOrBuild(sig).isNone(), true)
        // 通用路径照常工作
        @Assert(this.call([h, 3]), 4)
        @Assert(this.err(), 0)
        this.teardown()
    }

    /** 双路径逐位对拍：同一函数、同一实参，结果与错误码完全相同。 */
    @TestCase
    public func dualPathIsBitIdentical(): Unit {
        this.setup()
        let f: (Int64, String) -> String = { n, s => s + n.toString() }
        let sig = SignatureDescriptor([LocalType.I64, LocalType.STRING], LocalType.STRING)
        SignatureTable.enabled = false
        let h0 = HandleTable.pin(HostCallback(f, sig))
        SignatureTable.enabled = true
        let h1 = HandleTable.pin(HostCallback(f, sig))
        @Assert(SignatureTable.buildCount() >= 1, true)
        let s0 = HandleTable.pin('x')
        let r0 = this.call([h0, 7, s0])
        @Assert(this.err(), 0)
        let s1 = HandleTable.pin('x')
        let r1 = this.call([h1, 7, s1])
        @Assert(this.err(), 0)
        // 句柄型返回：两路各自分配新槽 ⇒ 比**值**不比 id（逐位口径 = 结果值 + errCode）
        let v0 = HandleTable.fetchString(r0)
        let v1 = HandleTable.fetchString(r1)
        @Assert(v0, 'x7')
        @Assert(v1, 'x7')
        @Assert(TCase.hit('T56/dual-path', v0 == v1), true)
        this.teardown()
    }

    /** N = 4 边界：argc 0–5 双路径同结果（≤4 展开、>4 循环）。 */
    @TestCase
    public func argcBoundaryMatchesBetweenPaths(): Unit {
        this.setup()
        let f0: () -> Int64 = { => 10 }
        let f1: (Int64) -> Int64 = { a => a }
        let f2: (Int64, Int64) -> Int64 = { a, b => a + b }
        let f3: (Int64, Int64, Int64) -> Int64 = { a, b, c => a + b + c }
        let f4: (Int64, Int64, Int64, Int64) -> Int64 = { a, b, c, d => a + b + c + d }
        let f5: (Int64, Int64, Int64, Int64, Int64) -> Int64 = { a, b, c, d, e =>
            a + b + c + d + e
        }
        let s0 = SignatureDescriptor(Array<UInt16>(), LocalType.I64)
        let s1 = SignatureDescriptor([LocalType.I64], LocalType.I64)
        let s2 = SignatureDescriptor([LocalType.I64, LocalType.I64], LocalType.I64)
        let s3 = SignatureDescriptor([LocalType.I64, LocalType.I64, LocalType.I64], LocalType.I64)
        let s4 = SignatureDescriptor([LocalType.I64, LocalType.I64, LocalType.I64, LocalType.I64],
            LocalType.I64)
        let s5 = SignatureDescriptor(
            [LocalType.I64, LocalType.I64, LocalType.I64, LocalType.I64, LocalType.I64],
            LocalType.I64)
        this.assertArity(f0, s0, 10)
        this.assertArity(f1, s1, 1)
        this.assertArity(f2, s2, 2)
        this.assertArity(f3, s3, 3)
        this.assertArity(f4, s4, 4)
        this.assertArity(f5, s5, 5)
        @Assert(TCase.hit('T56/argc-boundary', true), true)
        this.teardown()
    }

    /** 单个案：通用（开关关）与特化（开关开）两条路径逐位对拍。 */
    private func assertArity(fn: Any, sig: SignatureDescriptor, want: Int64): Unit {
        let argc = Int64(sig.params.size)
        SignatureTable.enabled = false
        let hg = HandleTable.pin(HostCallback(fn, sig))
        SignatureTable.enabled = true
        let hs = HandleTable.pin(HostCallback(fn, sig))
        let argv = Array<Int64>(argc + 1, repeat: 0)
        argv[0] = hg
        var i = 0
        while (i < argc) {
            argv[i + 1] = 1
            i = i + 1
        }
        let rg = this.call(argv)
        @Assert(this.err(), 0)
        argv[0] = hs
        let rs = this.call(argv)
        @Assert(this.err(), 0)
        @Assert(rg, want)
        @Assert(rs, want)
    }

    /** argc 上界 255：循环路径照常装配（N=4 只是分档，不是形参数量限制）。 */
    @TestCase
    public func planHandlesMaxArity(): Unit {
        this.setup()
        let sig = SignatureDescriptor(Array<UInt16>(255, repeat: LocalType.I64), LocalType.I64)
        let plan = SignaturePlan(sig)
        let a = Array<Int64>(256, repeat: 0)
        a[0] = 1
        var i = 1
        while (i < 256) {
            a[i] = Int64(i)
            i = i + 1
        }
        let args = plan.marshalArgs(a)
        @Assert(args.size, 255)
        match (args[254]) {
            case v: Int64 => @Assert(v, 255)
            case _ => @Fail('第 255 个实参未按 I64 还原')
        }
        this.teardown()
    }

    /** 条目有界：超过上限后不再缓存（表长恒定、行为不变）。 */
    @TestCase
    public func tableIsBounded(): Unit {
        this.setup()
        var n = 0
        while (n < SignatureTable.MAX_ENTRIES + 5) {
            let sig = SignatureDescriptor(Array<UInt16>(n, repeat: LocalType.I64), LocalType.I64)
            @Assert(SignatureTable.getOrBuild(sig).isSome(), true)
            n = n + 1
        }
        @Assert(SignatureTable.entryCount(), SignatureTable.MAX_ENTRIES)
        this.teardown()
    }
}
