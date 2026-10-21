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
package fountain::f_protocol.default

import std.unittest.*
import std.unittest.testmacro.*

/**
 * `Message.unsubscribe<T>(data!: T)`（带载荷、自动生成 `MessageID`）的用例。
 *
 * 需求方：`f_dbd` 关闭游标时需要"自动生成新 `MessageID` 并携带 `QueryResultClosePayload`"的
 * `UNSUBSCRIBE`（`f_dbd/doc/详细设计.md` §3.6.1、§5.9）；既有 `unsubscribe(id)` /
 * `unsubscribe(id, data!)` 的行为不得改变（f_rpc 等既有调用方无感）。
 */
@Test
public class MessageUnsubscribeTest {

    /** 与 `subscribe<T>(data!: T)` 同构：自动生成 `MessageID`，载荷由 `data.toData()` 产生。 */
    @TestCase
    public func unsubscribeWithDataCarriesPayload(): Unit {
        let payload = DataAny(DataString('qid-1'))
        let m = Message.unsubscribe(data: payload)
        @Assert(m.command.value == Command.UNSUBSCRIBE.value)
        @Assert(m.data.toString() == payload.toData().toString())
    }

    /** 自动生成的 `MessageID`：与手工构造的 `MessageID()` 同构（字段齐备、可 `toString()`、非空）。 */
    @TestCase
    public func unsubscribeWithDataGeneratesMessageId(): Unit {
        let payload = DataAny(DataString('qid-1'))
        let m = Message.unsubscribe(data: payload)
        let manual = MessageID()
        @Assert(m.id.toString().size > 0)
        @Assert(m.id.toString().size == manual.toString().size)
        @Assert(m.id.pid == manual.pid)
        @Assert(m.id.hostId == manual.hostId)
    }

    /** 连续两次调用：id 不同、data 相同。 */
    @TestCase
    public func unsubscribeWithDataTwiceYieldsDifferentIds(): Unit {
        let payload = DataAny(DataString('qid-1'))
        let a = Message.unsubscribe(data: payload)
        let b = Message.unsubscribe(data: payload)
        @Assert(a.id != b.id)
        @Assert(a.data.toString() == b.data.toString())
    }

    /** 与 `subscribe` 同构：data 相同、仅 command 不同。 */
    @TestCase
    public func unsubscribeWithDataMirrorsSubscribe(): Unit {
        let payload = DataAny(DataString('topic1'))
        let s = Message.subscribe(data: payload)
        let u = Message.unsubscribe(data: payload)
        @Assert(s.data.toString() == u.data.toString())
        @Assert(s.command.value == Command.SUBSCRIBE.value)
        @Assert(u.command.value == Command.UNSUBSCRIBE.value)
    }

    // ========== 既有重载语义不变（回归） ==========

    /** `unsubscribe(id, data!)`：仍使用传入的 id 并携带载荷。 */
    @TestCase
    public func unsubscribeWithExplicitIdKeepsId(): Unit {
        let id = MessageID()
        let payload = DataAny(DataString('topic1'))
        let m = Message.unsubscribe(id, data: payload)
        @Assert(m.id == id)
        @Assert(m.data.toString() == payload.toData().toString())
        @Assert(m.command.value == Command.UNSUBSCRIBE.value)
    }

    /** `unsubscribe(id)`：使用传入的 id、不携带载荷（`DataNone`）。 */
    @TestCase
    public func unsubscribeWithIdOnlyHasNoPayload(): Unit {
        let id = MessageID()
        let m = Message.unsubscribe(id)
        @Assert(m.id == id)
        @Assert(m.data is DataNone)
        @Assert(m.command.value == Command.UNSUBSCRIBE.value)
    }

    /** 三个重载共存且解析无歧义：`(MessageID)` / `(MessageID, data!)` / `(data!)` 各走各的。 */
    @TestCase
    public func threeOverloadsResolveUnambiguously(): Unit {
        let id = MessageID()
        let payload = DataAny(DataString('topic1'))
        let byId = Message.unsubscribe(id)
        let byIdAndData = Message.unsubscribe(id, data: payload)
        let byData = Message.unsubscribe(data: payload)
        @Assert(byId.id == id)
        @Assert(byId.data is DataNone)
        @Assert(byIdAndData.id == id)
        @Assert(byIdAndData.data.toString() == payload.toData().toString())
        @Assert(byData.id != id)
        @Assert(byData.data.toString() == payload.toData().toString())
        @Assert(byData.command.value == Command.UNSUBSCRIBE.value)
    }
}
