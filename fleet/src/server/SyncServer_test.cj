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
package fountain::fleet.server

import std.unittest.*
import std.unittest.testmacro.*

@Test
class SyncServerTest {
    private static let testPort: UInt16 = 19876

    @TestCase
    func constructAndClose(): Unit {
        let server = SyncServer(testPort)
        @Assert(!server.isClosed())
        server.close()
        @Assert(server.isClosed())
    }

    @TestCase
    func closeIsIdempotent(): Unit {
        let server = SyncServer(19877u16)
        server.close()
        server.close()
        @Assert(server.isClosed())
    }

    @TestCase
    func customQueueSize(): Unit {
        let server = SyncServer(19878u16, queueSize: 2048,
            checkDuration: Duration.second * 60)
        @Assert(!server.isClosed())
        server.close()
        @Assert(server.isClosed())
    }
}
