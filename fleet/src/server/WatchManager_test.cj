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
class WatchManagerTest {
    @TestCase
    func registerAndNotifyExact(): Unit {
        let wm = WatchManager()
        let future = wm.registerExact('/app/config/db/host', Duration.Zero)
        wm.notify('/app/config/db/host', [42u8])
        sleep(Duration.millisecond * 10)
        if (let Some(v) <- future.tryGet()) {
            @Assert(v.size == 1 && v[0] == 42u8)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func exactKeyNotNotifiedOnDifferentKey(): Unit {
        let wm = WatchManager()
        let future = wm.registerExact('/app/config/db/host', Duration.Zero)
        wm.notify('/app/config/cache/size', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(future.tryGet().isNone())
    }

    @TestCase
    func prefixMatchNotifies(): Unit {
        let wm = WatchManager()
        let future = wm.registerPrefix('/app/config/', Duration.Zero)
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(future.tryGet().isSome())
    }

    @TestCase
    func prefixNotMatchIfNotStartWith(): Unit {
        let wm = WatchManager()
        let future = wm.registerPrefix('/app/config/', Duration.Zero)
        wm.notify('/other/key', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(future.tryGet().isNone())
    }

    @TestCase
    func unwatchRemovesExactWatcher(): Unit {
        let wm = WatchManager()
        let future = wm.registerExact('/app/config/db/host', Duration.Zero)
        wm.unwatch('/app/config/db/host')
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(future.tryGet().isNone())
    }

    @TestCase
    func timeoutExpiresWatcher(): Unit {
        let wm = WatchManager()
        let future = wm.registerExact('/app/config/db/host', Duration.millisecond * 10)
        sleep(Duration.millisecond * 50)
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(future.tryGet().isNone())
    }

    @TestCase
    func multipleWatchersOnSameKeyBothNotified(): Unit {
        let wm = WatchManager()
        let f1 = wm.registerExact('/app/config/db/host', Duration.Zero)
        let f2 = wm.registerExact('/app/config/db/host', Duration.Zero)
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(f1.tryGet().isSome())
        @Assert(f2.tryGet().isSome())
    }

    @TestCase
    func unwatchPrefixStopsNotification(): Unit {
        let wm = WatchManager()
        let future = wm.registerPrefix('/app/config/', Duration.Zero)
        wm.unwatchPrefix('/app/config/')
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(future.tryGet().isNone())
    }

    @TestCase
    func unwatchGlobStopsNotification(): Unit {
        let wm = WatchManager()
        let future = wm.registerGlob('/app/config/*', Duration.Zero)
        wm.unwatchGlob('/app/config/*')
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(future.tryGet().isNone())
    }

    @TestCase
    func closeStopsCleanupThread(): Unit {
        let wm = WatchManager()
        @Assert(!wm.isClosed())
        wm.close()
        @Assert(wm.isClosed())
        // close 后注册新的 watcher 仍可工作（线程退出不影响业务逻辑）
        let future = wm.registerExact('/app/key', Duration.millisecond * 10)
        sleep(Duration.millisecond * 20)
        @Assert(future.tryGet().isNone())  // 超时返回 None
        // close 后 notify 仍能通知到已注册的 watcher
        let future2 = wm.registerExact('/app/key2', Duration.Zero)
        wm.notify('/app/key2', [42u8])
        sleep(Duration.millisecond * 10)
        @Assert(future2.tryGet().isSome())
    }
}
