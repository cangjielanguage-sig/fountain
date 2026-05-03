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

import std.sync.{AtomicBool, AtomicInt64}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fsync.server.WatchManager

@Test
class WatchManagerTest {
    @TestCase
    func registerAndNotifyExact(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/app/config/db/host', [42u8])
        sleep(Duration.millisecond * 10)
        @Assert(flag.load())
    }

    @TestCase
    func exactKeyNotNotifiedOnDifferentKey(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/app/config/cache/size', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func prefixMatchNotifies(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerPrefix('/app/config/', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(flag.load())
    }

    @TestCase
    func prefixNotMatchIfNotStartWith(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerPrefix('/app/config/', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/other/key', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func unwatchRemovesExactWatcher(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        wm.unwatch('/app/config/db/host')
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func timeoutExpiresWatcher(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.millisecond * 10, {_ => flag.store(true)})
        sleep(Duration.millisecond * 50)
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func multipleWatchersOnSameKeyAllNotified(): Unit {
        let wm = WatchManager()
        let c = AtomicInt64(0)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => c.fetchAdd(1)})
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => c.fetchAdd(1)})
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(c.load() == 2)
    }
}
