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
package fountain::fsync

import std.unittest.*
import std.unittest.testmacro.*
import fountain::fsync.server.*

@Test
class SyncDataFormatTest {
    @TestCase
    func createSyncData(): Unit {
        let data = SyncData('/app/config/db/host', 42, [104u8, 101u8, 108u8, 108u8, 111u8])
        @Assert(data.key == '/app/config/db/host')
        @Assert(data.version == 42)
        @Assert(data.value.size == 5)
    }

    @TestCase
    func createValueDataWithValue(): Unit {
        let data = ValueData([104u8, 101u8])
        if (let Some(v) <- data.value) {
            @Assert(v.size == 2)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func createValueDataNone(): Unit {
        let data = ValueData(None)
        @Assert(data.value.isNone())
    }

    @TestCase
    func createPatternData(): Unit {
        let data = PatternData('/app/config/*')
        @Assert(data.pattern == '/app/config/*')
    }

    @TestCase
    func createKeyData(): Unit {
        let data = KeyData('/app/config/db/host')
        @Assert(data.key == '/app/config/db/host')
    }

    @TestCase
    func createWatchNotifyData(): Unit {
        let data = WatchNotifyData('/app/config/db/host', [1u8, 2u8])
        @Assert(data.key == '/app/config/db/host')
        if (let Some(v) <- data.value) {
            @Assert(v.size == 2)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func createWatchData(): Unit {
        let data = WatchData('/app/config/db/host', timeout: Duration.second * 30)
        @Assert(data.key == '/app/config/db/host')
    }

    @TestCase
    func watchDataDefaultTimeout(): Unit {
        let data = WatchData('/app/config/db/host')
        @Assert(data.key == '/app/config/db/host')
    }
}
