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

import std.collection.ArrayList
import std.fs.{exists, remove}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_protocol.default.*
import fountain::f_store.Store
import fountain::f_util.PathPattern
import fountain::fleet.base.{HostAndPort, SyncData, KeyData, PatternData, ScanResult}

@Test
@Configure[warmup: Duration.millisecond * 50, batchSize: 10]
public class SyncBench {
    @Bench
    public func benchRegister(): Unit {
        let dir = '/tmp/fleet_bench/register'
        if (exists(dir)) { remove(dir, recursive: true) }
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        for (k in 0..10) {
            let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/${k}/host', 0, [1u8, 2u8, 3u8]).toData()))
        }
        store.close()
        if (exists(dir)) { remove(dir, recursive: true) }
    }

    @Bench
    public func benchGet(): Unit {
        let dir = '/tmp/fleet_bench/get'
        if (exists(dir)) { remove(dir, recursive: true) }
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        for (k in 0..10) {
            let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/${k}/host', 0, [10u8, 20u8]).toData()))
        }
        for (k in 0..10) {
            let _ = handler.handle(Message(Command.ACK, KeyData('/app/config/${k}/host').toData()))
        }
        store.close()
        if (exists(dir)) { remove(dir, recursive: true) }
    }

    @Bench
    public func benchPrefixScan(): Unit {
        let dir = '/tmp/fleet_bench/prefix'
        if (exists(dir)) { remove(dir, recursive: true) }
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        for (k in 0..10) {
            let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/${k}/host', 0, [1u8]).toData()))
        }
        let _ = handler.handle(Message(Command.ACK, PatternData('/app/config/').toData()))
        store.close()
        if (exists(dir)) { remove(dir, recursive: true) }
    }

    @Bench
    public func benchGlob(): Unit {
        let dir = '/tmp/fleet_bench/glob'
        if (exists(dir)) { remove(dir, recursive: true) }
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        for (k in 0..10) {
            let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/group/${k}.yaml', 0, [1u8]).toData()))
        }
        let _ = handler.handle(Message(Command.ACK, PatternData('/app/**/*.yaml').toData()))
        store.close()
        if (exists(dir)) { remove(dir, recursive: true) }
    }

    @Bench
    public func benchPathPattern(): Unit {
        let pp = PathPattern()
        pp.compile('/app/**/*.yaml')
        for (k in 0..10) {
            let _ = pp.matches('/app/group/${k}.yaml')
        }
    }
}
