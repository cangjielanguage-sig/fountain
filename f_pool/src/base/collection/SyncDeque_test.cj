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
        // 被标记 CHECKING 的节点必须还原成 idle，否则它既取不到、也不会再被清理（见 bug.md 7.2）。
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
        // 否则它永久停在 CHECKING、池记着它却取不出来（见 bug.md 7.2）。
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
        // ⇒ 池项凭空消失、size 还记着它（历史症状，见 bug.md 7.2）。
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
    public func testWeakDequeRemoveMustReturnElement(){
        // 弱引用池（Mode.WeakFifo/WeakLifo）走的是同一条"摘节点"路径：引用类型的池项包的是对象本身，
        // 修前只匹配 WeakRef<Box<T>> ⇒ 摘掉节点却返回 None，池项凭空丢失（见 bug.md 7.2）。
        let o = Object()
        let deque = WeakSyncDeque<Object>()
        deque.insertTail(o)
        let taken = deque.remove({_=>true}){_=>}
        @Assert(taken.isSome())
        @Assert(refEq(taken.getOrThrow(), o))
        @Assert(deque.remove({_=>true}){_=>}.isNone())
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