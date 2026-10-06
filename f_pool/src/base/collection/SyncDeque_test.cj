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
package fountain::f_pool.base.collection

import std.collection.ArrayList
import std.env.getStdErr
import std.sync.{AtomicBool, AtomicInt64}
import fountain::f_pool.diagnostics.PoolDiagnostics

@Test
public class SyncDequeTest {
    @TestCase
    public func testGiveBack(){
        let o = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o)
        @Assert(deque.size, 1)
        @Assert(deque.remove({_=>true}){_=>}.isSome())
        @Assert(deque.remove({_=>true}){_=>}.isNone())
        @Assert(deque.size, 1)
        deque.append(o, {_=>true}){_=>}
        @Assert(deque.size, 1)
        @Assert(deque.remove({_=>true}){_=>}.isSome())
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
    @TestCase
    public func testRemoveInvalid(){
        let o = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o)
        @Assert(deque.remove({_=>false}){_=>}.isNone())
    }
    @TestCase
    public func testAppendInvalid(){
        let o = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o)
        deque.remove({_=>true}){_=>}
        deque.append(o, {_=>false}){_=>}
        @Assert(deque.size, 0)
    }
    @TestCase
    public func testPrependInvalid(){
        let o = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o)
        deque.remove({_=>true}){_=>}
        deque.prepend(o, {_=>false}){_=>}
        @Assert(deque.size, 0)
    }
    @TestCase
    public func testAdd(){
        let o = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o)
        deque.insertTail(o)
        @Assert(deque.size, 2)
        deque.insertHead(o)
        @Assert(deque.size, 3)
    }
    @TestCase
    public func testFifo(){
        let o1 = Object()
        let o2 = Object()
        let o3 = Object()
        let deque = SyncDeque<Object>()
        
        deque.insertTail(o1)
        deque.insertTail(o2)
        deque.insertTail(o3)
        @Assert(deque.size, 3)
        @Assert(refEq(deque.remove({_=>true}){_=>}.getOrThrow(), o1))
        @Assert(deque.size, 3)
        @Assert(refEq(deque.remove({_=>true}){_=>}.getOrThrow(), o2))
        @Assert(deque.size, 3)
        @Assert(refEq(deque.remove({_=>true}){_=>}.getOrThrow(), o3))
        @Assert(deque.size, 3)
    }
    @TestCase
    public func testLifo(){
        let o1 = Object()
        let o2 = Object()
        let o3 = Object()
        let deque = SyncDeque<Object>()
        deque.insertHead(o1)
        deque.insertHead(o2)
        deque.insertHead(o3)
        @Assert(deque.size, 3)
        @Assert(refEq(deque.remove({_=>true}){_=>}.getOrThrow(), o3))
        @Assert(deque.size, 3)
        @Assert(refEq(deque.remove({_=>true}){_=>}.getOrThrow(), o2))
        @Assert(deque.size, 3)
        @Assert(refEq(deque.remove({_=>true}){_=>}.getOrThrow(), o1))
        @Assert(deque.size, 3)
    }
    @TestCase
    public func testCheck(){
        let o1 = Object()
        let o2 = Object()
        let o3 = Object()
        let deque = SyncDeque<Object>()
        deque.insertHead(o1)
        deque.insertHead(o2)
        deque.insertHead(o3)
        deque.check({=>true}, {o => false}){}
        @Assert(deque.size, 0)
    }
    @TestCase
    public func testInvalid(){
        let o1 = PooledObject()
        let o2 = PooledObject()
        let o3 = PooledObject()
        let o4 = PooledObject()
        let deque = SyncDeque<PooledObject>()
        deque.insertTail(o1)
        deque.insertTail(o2)
        deque.insertTail(o3)
        deque.insertTail(o4)
        deque.check({=>true}, {o => o.id % 2 == 0}){}
        @Assert(deque.size, 2)
        @Assert(deque.remove({_=>true}){_=>}.getOrThrow().id, 2)
        @Assert(deque.remove({_=>true}){_=>}.getOrThrow().id, 4)
    }
    @TestCase
    public func testCheckerThrowingMustNotLoseElement(){
        // check 的校验函数抛异常时，异常可以往外抛（调度方会记日志），但池项一个都不能丢：
        // 被标记 CHECKING 的节点必须还原成 idle，否则它既取不到、也不会再被清理（见 .autocode/bugs/bug-archived-on-20261004.md 7.2）。
        let o1 = Object()
        let o2 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        deque.insertTail(o2)
        try {
            deque.check({=>true}, {_ => throw Exception('checker boom')}){}
        } catch (_: Exception) {
        }
        @Assert(deque.size, 2)
        @Assert(deque.remove({_=>true}){_=>}.isSome())
        @Assert(deque.remove({_=>true}){_=>}.isSome())
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
    @TestCase
    public func testTaskPusherThrowingMustNotLoseElement(){
        // taskPusher 抛异常时同理：本轮「已标记待处理」的那个节点也要还原，
        // 否则它永久停在 CHECKING、池记着它却取不出来（见 .autocode/bugs/bug-archived-on-20261004.md 7.2）。
        let o1 = Object()
        let o2 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        deque.insertTail(o2)
        try {
            deque.check({=>true}, {_ => false}){=> throw Exception('pusher boom')}
        } catch (_: Exception) {
        }
        @Assert(deque.size, 1)                       // 只应销毁 checker 返回 false 的那一个
        @Assert(deque.remove({_=>true}){_=>}.isSome())   // 另一个必须还能取到
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
    @TestCase
    public func testScanForwardMustReturnTakenElement(){
        // 队首节点不是 idle 时（例如正被 check 标记），借用要往后续扫：
        // 扫到的项必须真的返回给调用方。修前这里返回 None，而项已经被摘掉
        // ⇒ 池项凭空消失、size 还记着它（历史症状，见 .autocode/bugs/bug-archived-on-20261004.md 7.2）。
        let o1 = Object()
        let o2 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        deque.insertTail(o2)
        @Assert(deque.strandHeadForTest())          // 队首 o1 变成非 idle
        let taken = deque.remove({_=>true}){_=>}
        @Assert(taken.isSome())
        @Assert(refEq(taken.getOrThrow(), o2))
        @Assert(deque.size, 2)                      // 借出不改 size，也不能被"顺手"改小
    }
    @TestCase
    public func testBorrowCheckerThrowingMustNotLeakElement(){
        // 借出后的校验回调抛异常时，这一项既没被拿走、也不算"已归还" ⇒ 若不管，它会永久挂在 out 上
        // （池项凭空消失、池越用越小）。自愈：按"校验不过"结清（销毁 + 计数还原）后再抛出（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）。
        let o1 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        let destroyed = AtomicInt64(0)
        try {
            deque.remove({_ => throw Exception('checker boom')}){_ => destroyed.fetchAdd(1)}
        } catch (_: Exception) {
        }
        @Assert(destroyed.load(), 1)                       // 抛异常的那一项必须被销毁（结清）
        @Assert(deque.size, 0)                             // 结清后 size 归零：池能重新创建池项
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
    @TestCase
    public func testReturnCheckerThrowingMustNotLeakElement(){
        let o1 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        @Assert(deque.remove({_=>true}){_=>}.isSome())     // 借出（size 仍为 1，out=1）
        let destroyed = AtomicInt64(0)
        try {
            deque.append(o1, {_ => throw Exception('return checker boom')}){_ => destroyed.fetchAdd(1)}
        } catch (_: Exception) {
        }
        @Assert(destroyed.load(), 1)
        @Assert(deque.size, 0)                             // 不悬空：不会永久记着一个借出项
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
    @TestCase
    public func testDestroyerThrowingMustNotBreakAccounting(){
        let o1 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        deque.remove({_=>true}){_=>}                       // 借出
        // 归还时校验不过 ⇒ 会调 destroier；destroier 自己抛异常也不能让计数悬空
        deque.append(o1, {_ => false}){_ => throw Exception('destroier boom')}
        @Assert(deque.size, 0)
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
    @TestCase
    public func testAuditHealsStrandedWithoutBorrowAttempt(){
        // 巡检线程每轮都会调 audit()：不必等某个 get 取不到项，滞留项在空闲期就被修掉（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）
        let o1 = Object()
        let o2 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        deque.insertTail(o2)
        @Assert(deque.strandHeadForTest())
        @Assert(deque.audit() > 0)                        // 审计发现并修掉滞留
        @Assert(deque.remove({_=>true}){_=>}.isSome())    // 修完即可正常取用
        @Assert(deque.remove({_=>true}){_=>}.isSome())
    }
    @TestCase
    public func testDiagnosticsSnapshotTracksActivity(){
        // 自愈动作与借还都被记数：即使问题不复现，也能从统计判断"到底发生过没有"（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）
        let before = PoolDiagnostics.snapshot()
        let deque = SyncDeque<Object>()
        deque.insertTail(Object())
        @Assert(PoolDiagnostics.snapshot() != before)
        PoolDiagnostics.installCrashHandler()             // 幂等：重复安装不能抛
        PoolDiagnostics.installCrashHandler()
        PoolDiagnostics.dump(reason: 'unittest')
        @Assert(PoolDiagnostics.snapshot().size > 0)
    }
    @TestCase
    public func testWarningHookCanBeRedirected(){
        // 底层（SyncDeque）的告警默认写 stderr；能不能进 f_log 取决于上层注入的钩子。
        // 这里验证"注入的通道确实收到消息"，而不是库内自己写 stdout（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）。
        let collected = ArrayList<String>()
        PoolDiagnostics.redirectWarningsTo(
            warn: {message =>
                collected.add('[warn] ${message}')
                ()
            },
            error: {message =>
                collected.add('[error] ${message}')
                ()
            })
        let o1 = Object()
        let o2 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        deque.insertTail(o2)
        @Assert(deque.strandHeadForTest())
        @Assert(deque.audit() > 0)                        // 触发 WEDGE-HEAL 告警
        @Assert(collected.size > 0)
        @Assert(collected[0].contains('WEDGE-HEAL'))
        // 收尾：恢复成"默认通道"的样子（stderr），避免影响后续用例
        PoolDiagnostics.redirectWarningsTo(
            warn: {message =>
                getStdErr().writeln(message)
                ()
            },
            error: {message =>
                getStdErr().writeln(message)
                ()
            })
    }
    /**
     * `POOL-L1`（.autocode/bugs/bug-pool.md §3）：告警钩子**不得在 `head.globalLock` 临界区内**被调用。
     *
     * 判别方式：钩子执行期间让**另一根线程**去抢同一把锁（`insertTail` 内部就是
     * `synchronized(head.globalLock)`）——修前钩子在锁内，那根线程会被挡到钩子返回（`blocked=true`）；
     * 修后钩子跑在锁外，它应当立刻完成。触发沿用现成路径：`strandHeadForTest()` + `audit()` ⇒ `WEDGE-HEAL`。
     */
    @TestCase
    public func testWarningHookMustRunOutsideDequeLock(){
        let deque = SyncDeque<Object>()
        deque.insertTail(Object())
        @Assert(deque.strandHeadForTest())                   // 制造滞留项，逼出 WEDGE-HEAL
        let hookEntered = AtomicBool(false)
        let blockedWhileHookRan = AtomicBool(false)
        PoolDiagnostics.redirectWarningsTo(
            warn: {message =>
                if (message.contains('WEDGE-HEAL')) {
                    hookEntered.store(true)
                    let done = AtomicBool(false)
                    spawn {
                        deque.insertTail(Object())           // 另一根线程要同一把锁
                        done.store(true)
                    }
                    for (_ in 0 .. 200) {                    // 最多等 400ms：等到了 = 钩子没占着锁
                        if (done.load()) {
                            return
                        }
                        sleep(Duration.millisecond * 2)
                    }
                    blockedWhileHookRan.store(true)          // 钩子返回前它一直拿不到锁 ⇒ 钩子在锁内
                }
                ()
            },
            error: {message => ()})
        @Assert(deque.audit() > 0)                           // 触发 WEDGE-HEAL 告警
        @Assert(hookEntered.load())                          // 告警确实被逼出来了
        @Assert(blockedWhileHookRan.load(), false)            // 修前：true（钩子占着 deque 全局锁）
        // 收尾：恢复成"默认通道"的样子（stderr），避免影响后续用例（与 testWarningHookCanBeRedirected 一致）
        PoolDiagnostics.redirectWarningsTo(
            warn: {message =>
                getStdErr().writeln(message)
                ()
            },
            error: {message =>
                getStdErr().writeln(message)
                ()
            })
    }
    @TestCase
    public func testWeakDequeRemoveMustReturnElement(){
        // 弱引用池（Mode.WeakFifo/WeakLifo）走的是同一条"摘节点"路径：引用类型的池项包的是对象本身，
        // 修前只匹配 WeakRef<Box<T>> ⇒ 摘掉节点却返回 None，池项凭空丢失（见 .autocode/bugs/bug-archived-on-20261004.md 7.2）。
        let o = Object()
        let deque = WeakSyncDeque<Object>()
        deque.insertTail(o)
        let taken = deque.remove({_=>true}){_=>}
        @Assert(taken.isSome())
        @Assert(refEq(taken.getOrThrow(), o))
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
    /**
     * `POOL-L4`：`nodes`（锁内维护的 O(1) 计数，供 `selfCheck` 用）在混合操作之后必须与实际节点数一致 ——
     * 判据就是「`audit()`（实走对账）返回 0」= 没有需要修正的记账。
     * 覆盖：插入（insertHead/insertTail）、取走、归还（prepend/append）、校验不过丢弃（checker=false）、
     * 滞留项救回（`strandHeadForTest` + `audit`）。
     */
    @TestCase
    public func testNodeCountMustNotDrift(){
        let deque = SyncDeque<Int64>()
        for (i in 0 .. 50) {
            deque.insertHead(i)
            deque.insertTail(i)
        }
        for (_ in 0 .. 10) {
            if (deque.remove({_=>true}){_=>}.isNone()) {
                @Assert(false)
            }
        }
        deque.prepend(7, {_=>true}){_=>}             // 归还：节点 +1、out −1
        deque.append(8, {_=>true}){_=>}
        if (let Some(v) <- deque.remove({_=>true}){_=>}) {
            deque.prepend(v, {_=>false}){_=>}        // 校验不过 ⇒ 销毁 + 结清（节点数不变）
        } else {
            @Assert(false)
        }
        @Assert(deque.audit(), 0)                    // 实走对账：`nodes`/`s` 都一致 ⇒ 0
        @Assert(deque.strandHeadForTest())
        @Assert(deque.audit() > 0)                   // 救回滞留项
        @Assert(deque.audit(), 0)                    // 再对账一次：仍然一致
    }
    @TestCase
    public func testStrandedCheckingMustBeHealed(){
        // 人为制造历史现场：节点还在队列里、但停在 CHECKING（模拟 check 线程抛异常/被阻塞），
        // 于是「size 说还有可用项、实际一个也取不出来」；下一次取不到项时自愈应把它救回。
        let o1 = Object()
        let o2 = Object()
        let deque = SyncDeque<Object>()
        deque.insertTail(o1)
        deque.insertTail(o2)
        @Assert(deque.strandHeadForTest())
        @Assert(deque.remove({_=>true}){_=>}.isSome())   // 先取走没滞留的那个
        @Assert(deque.remove({_=>true}){_=>}.isNone())   // 滞留着 ⇒ 取不到 ⇒ 触发自愈
        @Assert(deque.remove({_=>true}){_=>}.isSome())   // 自愈后把滞留项救回、可正常取用
        @Assert(deque.remove({_=>true}){_=>}.isNone())
    }
}
class PooledObject {
    private static var count = 0
    let id = {=>
       count++
       count
    }()

}