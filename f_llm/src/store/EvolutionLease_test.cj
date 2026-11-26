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
import std.fs.Directory
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_util.UUID

/** 每日租约：时间型 UUID + 同日只放行一次 */
@Test
class EvolutionLease_test {
    private static func now(): Int64 {
        DateTime.now().toUnixTimeStamp().toSeconds()
    }

    private static func newPath(): String {
        '/tmp/fllm-evo-lease-${UUID.random().toHexString()}'
    }

    /** 时间型 UUID 能解析出时间戳，且落在今天 */
    @TestCase
    func testTimeUuidParsesTimestamp(): Unit {
        let stamp = now()
        let value = TimeUuid.create()
        @Expect(TimeUuid.timestampOf(value) > 0, true)
        @Expect(TimeUuid.dayOf(value), stamp / 86400)
        // 非 UUID 文本视为「无时间」
        @Expect(TimeUuid.timestampOf('not-a-uuid'), 0)
        @Expect(TimeUuid.timestampOf(''), 0)
    }

    /** 内存实现：ensure 只写一次；同一天 acquire 失败，隔天成功 */
    @TestCase
    func testMemoryLeaseSingleWinnerPerDay(): Unit {
        let stamp = now()
        let lease = InMemoryEvolutionLease()
        @Expect(lease.current(), '')

        let created = lease.ensure(stamp)
        @Expect(created.isEmpty(), false)
        @Expect(lease.ensure(stamp), created)      // 已存在就不再变
        @Expect(TimeUuid.dayOf(created), stamp / 86400)

        @Expect(lease.acquire(stamp), '')          // 今天已被领取
        let tomorrow = lease.acquire(stamp + 86400)
        @Expect(tomorrow.isEmpty(), false)         // 隔天可领取
        @Expect(tomorrow != created, true)
    }

    /** f_store：租约持久化，重开实例仍读到同一值 */
    @TestCase
    func testFStoreLeasePersists(): Unit {
        let path = newPath()
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let stamp = now()
        let first = FStoreEvolutionLease(path)
        let created = first.ensure(stamp)
        @Expect(created.isEmpty(), false)

        let reopened = FStoreEvolutionLease(path)
        @Expect(reopened.current(), created)
        @Expect(reopened.acquire(stamp), '')       // 同一天：另一个实例也抢不到
        @Expect(reopened.acquire(stamp + 86400).isEmpty(), false)
    }
}
