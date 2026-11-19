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
package fountain::f_zip

import std.unittest.*
import std.unittest.testmacro.*

/** 测试辅助：捕获 `ZipException` 并断言消息片段。 */
internal func captureZipError<T>(action: () -> T): Option<ZipException> {
    try {
        action()
    } catch (e: ZipException) {
        return Some(e)
    }
    None<ZipException>
}

internal func assertZipError<T>(action: () -> T, fragment: String): Unit {
    match (captureZipError(action)) {
        case Some(e) =>
            if (!e.message.contains(fragment)) {
                @Fail("异常消息不含 \"${fragment}\"，实际是 \"${e.message}\"")
            }
        case None => @Fail("没有抛出 ZipException（期望消息含 \"${fragment}\"）")
    }
}

@Test
public class F_zip_test {
    /** 骨架用例：证明 `cjpm test` 可跑、`ZipException` 的消息原样保留。 */
    @TestCase
    public func zipExceptionKeepsMessage(): Unit {
        @Assert(ZipException("x").message, "x")
    }

    @TestCase
    public func zipExceptionIsBaseException(): Unit {
        let e: Exception = ZipException("boom")
        @Assert(e.message, "boom")
    }
}
