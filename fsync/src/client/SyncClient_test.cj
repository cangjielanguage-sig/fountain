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
package fountain::fsync.client

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config

@Test
class SyncClientTest {
    @TestCase
    func constructWithSingleNode(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let _ = SyncClient()
    }

    @TestCase
    func constructWithMultipleNodes(): Unit {
        Config.set([('sync_hosts', '10.0.0.1:1203,10.0.0.2:1203,10.0.0.3:1203')], ifAbsent: false)
        let _ = SyncClient()
    }
}

@Test
class SyncClientUtilTest {
    @TestCase
    func sameBytesBothNone(): Unit {
        let a: ?Array<Byte> = None
        let b: ?Array<Byte> = None
        @Assert(SyncClient.sameBytes(a, b))
    }

    @TestCase
    func sameBytesBothSomeEqual(): Unit {
        let a: ?Array<Byte> = [1u8, 2u8, 3u8]
        let b: ?Array<Byte> = [1u8, 2u8, 3u8]
        @Assert(SyncClient.sameBytes(a, b))
    }

    @TestCase
    func sameBytesDifferentSize(): Unit {
        let a: ?Array<Byte> = [1u8, 2u8]
        let b: ?Array<Byte> = [1u8, 2u8, 3u8]
        @Assert(!SyncClient.sameBytes(a, b))
    }

    @TestCase
    func sameBytesDifferentContent(): Unit {
        let a: ?Array<Byte> = [1u8, 2u8, 3u8]
        let b: ?Array<Byte> = [4u8, 5u8, 6u8]
        @Assert(!SyncClient.sameBytes(a, b))
    }

    @TestCase
    func sameBytesOneNone(): Unit {
        let a: ?Array<Byte> = [1u8]
        let b: ?Array<Byte> = None
        @Assert(!SyncClient.sameBytes(a, b))
    }
}
