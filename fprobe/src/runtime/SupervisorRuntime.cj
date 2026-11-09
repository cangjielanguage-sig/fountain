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
package fountain::fprobe.runtime

import std.collection.ArrayList
import std.sync.{AtomicBool, Mutex}
import fountain::f_config.Config
import fountain::f_data.{DataObject, JsonValue}
import fountain::f_probe.{AlarmChannelRegistry, AlarmMessageChannel}
import fountain::fprobe.alarm.{AlarmEngine, AlarmEvent, AlarmRule}
import fountain::fprobe.channel.{ChannelDispatcher, ChannelMessage, EmailAlarmChannel, FEmailTransport}
import fountain::fprobe.collect.SystemClock
import fountain::fprobe.collect.topology.TopologySample
import fountain::fprobe.config.SupervisorSettings
import fountain::fprobe.llm.{ActionWhitelist, FLlmClient, LlmAdvice, LlmTrigger, ProbeAdvisor, ReplyDecision,
    ReplyMonitor, ReplyStateStore, WhitelistResult}
import fountain::fprobe.report.{AttachmentStore, ChannelReportSender, ChartRenderer, ChartSelector, ReportBuilder,
    ReportJob, TicktockJobScheduler}
import fountain::fprobe.rpc.{NodeEndpoint, NodeRpcTransport}
import fountain::fprobe.snapshot.ProbeSnapshot
import fountain::fprobe.supervisor.{NodeEvent, NodeSource, NodeState, NodeStateStore, PollLoop}
import fountain::fprobe.tui.{NodeHistoryStore, Painter, RenderLoop, SupervisorApp, SupervisorComponents, ViewModel}

/** 单节点的 RPC 拉取源；每次 `collect` 复用同一条连接。 */
class TransportSource <: NodeSource {
    private let endpoint: NodeEndpoint
    private let transport: NodeRpcTransport

    init(endpoint: NodeEndpoint, timeoutMs: Int64) {
        this.endpoint = endpoint
        this.transport = NodeRpcTransport(endpoint, timeoutMs)
    }

    public prop name: String {
        get() {
            endpoint.name
        }
    }

    public func collect(): ProbeSnapshot {
        transport.collect()
    }

    func close(): Unit {
        transport.close()
    }
}

/** 延迟绑定，解决「告警回调需要 advisor、advisor 构造又依赖 dispatcher」的构造环。 */
private class AdvisorRef {
    var value: ?ProbeAdvisor = None
}

/** LLM 装配结果；关闭时两者都是 `None`。 */
private class AdvisorParts {
    let advisor: ?ProbeAdvisor
    let replies: ?ReplyMonitor
    let intervalMs: Int64
    let replyPollMs: Int64

    public init(advisor: ?ProbeAdvisor, replies: ?ReplyMonitor, intervalMs: Int64, replyPollMs: Int64) {
        this.advisor = advisor
        this.replies = replies
        this.intervalMs = intervalMs
        this.replyPollMs = replyPollMs
    }
}

/**
 * supervisor 的运行时装配。
 *
 * 把节点拉取、告警评估、历史记录、渲染、周期报告与可选 LLM 智能体串起来；
 * TUI 是否初始化由 `resident` 决定，resident 模式下完全不触碰终端。
 *
 * 装配逻辑只做接线：采集、告警、渲染、报告的语义都在各自模块里并有单测覆盖。
 */
public class SupervisorRuntime <: SupervisorComponents {
    private let settings: SupervisorSettings
    private let resident: Bool
    private let store = NodeStateStore()
    private let history: NodeHistoryStore
    private let sources: Array<TransportSource>
    private let poll: PollLoop
    private let render: ?RenderLoop
    private let dispatcher: ChannelDispatcher
    private let events: ArrayList<AlarmEvent>
    private let eventLock: Mutex
    private let advisor: ?ProbeAdvisor
    private let replies: ?ReplyMonitor
    private let llmIntervalMs: Int64
    private let replyPollMs: Int64
    private let running = AtomicBool(false)

