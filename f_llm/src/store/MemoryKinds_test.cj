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
package fountain::f_llm.store

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

class FakeKindPersistence <: KindPersistence {
    public var inserted: Int64 = 0
    private let rows = HashMap<String, Bool>()
    private let custom = HashMap<Int64, ArrayList<String>>()

    public func has(kind: String): Bool {
        rows.contains(kind)
    }

    public func insert(kind: String, predefined: Bool): Unit {
        rows[kind] = predefined
        inserted++
    }

    public func allCustom(): HashMap<Int64, ArrayList<String>> {
        let copy = HashMap<Int64, ArrayList<String>>()
        for((userId, kinds) in custom){
            let items = ArrayList<String>()
            items.add(all: kinds)
            copy[userId] = items
        }
        copy
    }

    public func insertCustom(userId: Int64, kind: String): Unit {
        match(custom.get(userId)){
            case Some(kinds) => kinds.add(kind)
            case None =>
                let kinds = ArrayList<String>()
                kinds.add(kind)
                custom[userId] = kinds
        }
    }

    public func deleteCustom(userId: Int64, kind: String): Unit {
        match(custom.get(userId)){
            case Some(kinds) =>
                let kept = ArrayList<String>()
                for(item in kinds){
                    if(item != kind){
                        kept.add(item)
                    }
                }
                custom[userId] = kept
            case None => ()
        }
    }
}

@Test
public class MemoryKindsTest {

    @TestCase
    func testPredefinedAreFixed(): Unit {
        MemoryKinds.resetForTest()
        let kinds = MemoryKinds.predefined()
        @Expect(kinds.size, 9)
        @Expect(kinds[0], 'note')
        @Expect(kinds[6], 'session')
        @Expect(kinds[7], 'experience')
        @Expect(kinds[8], 'experience_failed')
    }

    @TestCase
    func testCustomKindBelongsToUser(): Unit {
        MemoryKinds.resetForTest()
        @Expect(MemoryKinds.register(1, 'meeting'), true)
        @Expect(has(MemoryKinds.all(1), 'meeting'), true)
        @Expect(has(MemoryKinds.all(2), 'meeting'), false)
        @Expect(MemoryKinds.validate(1, 'meeting'), true)
        @Expect(MemoryKinds.validate(2, 'meeting'), false)
    }

    @TestCase
    func testPredefinedCannotBeRemoved(): Unit {
        MemoryKinds.resetForTest()
        var thrown = false
        try{
            MemoryKinds.remove(1, 'note')
        }catch(_: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
        @Expect(MemoryKinds.validate(1, 'note'), true)
    }

    @TestCase
    func testRegisterIsIdempotent(): Unit {
        MemoryKinds.resetForTest()
        @Expect(MemoryKinds.register(1, 'meeting'), true)
        @Expect(MemoryKinds.register(1, 'meeting'), false)
        @Expect(MemoryKinds.register(1, 'note'), false)
    }

    @TestCase
    func testRemoveOnlyOwnCustomKind(): Unit {
        MemoryKinds.resetForTest()
        MemoryKinds.register(1, 'meeting')
        @Expect(MemoryKinds.remove(2, 'meeting'), false)
        @Expect(MemoryKinds.remove(1, 'meeting'), true)
        @Expect(MemoryKinds.validate(1, 'meeting'), false)
    }

    @TestCase
    func testSeedIsIdempotent(): Unit {
        MemoryKinds.resetForTest()
        let persistence = FakeKindPersistence()
        MemoryKinds.seed(persistence)
        @Expect(persistence.inserted, Int64(MemoryKinds.predefined().size))
        MemoryKinds.seed(persistence)
        @Expect(persistence.inserted, Int64(MemoryKinds.predefined().size))
    }

    @TestCase
    func testInvalidKindIsRejected(): Unit {
        MemoryKinds.resetForTest()
        var thrown = false
        try{
            MemoryKinds.register(1, 'bad kind!')
        }catch(_: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }
    /** 经验 kind 是预定义集合的一部分 */
    @TestCase
    func testExperienceKindsArePredefined(): Unit {
        let kinds = MemoryKinds.predefined()
        @Expect(kinds.contains('experience'), true)
        @Expect(kinds.contains('experience_failed'), true)
        @Expect(MemoryKinds.validate(0, 'experience'), true)
        @Expect(MemoryKinds.validate(0, 'experience_failed'), true)
    }

    /** 纳入预定义不改变权重：两者都是 0.8 */
    @TestCase
    func testExperienceKindWeightUnchanged(): Unit {
        @Expect(MemoryKinds.weightOf('experience'), 0.8)
        @Expect(MemoryKinds.weightOf('experience_failed'), 0.8)
    }
}

private func has(values: ArrayList<String>, target: String): Bool {
    for(value in values){
        if(value == target){
            return true
        }
    }
    false
}
