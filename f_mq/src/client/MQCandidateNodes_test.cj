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
package fountain::f_mq.client

import std.collection.ArrayList
import std.env.getVariable
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCFreedSize}
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

/** 旧写法：`ArrayList` + `contains` + `toArray`。 */
private func legacyCandidateNodes(preferred: Array<Int64>, all: Array<Int64>): Array<Int64> {
    let result = ArrayList<Int64>()
    for (node in preferred) {
        if (!result.contains(node)) {
            result.add(node)
        }
    }
    for (node in all) {
        if (!result.contains(node)) {
            result.add(node)
        }
    }
    result.toArray()
}

private func expectNodes(expected: Array<Int64>, actual: Array<Int64>): Unit {
    @Assert(expected.size, actual.size)
    for (i in 0..min(expected.size, actual.size)) {
        @Assert(expected[i], actual[i])
    }
}

private func mqBenchEnabled(): Bool {
    match (getVariable("F_MQ_BENCH")) {
        case Some(v) => v == "1"
        case None => false
    }
}

private func mqSettle(): Unit {
    for (_ in 0..3) {
        gc()
    }
}

private func mqMeasure(action: () -> Unit): (Int64, Int64) {
    let allocs = ArrayList<Int64>()
    var attempts = 0
    while (allocs.size < 5 && attempts < 20) {
        attempts++
        mqSettle()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        action()
        let alloc = (getAllocatedHeapSize() - heap0) + (getGCFreedSize() - freed0)
        if (alloc >= 0) {
            allocs.add(alloc)
        }
    }
    if (allocs.size == 0) {
        return (-1, 0)
    }
    var best = allocs[0]
    for (a in allocs) {
        if (a < best) {
            best = a
        }
    }
    (best, allocs.size)
}

@Test
public class MQCandidateNodes_test {
    /** owner 在前，其余节点按原顺序在后。 */
    @TestCase
    public func ownerFirstThenRest(): Unit {
        expectNodes([2, 3, 1, 4], candidateNodesOf([2, 3], [1, 2, 3, 4]))
    }

    /** preferred 内部重复只保留一个。 */
    @TestCase
    public func dedupePreferred(): Unit {
        expectNodes([2, 3], candidateNodesOf([2, 2, 3], []))
    }

    /** all 与 preferred 重复的节点不重复出现。 */
    @TestCase
    public func dedupeAllAgainstPreferred(): Unit {
        expectNodes([2, 1], candidateNodesOf([2], [2, 1, 2]))
    }

    /** all 内部重复只保留一个。 */
    @TestCase
    public func dedupeAll(): Unit {
        expectNodes([1, 2], candidateNodesOf([], [1, 1, 2]))
    }

    /** 空输入：双空为空，单边为空时取另一边。 */
    @TestCase
    public func emptyInputs(): Unit {
        expectNodes([], candidateNodesOf([], []))
        expectNodes([1], candidateNodesOf([], [1]))
        expectNodes([1], candidateNodesOf([1], []))
    }

    /**
     * n=8 的候选列表分配基准：新写法总量低于旧写法 1/2。
     */
    @TestCase
    public func testBenchCandidateAllocation(): Unit {
        if (!mqBenchEnabled()) {
            println("SKIP: 未设置 F_MQ_BENCH=1，候选节点分配基准不执行")
            return
        }
        let ops: Int64 = 5000
        let preferred: Array<Int64> = [1, 2]
        let all: Array<Int64> = [1, 2, 3, 4, 5, 6, 7, 8]
        let acc = AtomicInt64(0)

        let (producedAlloc, producedSamples) = mqMeasure({ =>
            for (_ in 0..ops) {
                acc.fetchAdd(candidateNodesOf(preferred, all).size)
            }
        })
        let (legacyAlloc, legacySamples) = mqMeasure({ =>
            for (_ in 0..ops) {
                acc.fetchAdd(legacyCandidateNodes(preferred, all).size)
            }
        })

        println('MQ_CANDIDATE_BENCH case=produced allocTotal=${producedAlloc} ' +
            'allocPerCall=${producedAlloc / ops} samples=${producedSamples}')
        println('MQ_CANDIDATE_BENCH case=legacy allocTotal=${legacyAlloc} ' +
            'allocPerCall=${legacyAlloc / ops} samples=${legacySamples}')
        @Assert(producedSamples > 0 && legacySamples > 0)
        @Assert(legacyAlloc > producedAlloc * 2)
    }
}
