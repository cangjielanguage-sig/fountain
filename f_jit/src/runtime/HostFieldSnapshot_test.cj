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

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType

/** 快照语义的两个探针类（同 index、不同类）。 */
private class SnapA {
    var v: Int64 = 1
}

private class SnapB {
    var v: Int64 = 2
}

/**
 * `HostFieldTable` 的**快照语义护栏**（`optimize-call-path-phase1` P1.2）。
 *
 * 本项是纯性能重构：这些用例在实现前后都应通过（设计已声明 TDD 例外）；
 * keep/revert 只由 `F1/F4` 数据决定。
 */
@Test
public class HostFieldSnapshot_test {

    private static func reg(index: UInt16, tag: Int64): Unit {
        HostFieldTable.register(index: index, `type`: LocalType.I64, mutable: true,
            accepts: { o => if (tag == 1) { o is SnapA } else { o is SnapB } },
            getter: { o => match (o) {
                case a: SnapA => a.v
                case b: SnapB => b.v
                case _ => 0
            } },
            setter: { o, v => match ((o, v)) {
                case (a: SnapA, x: Int64) => a.v = x
                case (b: SnapB, x: Int64) => b.v = x
                case _ => ()
            } })
    }

    /** 同 index 多类：按注册序 + `accepts` 命中唯一访问器。 */
    @TestCase
    public func sameIndexMultipleClassesKeepRegistrationOrder(): Unit {
        HostFieldTable.resetForTest()
        HostFieldSnapshot_test.reg(5u16, 1)
        HostFieldSnapshot_test.reg(5u16, 2)
        let a = SnapA()
        let b = SnapB()
        match (HostFieldTable.find(a, 5u16)) {
            case Some(acc) =>
                match (acc.getter(a)) {
                    case x: Int64 => @Assert(x, 1)
                    case _ => @Fail('A getter type')
                }
            case None => @Fail('A not found')
        }
        match (HostFieldTable.find(b, 5u16)) {
            case Some(acc) =>
                match (acc.getter(b)) {
                    case x: Int64 => @Assert(x, 2)
                    case _ => @Fail('B getter type')
                }
            case None => @Fail('B not found')
        }
        HostFieldTable.resetForTest()
    }

    /** 读线程反复 find 的同时写线程注册新 index：不崩、不空表、不死锁。 */
    @TestCase
    public func concurrentReadAndRegister(): Unit {
        HostFieldTable.resetForTest()
        HostFieldSnapshot_test.reg(1u16, 1)
        let a = SnapA()
        let done = AtomicInt64(0)
        let reader = spawn {
            var hits = 0
            var i = 0
            while (i < 50000) {
                match (HostFieldTable.find(a, 1u16)) {
                    case Some(_) => hits = hits + 1
                    case None => ()
                }
                i = i + 1
            }
            let _ = done.fetchAdd(1)
            hits
        }
        var k = 100
        while (k < 300) {
            HostFieldSnapshot_test.reg(UInt16(k), 1)
            k = k + 1
        }
        @Assert(reader.get(), 50000)
        @Assert(done.load(), 1)
        HostFieldTable.resetForTest()
    }

    /** `accepts` 内部再注册：不死锁，本次查找仍完成，新条目随后可查。 */
    @TestCase
    public func reentrantRegisterInsideAccepts(): Unit {
        HostFieldTable.resetForTest()
        let once = AtomicInt64(0)
        HostFieldTable.register(index: 3u16, `type`: LocalType.I64, mutable: true,
            accepts: { o =>
                if (once.load() == 0) {
                    let _ = once.fetchAdd(1)
                    HostFieldTable.register(index: 4u16, `type`: LocalType.I64, mutable: true,
                        accepts: { _ => true },
                        getter: { _ => 7 },
                        setter: { _, _ => () })
                }
                o is SnapA
            },
            getter: { _ => 11 },
            setter: { _, _ => () })
        @Assert(HostFieldTable.find(SnapA(), 3u16).isSome(), true)
        @Assert(once.load(), 1)
        @Assert(HostFieldTable.find(SnapA(), 4u16).isSome(), true)
        HostFieldTable.resetForTest()
    }

    /** `resetForTest` 发布空快照：旧 index 不再命中。 */
    @TestCase
    public func resetPublishesEmptySnapshot(): Unit {
        HostFieldTable.resetForTest()
        HostFieldSnapshot_test.reg(9u16, 1)
        @Assert(HostFieldTable.find(SnapA(), 9u16).isSome(), true)
        HostFieldTable.resetForTest()
        @Assert(HostFieldTable.find(SnapA(), 9u16).isNone(), true)
    }
}
