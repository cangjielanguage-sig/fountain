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
package fountain::f_tui.term

import std.unittest.*
import std.unittest.testmacro.*

class FakeSizeProvider <: SizeProvider {
    public var value: Option<TuiSize> = Some(TuiSize(80, 24))
    public var reads: Int64 = 0

    public init() {}

    public func size(): Option<TuiSize> {
        reads += 1
        value
    }
}

@Test
public class TerminalSize_test {
    /** ioctl 成功时返回行列。 */
    @TestCase
    public func ioctlSuccess(): Unit {
        let ffi = FakePosixFfi()
        ffi.windowValue = Some(winSize(120, 40))
        let size = TerminalSize(IoctlSizeProvider(ffi, STDOUT_FILENO))
        let value = size.size().getOrThrow()
        @Assert(value.width, 120)
        @Assert(value.height, 40)
    }

    /** ioctl 失败返回 None，不返回随机值。 */
    @TestCase
    public func ioctlFailureReturnsNone(): Unit {
        let ffi = FakePosixFfi()
        ffi.windowValue = None
        let size = TerminalSize(IoctlSizeProvider(ffi, STDOUT_FILENO))
        @Assert(size.size().isNone())
        @Assert(size.lastKnown().isUnknown())
    }

    /** 行列任一为 0 视为未知尺寸。 */
    @TestCase
    public func zeroSizeIsUnknown(): Unit {
        let ffi = FakePosixFfi()
        ffi.windowValue = Some(winSize(0, 0))
        let size = TerminalSize(IoctlSizeProvider(ffi, STDOUT_FILENO))
        @Assert(size.size().isNone())
    }

    /** 注入 SizeProvider 的路径同样可用。 */
    @TestCase
    public func injectedProviderIsUsed(): Unit {
        let provider = FakeSizeProvider()
        provider.value = Some(TuiSize(100, 30))
        let size = TerminalSize(provider)
        @Assert(size.size().getOrThrow().width, 100)
        @Assert(size.size().getOrThrow().height, 30)
        @Assert(provider.reads, 2)
    }

    /** 窗口变化后重新读取，不沿用旧尺寸。 */
    @TestCase
    public func rereadsAfterResize(): Unit {
        let ffi = FakePosixFfi()
        ffi.windowValue = Some(winSize(80, 24))
        let size = TerminalSize(IoctlSizeProvider(ffi, STDOUT_FILENO))
        @Assert(size.size().getOrThrow().width, 80)

        ffi.windowValue = Some(winSize(132, 43))
        @Assert(size.size().getOrThrow().width, 132)
        @Assert(size.size().getOrThrow().height, 43)
        @Assert(size.lastKnown().height, 43)
    }
}
