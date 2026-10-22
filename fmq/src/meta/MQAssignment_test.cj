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
package fountain::fmq.meta

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MQAssignmentTest {
    @TestCase
    public func specExampleIsReproduced(): Unit {
        let t1 = MQAssignment.allocate("/topic1", 4, 3, 0)
        @Assert(t1.owners == [0, 1, 2, 0])
        @Assert(t1.startNodeIndex == 0)
        @Assert(MQAssignment.nextStart(0, 4, 3) == 1)
        let t2 = MQAssignment.allocate("/topic2", 2, 3, 1)
        @Assert(t2.owners == [1, 2])
    }

    @TestCase
    public func singleNodeGetsEverything(): Unit {
        let assignment = MQAssignment.allocate("/t", 3, 1, 0)
        @Assert(assignment.owners == [0, 0, 0])
        @Assert(MQAssignment.nextStart(0, 3, 1) == 0)
    }

    @TestCase
    public func singleQueueWrapsAround(): Unit {
        let assignment = MQAssignment.allocate("/t", 1, 3, 2)
        @Assert(assignment.owners == [2])
        @Assert(MQAssignment.nextStart(2, 1, 3) == 0)
    }

    @TestCase
    public func invalidQueueCountThrows(): Unit {
        var threw = false
        try {
            MQAssignment.allocate("/t", 0, 3, 0)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        @Assert(threw)
    }

    @TestCase
    public func ownerLookupMatchesQueueIndex(): Unit {
        let assignment = MQAssignment.allocate("/t", 4, 3, 0)
        @Assert(assignment.owner(0) == Some(0))
        @Assert(assignment.owner(1) == Some(1))
        @Assert(assignment.owner(2) == Some(2))
        @Assert(assignment.owner(3) == Some(0))
        @Assert(assignment.owner(4).isNone())
    }
    @TestCase
    public func allocateKeepsDelaying(): Unit {
        let assignment = MQAssignment.allocate("/d", 2, 3, 0, delayingMs: 61000)
        @Assert(assignment.delayingMs == 61000)
        @Assert(assignment.owners == [0, 1])
    }
}