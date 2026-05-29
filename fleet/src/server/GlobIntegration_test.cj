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
import fountain::fleet.base.{HostAndPort, SyncData, PatternData, ScanResult}

@Test
public class GlobIntegrationTest {
    private static let dataDir = '/tmp/fleet_int/glob'

    @TestCase
    public func globEndToEnd(): Unit {
        cleanup()
        let store = Store(dataDir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)

        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/db/host.yaml', 0, [1u8, 2u8, 3u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/cache/size.xml', 0, [4u8, 5u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/a/b/c/host.yaml', 0, [6u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/other/app/test.yaml', 0, [7u8, 8u8, 9u8, 10u8]).toData()))

        let globResp = handler.handle(Message(Command.ACK, PatternData('/app/**/*.yaml').toData()))
        @Assert(match (globResp.command) { case RESP(_) => true case _ => false })

        let pp = PathPattern()
        pp.compile('/app/**/*.yaml')
        var matched = 0i64
        for ((k, v) in store.prefix([])) {
            if (pp.matches(String.fromUtf8(k))) {
                matched++
            }
        }
        @Assert(matched == 2)
        store.close()
        cleanup()
    }

    public static func cleanup(): Unit {
        if (exists(dataDir)) {
            remove(dataDir, recursive: true)
        }
    }
}