    init(settings: SupervisorSettings, resident: Bool, painter: Painter, holder: AppHolder) {
        this.settings = settings
        this.resident = resident
        let stateStore = NodeStateStore()
        let historyStore = NodeHistoryStore(settings.historyPoints)
        this.history = historyStore

        let transports = ArrayList<TransportSource>()
        let sources = ArrayList<NodeSource>()
        for (node in settings.nodes) {
            let source = TransportSource(node, settings.nodeTimeoutMs)
            transports.add(source)
            sources.add(source)
        }
        this.sources = transports.toArray()

        let (channels, enabled) = SupervisorRuntime.buildChannels()
        let dispatcher = ChannelDispatcher(channels, enabled,
            logWarning: {message => eprintln(message)}, logError: {message => eprintln(message)})
        this.dispatcher = dispatcher

        let eventList = ArrayList<AlarmEvent>()
        let eventMutex = Mutex()
        this.events = eventList
        this.eventLock = eventMutex

        let advisorRef = AdvisorRef()
        let alarm = AlarmEngine(AlarmRule.load(), SystemClock(),
            {event =>
                synchronized(eventMutex) {
                    eventList.add(event)
                    while (eventList.size > 50) {
                        eventList.remove(0..1)
                    }
                }
                dispatcher.dispatch(event.format())
                match (advisorRef.value) {
                    case Some(advisor) =>
                        spawn {=> advisor.analyzeAlarm(event, stateStore.all(), historyStore)}
                    case None => ()
                }
            },
            cooldownMs: SupervisorRuntime.cooldownSeconds() * 1000,
            recoverNotify: SupervisorRuntime.recoverNotify(),
            missingThreshold: settings.missingThreshold,
            expectKinds: Config.getStringArray("probe_expectKinds"))

        this.poll = PollLoop(sources.toArray(), stateStore, SystemClock(), settings.pollIntervalMs,
            settings.missingThreshold,
            {event => SupervisorRuntime.onNodeEvent(event)},
            {states =>
                alarm.evaluate(states)
                for (state in states) {
                    match (state.snapshot) {
                        case Some(snapshot) => historyStore.observe(state.node, snapshot.agents)
                        case None => ()
                    }
                }
            })

        let reportJob = SupervisorRuntime.buildReportJob(dispatcher, stateStore, historyStore, eventMutex,
            eventList)
        match (reportJob) {
            case Some(job) => job.register()
            case None => ()
        }

        let llm = SupervisorRuntime.buildAdvisor(channels, dispatcher, alarm, reportJob)
        advisorRef.value = llm.advisor
        this.advisor = llm.advisor
        this.replies = llm.replies
        this.llmIntervalMs = llm.intervalMs
        this.replyPollMs = llm.replyPollMs

        if (resident) {
            this.render = None<RenderLoop>
        } else {
            this.render = Some(RenderLoop(stateStore,
                {=> SupervisorRuntime.viewOf(holder, stateStore, eventMutex, eventList)},
                historyStore, painter, 500, SystemClock(),
                {=> SupervisorRuntime.alarmTexts(eventMutex, eventList)}))
        }
    }

    public func start(): Unit {
        if (running.load()) {
            return
        }
        running.store(true)
        spawn {=> poll.run()}
        match (render) {
            case Some(loop) => spawn {=> loop.run()}
            case None => ()
        }
        match ((advisor, replies)) {
            case (Some(activeAdvisor), Some(monitor)) =>
                spawn {=>
                    SupervisorRuntime.llmLoop(running, activeAdvisor, monitor, store, history,
                        eventLock, events, llmIntervalMs, replyPollMs)
                }
            case _ => ()
        }
    }

    public func stop(): Unit {
        running.store(false)
        poll.stop()
        match (render) {
            case Some(loop) => loop.stop()
            case None => ()
        }
    }

    public func close(): Unit {
        for (source in sources) {
            source.close()
        }
    }

