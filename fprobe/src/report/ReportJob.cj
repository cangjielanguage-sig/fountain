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

import fountain::f_probe.{ProbeErrorCode, ProbeException}
import fountain::fprobe.channel.ChannelDispatcher
import fountain::f_ticktock.{CronCompiler, Ticktock}

/** 报告发送端口；生产实现桥接 `ChannelDispatcher`。 */
public interface ReportSender {
    func sendRich(message: String, html: String, attachments: Array<String>,
        receivers: Array<String>): Unit
}

/** 定时任务注册端口；生产实现桥接 `f_ticktock.Ticktock`。 */
public interface JobScheduler {
    func schedule(name: String, cron: String, task: () -> Unit): Unit
}

/** 把报告交给现有渠道分发器。 */
public class ChannelReportSender <: ReportSender {
    private let dispatcher: ChannelDispatcher

    public init(dispatcher: ChannelDispatcher) {
        this.dispatcher = dispatcher
    }

    public func sendRich(message: String, html: String, attachments: Array<String>,
        receivers: Array<String>): Unit {
        dispatcher.dispatchRich(message, html, attachments, receivers: receivers)
    }
}

/** 生产定时器：注册到全局 Ticktock。 */
public class TicktockJobScheduler <: JobScheduler {
    public init() {}

    public func schedule(name: String, cron: String, task: () -> Unit): Unit {
        Ticktock.instance.addOrReplaceTask(taskName: name, taskCron: cron, executor: task)
    }
}

/**
 * 周期报告任务（spec「周期报告」）。
 *
 * CRON 为空表示关闭，不注册；非法 CRON 在启动期失败而不是静默关闭。发送失败
 * 只记录 ERROR，临时附件仍会清理，下一周期继续尝试。
 */
public class ReportJob {
    public static let TASK_NAME = "fprobe-report"

    private let builder: () -> ReportDraft
    private let sender: ReportSender
    private let scheduler: JobScheduler
    private let cron: String
    private let receivers: Array<String>
    private let logError: (String) -> Unit

    public init(builder: () -> ReportDraft, sender: ReportSender, scheduler: JobScheduler,
        cron: String, receivers!: Array<String> = [],
        logError!: (String) -> Unit = {message => eprintln(message)}) {
        this.builder = builder
        this.sender = sender
        this.scheduler = scheduler
        this.cron = cron
        this.receivers = receivers
        this.logError = logError
    }

    /** 注册 CRON；空表达式返回 false，非法表达式抛 `CONFIG` 错误。 */
    public func register(): Bool {
        let expression = cron.trimAscii()
        if (expression.isEmpty()) {
            return false
        }
        try {
            CronCompiler.compile(expression)
        } catch (e: Exception) {
            throw ProbeException(ProbeErrorCode.CONFIG,
                'probe_reportCron 非法 "${expression}": ${e.message}')
        } catch (e: Error) {
            throw ProbeException(ProbeErrorCode.CONFIG,
                'probe_reportCron 非法 "${expression}": ${e.message}')
        }
        scheduler.schedule(TASK_NAME, expression, {=> runOnce()})
        true
    }

    /** 立即生成并发送一次报告；无论发送成败都清理临时附件。 */
    public func runOnce(): Unit {
        let draft = builder()
        try {
            let files = Array<String>(draft.attachments.size) {i => draft.attachments[i].path}
            sender.sendRich(draft.text, draft.html, files, receivers)
        } catch (e: Exception) {
            logError('报告发送失败: ${e.message}')
        } catch (e: Error) {
            logError('报告发送失败: ${e.message}')
        } finally {
            draft.cleanup()
        }
    }
}
