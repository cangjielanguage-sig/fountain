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
package fountain::fprobe.report

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

/** 15.4：附件命名、路径清洗与发送后清理。 */
@Test
public class Attachment_test {
    @TestCase
    public func fileNameUsesNodeAndMetric(): Unit {
        @Assert(AttachmentStore.fileNameFor("web1", "cpu.usagePercent"), "web1-cpu_usagePercent.svg")
    }

    @TestCase
    public func nodeNameWithSlashIsSanitized(): Unit {
        @Assert(AttachmentStore.fileNameFor("web/1", "cpu.usagePercent"), "web_1-cpu_usagePercent.svg")
        @Assert(AttachmentStore.fileNameFor("../etc", "disk.usedPercent"), ".._etc-disk_usedPercent.svg")
    }

    @TestCase
    public func writeCreatesFileAndCleanupRemovesDirectory(): Unit {
        let dir = reportTempDir()
        let store = AttachmentStore(dir)
        let attachment = store.write("web1", "cpu.usagePercent", FIXED_SVG)

        @Assert(attachment.name, "web1-cpu_usagePercent.svg")
        @Assert(exists(Path(attachment.path)))
        @Assert(String.fromUtf8(File.readFrom(Path(attachment.path))), FIXED_SVG)

        store.cleanup()
        @Assert(!exists(Path(dir)))
    }
}