    /** LLM 周期分析与回复轮询共用一个后台线程，按各自间隔触发。 */
    private static func llmLoop(running: AtomicBool, advisor: ProbeAdvisor, replies: ReplyMonitor,
        store: NodeStateStore, history: NodeHistoryStore, eventLock: Mutex, events: ArrayList<AlarmEvent>,
        intervalMs: Int64, replyMs: Int64): Unit {
        let clock = SystemClock()
        var sinceLlm: Int64 = 0
        var sinceReply: Int64 = 0
        while (running.load()) {
            clock.wait(1000)
            sinceLlm += 1000
            sinceReply += 1000
            if (sinceReply >= replyMs) {
                sinceReply = 0
                try {
                    replies.pollOnce()
                } catch (e: Exception) {
                    eprintln("fprobe supervisor: 回复轮询失败: ${e.message}")
                } catch (e: Error) {
                    eprintln("fprobe supervisor: 回复轮询失败: ${e.message}")
                }
            }
            if (sinceLlm >= intervalMs) {
                sinceLlm = 0
                let batch = SupervisorRuntime.snapshotEvents(eventLock, events)
                spawn {=> advisor.analyzeInterval(store.all(), history, events: batch)}
            }
        }
    }

    private static func viewOf(holder: AppHolder, store: NodeStateStore, lock: Mutex,
        events: ArrayList<AlarmEvent>): ViewModel {
        let base = match (holder.app) {
            case Some(app) => app.view()
            case None => ViewModel.empty()
        }
        let count = synchronized(lock) {
            Int64(events.size)
        }
        base.withNodes(SupervisorRuntime.nodesOf(store)).withAlarmCount(count)
    }

    private static func alarmTexts(lock: Mutex, events: ArrayList<AlarmEvent>): Array<String> {
        synchronized(lock) {
            let texts = ArrayList<String>()
            for (event in events) {
                texts.add(event.message)
            }
            texts.toArray()
        }
    }

    private static func nodesOf(store: NodeStateStore): Array<String> {
        let names = ArrayList<String>()
        for (state in store.all()) {
            names.add(state.node)
        }
        names.toArray()
    }

    /**
     * 节点事件只写日志。
     *
     * 不可达与恢复的对外告警由 `AlarmEngine` 统一发送，避免同一事件被
     * `PollLoop` 与告警引擎重复通知。
     */
    private static func onNodeEvent(event: NodeEvent): Unit {
        eprintln('[node] ${event.message}')
    }

    /**
     * 构建周期报告；`probe_reportCron` 为空时返回 `None`。
     *
     * `register()` 在构造期调用，非法 CRON 会让进程以非 0 退出，而不是静默不注册。
     */
    private static func buildReportJob(dispatcher: ChannelDispatcher, store: NodeStateStore,
        history: NodeHistoryStore, lock: Mutex, events: ArrayList<AlarmEvent>): ?ReportJob {
        let cron = (Config.getString("probe_reportCron") ?? "").trimAscii()
        if (cron.isEmpty()) {
            return None<ReportJob>
        }
        let receivers = Config.getStringArray("probe_reportReceivers")
        let builder = ReportBuilder(ChartSelector(), ChartRenderer(),
            AttachmentStore(Config.getString("probe_reportTmpDir") ?? "./data/fprobe-report"), SystemClock())
        Some(ReportJob(
            {=>
                builder.build(store.all(), history, SupervisorRuntime.snapshotEvents(lock, events),
                    SupervisorRuntime.topologyOf(store))
            },
            ChannelReportSender(dispatcher), TicktockJobScheduler(), cron, receivers: receivers))
    }

    private static func snapshotEvents(lock: Mutex, events: ArrayList<AlarmEvent>): Array<AlarmEvent> {
        synchronized(lock) {
            events.toArray()
        }
    }

