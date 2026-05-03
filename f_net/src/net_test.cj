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
package fountain::f_net

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class MessageFutureTest {
    @TestCase
    public func getReturnsSetValue(): Unit {
        var fut = MessageFuture<Int64>()
        fut.set(42)
        @Assert(fut.get() == 42)
    }

    @TestCase
    public func tryGetReturnsNoneWhenNotSet(): Unit {
        let fut = MessageFuture<Int64>()
        @Assert(fut.tryGet().isNone())
    }

    @TestCase
    public func tryGetReturnsSomeWhenSet(): Unit {
        var fut = MessageFuture<Int64>()
        fut.set(99)
        if (let Some(v) <- fut.tryGet()) {
            @Assert(v == 99)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    public func tryGetWithTimeoutReturnsNoneOnTimeout(): Unit {
        let fut = MessageFuture<Int64>()
        @Assert(fut.tryGet(Duration.millisecond).isNone())
    }
}

@Test
public class SocketParamsTest {
    @TestCase
    public func builderPatternChaining(): Unit {
        let _ = SocketParams()
            .bindToDevice(None)
        @Assert(true)
    }
}
