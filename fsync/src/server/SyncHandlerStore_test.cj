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
package fountain::fsync.server

import std.collection.ArrayList
import std.fs.{exists, remove}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_protocol.default.*
import fountain::f_store.Store
import fountain::fsync.base.{HostAndPort, SyncData, KeyData, ValueData}

@Test
class SyncHandlerStoreTest {
    @TestCase
    func registerWritesToStore(): Unit {
        let dir = '/tmp/fsync_test/register'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let key = '/app/config/db/host'
        let value = [104u8, 101u8, 108u8, 108u8, 111u8]
        let msg = Message(Command.REGISTER, SyncData(key, 0, value).toData())
        let resp = handler.handle(msg)
        let isResp = match (resp.command) { case RESP(_) => true case _ => false }
        @Assert(isResp)
        var stored = store.get(key.unsafeBytes())
        if (let Some(s) <- stored) {
            @Assert(s.size == value.size)
        } else {
            @Assert(false)
        }
        store.close()
        cleanup(dir)
    }

    @TestCase
    func pingReturnsPing(): Unit {
        let dir = '/tmp/fsync_test/ping'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let msg = Message(Command.PING(1))
        let resp = handler.handle(msg)
        let isPing = match (resp.command) { case PING(_) => true case _ => false }
        @Assert(isPing)
        store.close()
        cleanup(dir)
    }

    @TestCase
    func invalidPayloadReturnsError(): Unit {
        let dir = '/tmp/fsync_test/invalid'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let msg = Message(Command.REGISTER)
        let resp = handler.handle(msg)
        let isResp = match (resp.command) { case RESP(_) => true case _ => false }
        @Assert(isResp)
        store.close()
        cleanup(dir)
    }

    private static func cleanup(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
}
