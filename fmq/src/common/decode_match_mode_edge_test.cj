/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.env.{setVariable, removeVariable}
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.Message as ProtocolMessage


@Test
public class DecodeMatchModeEdgeTest {
    @TestCase
    public func testDecodeMatchModeEmptyExact(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "empty", groupId: "empty",
            matchModeStr: "Exact:",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        // 空 Exact("") 不应崩溃，返回 Exact("")
        match (mode) {
            case Exact(t) => @Assert(t == "")
            case _ => @Assert(false)
        }
    }

    @TestCase
    public func testDecodeMatchModeSingleCharGlob(): Unit {
        // P2-1: "Glob:*" (6 bytes) 之前被 s.size <= 6 误判为空 Exact
        let reg = ConsumerRegistration(
            consumerId: "g1", groupId: "g1",
            matchModeStr: "Glob:*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        match (mode) {
            case Glob(p) => @Assert(p == "*")
            case _ => @Assert(false)
        }
    }

    @TestCase
    public func testDecodeMatchModeEmptyString(): Unit {
        // P2-1 边界: 空字符串 < 5 字节，返回 Exact("")
        let reg = ConsumerRegistration(
            consumerId: "e1", groupId: "e1",
            matchModeStr: "",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        match (mode) {
            case Exact(t) => @Assert(t == "")
            case _ => @Assert(false)
        }
    }

    @TestCase
    public func testDecodeMatchModeGlobEmptyPattern(): Unit {
        // P2-1 边界: "Glob:" (5 bytes) — 最短合法前缀，空 pattern
        let reg = ConsumerRegistration(
            consumerId: "g2", groupId: "g2",
            matchModeStr: "Glob:",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        match (mode) {
            case Glob(p) => @Assert(p == "")
            case _ => @Assert(false)
        }
    }

    @TestCase
    public func testDecodeMatchModeGlobSingleCharX(): Unit {
        // P2-1 边界: "Glob:x" (6 bytes) — 单字符 pattern，之前 ≤6 被误判
        let reg = ConsumerRegistration(
            consumerId: "g3", groupId: "g3",
            matchModeStr: "Glob:x",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        match (mode) {
            case Glob(p) => @Assert(p == "x")
            case _ => @Assert(false)
        }
    }

    @TestCase
    public func testDecodeMatchModeUnknownPrefix(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "unknown", groupId: "unknown",
            matchModeStr: "WTF:pattern",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        // 未知前缀降级为 Exact("WTF:pattern")，不应崩溃
        match (mode) {
            case Exact(t) => @Assert(t == "WTF:pattern")
            case _ => @Assert(false)
        }
    }
}