    private static func topologyOf(store: NodeStateStore): ?TopologySample {
        for (state in store.all()) {
            match (state.snapshot) {
                case Some(snapshot) =>
                    for (agent in snapshot.agents) {
                        if (agent.kind != "topology" || !agent.error.isEmpty()) {
                            continue
                        }
                        let parsed = try {
                            JsonValue.fromStr(agent.dataJson)
                        } catch (_: Exception) {
                            continue
                        }
                        match (DataObject<TopologySample>.populate(parsed.toData())) {
                            case Some(value) => return Some(value)
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        None<TopologySample>
    }

    private static func buildAdvisor(channels: Array<(String, AlarmMessageChannel)>,
        dispatcher: ChannelDispatcher, alarm: AlarmEngine, reportJob: ?ReportJob): AdvisorParts {
        let intervalMs = Config.getValue<Int64>("probe_llmIntervalMs") ?? 300000
        let replyPollMs = Config.getValue<Int64>("probe_llmReplyPollMs") ?? 30000
        let enabled = Config.getValue<Bool>("probe_llmAgent") ?? false
        if (!enabled) {
            return AdvisorParts(None<ProbeAdvisor>, None<ReplyMonitor>, intervalMs, replyPollMs)
        }
        let trigger = LlmTrigger.parse(Config.getString("probe_llmTrigger") ?? "alarm")
        let model = Config.getString("probe_llmName") ?? "deepseek-flash"
        let muteSeconds = Config.getValue<Int64>("probe_llmMuteSeconds") ?? 600
        let stateFile = Config.getString("probe_replyStateFile") ?? "./data/reply-state.json"

        let whitelist = ActionWhitelist(
            ack: {rule => eprintln('fprobe supervisor: 已确认告警 ${rule}')},
            mute: {rule: String, until: Int64 => alarm.mute(rule, until)},
            report: {=>
                match (reportJob) {
                    case Some(job) => job.runOnce()
                    case None => eprintln("fprobe supervisor: 未配置 probe_reportCron，无法立即生成报告")
                }
            },
            nowMs: {=> SystemClock().nowMs()},
            muteSeconds: muteSeconds)

        let advisor = ProbeAdvisor(true, trigger, FLlmClient(model),
            onAdvice: {advice => dispatcher.dispatch(SupervisorRuntime.formatAdvice(advice))},
            historyPoints: 20)

        let monitor = ReplyMonitor(channels, ReplyStateStore(stateFile),
            {message => SupervisorRuntime.handleReply(message, whitelist)},
            logWarning: {message => eprintln(message)}, logError: {message => eprintln(message)})

        AdvisorParts(Some(advisor), Some(monitor), intervalMs, replyPollMs)
    }

    /** 建议消息：摘要 + 问题 + 建议 + 回复格式说明。 */
    static func formatAdvice(advice: LlmAdvice): String {
        var text = "【智能体建议】${advice.summary}"
        if (!advice.problems.isEmpty()) {
            text += "\n问题:"
            for (problem in advice.problems) {
                text += "\n- ${problem}"
            }
        }
        if (!advice.solutions.isEmpty()) {
            text += "\n建议:"
            for (solution in advice.solutions) {
                text += "\n- [${solution.action}] ${solution.title}（风险: ${solution.risk}）"
            }
        }
        text += "\n回复格式：同意 <action> <rule> / 拒绝 <action> <rule>；只有白名单动作会被执行。"
        text
    }

    /** 解析授权回复：`同意 mute cpu-high` / `拒绝 mute cpu-high`。 */
    static func handleReply(message: ChannelMessage, whitelist: ActionWhitelist): Unit {
        let words = ArrayList<String>()
        for (word in message.body.trimAscii().split(" ")) {
            let trimmed = word.trimAscii()
            if (!trimmed.isEmpty()) {
                words.add(trimmed)
            }
        }
        if (words.isEmpty()) {
            eprintln("fprobe supervisor: 忽略空回复 ${message.id}")
            return
        }
        let decision = match (words[0]) {
            case "同意" => ReplyDecision.APPROVE
            case "拒绝" => ReplyDecision.REJECT
            case _ =>
                eprintln('fprobe supervisor: 无法识别的回复 "${words[0]}"（${message.id}）')
                return
        }
        let action = if (words.size > 1) {
            words[1]
        } else {
            "none"
        }
        let rule = if (words.size > 2) {
            words[2]
        } else {
            ""
        }
        let result = whitelist.apply(decision, action, rule)
        eprintln('fprobe supervisor: 回复 ${message.id} 处理结果 ${resultName(result)}')
    }

    private static func resultName(result: WhitelistResult): String {
        match (result) {
            case ACKED => "ACKED"
            case MUTED => "MUTED"
            case REPORTED => "REPORTED"
            case NONE => "NONE"
            case REJECTED => "REJECTED"
            case UNSUPPORTED => "UNSUPPORTED"
        }
    }

    private static func cooldownSeconds(): Int64 {
        match (Config.getValue<Int64>("probe_alarmCooldownSeconds")) {
            case Some(value) => if (value < 0) {
                0
            } else {
                value
            }
            case None => 300
        }
    }

    private static func recoverNotify(): Bool {
        match (Config.getValue<Bool>("probe_alarmRecoverNotify")) {
            case Some(value) => value
            case None => true
        }
    }

    /**
     * 按 `probe_alarmChannels` 构建渠道表与启用列表。
     *
     * 未注册的渠道名会原样交给 `ChannelDispatcher`，由它在构造期抛 `CONFIG`，
     * 保证配置错误在启动时暴露，而不是运行期静默跳过。
     */
    static func buildChannels(): (Array<(String, AlarmMessageChannel)>, Array<String>) {
        let channels = ArrayList<(String, AlarmMessageChannel)>()
        match (buildEmailChannel()) {
            case Some(channel) => channels.add(("email", channel))
            case None => ()
        }
        let requested = Config.getStringArray("probe_alarmChannels")
        let names = if (requested.isEmpty()) {
            ["email"]
        } else {
            requested
        }
        let enabled = ArrayList<String>()
        for (name in names) {
            let trimmed = name.trimAscii()
            if (trimmed.isEmpty()) {
                continue
            }
            var built = false
            for ((channelName, _) in channels) {
                if (channelName == trimmed) {
                    built = true
                }
            }
            if (built) {
                enabled.add(trimmed)
                continue
            }
            let known = trimmed == "email" || AlarmChannelRegistry.channel(trimmed).isSome()
            if (known) {
                eprintln('fprobe supervisor: 渠道 "${trimmed}" 已注册但未配置，已跳过')
            } else {
                enabled.add(trimmed)
            }
        }
        (channels.toArray(), enabled.toArray())
    }

    /** 兼容旧调用：只要分发器。 */
    static func buildDispatcher(): ChannelDispatcher {
        let (channels, enabled) = buildChannels()
        ChannelDispatcher(channels, enabled,
            logWarning: {message => eprintln(message)}, logError: {message => eprintln(message)})
    }

    private static func buildEmailChannel(): ?EmailAlarmChannel {
        match (Config.getString("probe_channel_email_smtpHost")) {
            case Some(raw) =>
                if (raw.trimAscii().isEmpty()) {
                    return None<EmailAlarmChannel>
                }
            case None => return None<EmailAlarmChannel>
        }
        try {
            let sender = Config.getString("probe_channel_email_from") ?? ""
            let prefix = Config.getString("probe_channel_email_subjectPrefix") ?? "[fprobe]"
            let receivers = Config.getStringArray("probe_channel_email_receivers")
            Some(EmailAlarmChannel(FEmailTransport.fromConfig(), sender, subjectPrefix: prefix,
                defaultReceivers: receivers))
        } catch (e: Exception) {
            eprintln("fprobe supervisor: 邮件渠道初始化失败: ${e.message}")
            None<EmailAlarmChannel>
        } catch (e: Error) {
            eprintln("fprobe supervisor: 邮件渠道初始化失败: ${e.message}")
            None<EmailAlarmChannel>
        }
    }
}
