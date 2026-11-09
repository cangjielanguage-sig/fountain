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
import std.sync.AtomicBool
import fountain::f_config.Config
import fountain::f_probe.AlarmMessageChannel
import fountain::fprobe.alarm.{AlarmEngine, AlarmEvent, AlarmRule}
import fountain::fprobe.channel.{ChannelDispatcher, EmailAlarmChannel, FEmailTransport}
import fountain::fprobe.collect.SystemClock
import fountain::fprobe.config.SupervisorSettings
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

/**
 * supervisor 的运行时装配。
 *
 * 把节点拉取、告警评估、历史记录、渲染与退出串起来；TUI 是否初始化由
 * `resident` 决定，resident 模式下完全不触碰终端。
 *
 * 与 `AgentRuntime` 一样，装配逻辑只做接线，采集/告警/渲染的语义都在各自
 * 模块里（且已有用例覆盖）。
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

        let dispatcher = SupervisorRuntime.buildDispatcher()
        this.dispatcher = dispatcher

        let alarm = AlarmEngine(AlarmRule.load(), SystemClock(), {event => dispatcher.dispatch(event.message)},
            cooldownMs: SupervisorRuntime.cooldownSeconds() * 1000,
            recoverNotify: SupervisorRuntime.recoverNotify(),
            missingThreshold: settings.missingThreshold)

        this.poll = PollLoop(sources.toArray(), stateStore, SystemClock(), settings.pollIntervalMs,
            settings.missingThreshold,
            {event => SupervisorRuntime.onNodeEvent(event, dispatcher)},
            {states =>
                alarm.evaluate(states)
                SupervisorRuntime.recordHistoryOf(historyStore, states)
            })

        if (resident) {
            this.render = None<RenderLoop>
        } else {
            this.render = Some(RenderLoop(stateStore, {=> SupervisorRuntime.viewOf(holder, stateStore)},
                historyStore, painter, 500, SystemClock(), {=> []}))
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

    /** 周期评估时记录关键指标，供 TUI 画 Sparkline。 */
    private static func recordHistoryOf(history: NodeHistoryStore, states: Array<NodeState>): Unit {
        for (state in states) {
            match (state.snapshot) {
                case Some(snapshot) =>
                    for (agent in snapshot.agents) {
                        if (!agent.error.isEmpty()) {
                            continue
                        }
                        SupervisorRuntime.recordMetric(history, state.node, agent.kind, agent.dataJson)
                    }
                case None => ()
            }
        }
    }

    private static func recordMetric(history: NodeHistoryStore, node: String, kind: String, json: String): Unit {
        let value = match (MetricExtractor.primary(kind, json)) {
            case Some(found) => found
            case None => return
        }
        history.record(node, kind, value)
    }

    private static func viewOf(holder: AppHolder, store: NodeStateStore): ViewModel {
        match (holder.app) {
            case Some(app) => app.view()
            case None => ViewModel(SupervisorRuntime.nodesOf(store), 0, 0, 0)
        }
    }

    private static func nodesOf(store: NodeStateStore): Array<String> {
        let names = ArrayList<String>()
        for (state in store.all()) {
            names.add(state.node)
        }
        names.toArray()
    }

    private static func onNodeEvent(event: NodeEvent, dispatcher: ChannelDispatcher): Unit {
        dispatcher.dispatch(event.message)
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
     * 按 `probe_alarmChannels` 构建分发器。
     *
     * 只有配置齐全的渠道才会被启用；未配置 SMTP 时邮件渠道不构建，
     * 告警仍写入日志（`ChannelDispatcher.dispatch` 本身会记录）。
     */
    static func buildDispatcher(): ChannelDispatcher {
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
            var existed = false
            for ((channelName, _) in channels) {
                if (channelName == trimmed) {
                    existed = true
                }
            }
            if (existed) {
                enabled.add(trimmed)
            } else {
                eprintln('fprobe supervisor: 告警渠道 "${trimmed}" 未配置，已跳过')
            }
        }
        ChannelDispatcher(channels.toArray(), enabled.toArray(),
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
