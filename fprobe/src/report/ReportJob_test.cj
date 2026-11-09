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

import std.collection.ArrayList
import std.fs.{exists, Path}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

private class FakeScheduler <: JobScheduler {
    var scheduled: Int64 = 0
    var lastName: String = ""
    var lastCron: String = ""

    public func schedule(name: String, cron: String, task: () -> Unit): Unit {
        let _ = task
        scheduled += 1
        lastName = name
        lastCron = cron
    }
}

private class FakeSender <: ReportSender {
    let messages = ArrayList<String>()
    let htmls = ArrayList<String>()
    let attachments = ArrayList<Array<String>>()
    var fail: Bool = false

    public func sendRich(message: String, html: String, files: Array<String>,
        receivers: Array<String>): Unit {
        let _ = receivers
        if (fail) {
            throw Exception("smtp down")
        }
        messages.add(message)
        htmls.add(html)
        attachments.add(files)
    }
}

private func draftWith(dir: String): ReportDraft {
    let store = AttachmentStore(dir)
    let attachment = store.write("web1", "cpu.usagePercent", FIXED_SVG)
    ReportDraft("fprobe 报告", "文本摘要", "<html>摘要</html>", [attachment], dir)
}

/** 15.5：CRON 为空不注册、非法 CRON 启动失败、runOnce 发送并清理。 */
@Test
public class ReportJob_test {
    @TestCase
    public func emptyCronDoesNotRegister(): Unit {
        let scheduler = FakeScheduler()
        let job = ReportJob({=> draftWith(reportTempDir())}, FakeSender(), scheduler,
            "   ", receivers: ["ops@example.com"])

        @Assert(!job.register())
        @Assert(scheduler.scheduled, 0)
    }

    @TestCase
    public func invalidCronFailsAtStartup(): Unit {
        let scheduler = FakeScheduler()
        let job = ReportJob({=> draftWith(reportTempDir())}, FakeSender(), scheduler,
            "bogus cron", receivers: ["ops@example.com"])
        var caught = false
        try {
            job.register()
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
            @Assert(e.message.contains("probe_reportCron"))
        }
        @Assert(caught)
        @Assert(scheduler.scheduled, 0)
    }

    @TestCase
    public func registerSchedulesCronOnce(): Unit {
        let scheduler = FakeScheduler()
        let job = ReportJob({=> draftWith(reportTempDir())}, FakeSender(), scheduler,
            "0 0 2 * * * *", receivers: ["ops@example.com"])

        @Assert(job.register())
        @Assert(scheduler.scheduled, 1)
        @Assert(scheduler.lastName, "fprobe-report")
        @Assert(scheduler.lastCron, "0 0 2 * * * *")
    }

    @TestCase
    public func runOnceSendsReportAndCleansTemporaryFiles(): Unit {
        let dir = reportTempDir()
        let sender = FakeSender()
        let job = ReportJob({=> draftWith(dir)}, sender, FakeScheduler(),
            "0 0 2 * * * *", receivers: ["ops@example.com"])

        @Assert(exists(Path(dir)))
        job.runOnce()

        @Assert(sender.messages.size, 1)
        @Assert(sender.messages[0], "文本摘要")
        @Assert(sender.htmls[0], "<html>摘要</html>")
        @Assert(sender.attachments[0].size, 1)
        @Assert(!exists(Path(dir)))
    }

    @TestCase
    public func senderFailureStillCleansTemporaryFiles(): Unit {
        let dir = reportTempDir()
        let sender = FakeSender()
        sender.fail = true
        let errors = ArrayList<String>()
        let job = ReportJob({=> draftWith(dir)}, sender, FakeScheduler(),
            "0 0 2 * * * *", receivers: ["ops@example.com"],
            logError: {message => errors.add(message)})

        job.runOnce()

        @Assert(errors.size, 1)
        @Assert(errors[0].contains("smtp down"))
        @Assert(!exists(Path(dir)))
    }
}
