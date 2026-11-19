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
package fountain::fprobe.tui

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

class FalseTtyDetector <: TtyDetector {
    public func isTty(): Bool {
        false
    }
}

class TrueTtyDetector <: TtyDetector {
    public func isTty(): Bool {
        true
    }
}

/** 12.3：非 TTY 必须报错，并把用户引向 resident 模式。 */
@Test
public class TtyDetector_test {
    @TestCase
    public func nonTtyIsRejectedWithResidentHint(): Unit {
        var caught = false
        try {
            requireTty(FalseTtyDetector())
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
            @Assert(e.message.contains("TTY"))
            @Assert(e.message.contains("resident"))
        }
        @Assert(caught)
    }

    @TestCase
    public func ttyPassesWithoutError(): Unit {
        requireTty(TrueTtyDetector())
    }
}
