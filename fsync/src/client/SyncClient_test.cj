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
import fountain::fsync.exception.InvalidKeyException

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

    @TestCase
    func getRejectsRelativePath(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        try {
            let _ = client.getBytes('relative/path')
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func getGenericRejectsRelativePath(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        try {
            let _: ?Array<Byte> = client.get<Array<Byte>>('relative/path')
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func addRejectsRelativePath(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        try {
            client.add<Array<Byte>>('relative/path', [1u8])
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func deleteRejectsRelativePath(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        try {
            client.delete('relative/path')
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func prefixRejectsRelativePath(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        try {
            client.prefix('relative/path')
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func watchRejectsRelativePath(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        try {
            let _: ?Array<Byte> = client.watch<Array<Byte>>('relative/path', timeout: Duration.millisecond * 10)
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func unwatchRejectsRelativePath(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        try {
            client.unwatch('relative/path')
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func absolutePathAccepted(): Unit {
        Config.set([('sync_hosts', '127.0.0.1:1203')], ifAbsent: false)
        let client = SyncClient()
        // 调用 getBytes 验证不抛 InvalidKeyException（连接失败会抛其他异常）
        try {
            client.getBytes('/valid/path')
        } catch (e: InvalidKeyException) {
            @Assert(false)
        } catch (_: Exception) {
            // 连接失败是正常行为，不在此测试范围内
            @Assert(true)
        }
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
