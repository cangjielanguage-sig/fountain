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
}
class PooledObject {
    private static var count = 0
    let id = {=>
       count++
       count
    }()

}