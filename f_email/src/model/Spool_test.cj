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
package fountain::f_email.model

import std.fs.{Directory, Path, exists, removeIfExists}
import std.process.executeWithOutput
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Spool_test {
    @TestCase
    public func createsFileWithOwnerOnlyPermission(): Unit {
        let dir = Path("/tmp/f_email_spool_test")
        try {
            Directory.create(dir, recursive: true)
        } catch (_: Exception) {}
        let path = Spool.createFile(spoolDir: dir)
        @Assert(exists(path), true)
        let (code, out, _) = executeWithOutput("stat", ["-c", "%a", path.toString()])
        @Assert(code, 0)
        @Assert(String.fromUtf8(out).trimAscii(), "600")
        removeIfExists(path)
    }

    @TestCase
    public func tempNameDoesNotUseAttachmentName(): Unit {
        let dir = Path("/tmp/f_email_spool_test")
        try {
            Directory.create(dir, recursive: true)
        } catch (_: Exception) {}
        let path = Spool.createFile(spoolDir: dir)
        @Assert(path.toString().contains("passwd"), false)
        @Assert(path.toString().contains("_f_email_"), true)
        removeIfExists(path)
    }
}
