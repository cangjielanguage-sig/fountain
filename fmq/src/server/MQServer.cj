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
package fountain::fmq.server

import std.collection.{ArrayList, HashSet}
import std.fs.*
import std.sync.{AtomicBool, Mutex, Timer}
import fountain::f_data.DataAny
import fountain::f_log.*
import fountain::f_net.server.Server
import fountain::f_protocol.default.Message
import fountain::fmq.cluster.{BackupReplicator, LogCleaner, MetaSyncer, NodeRegistry}
import fountain::fmq.meta.MetaStore
import fountain::fmq.metrics.MQMetrics
import fountain::fmq.queue.{CursorCatalog, CursorStore, DeadLetterQueue, MQMatcher, QueueManager}

/**
 * 服务端装配与生命周期。
 *
 * 顺序：配置校验 → 目录准备 → 元数据加载 → 节点注册 → 启动同步 → 打开本机队列
 * → 清理/备份定时器 → 监听。关闭按相反顺序释放。
 */
public class MQServer {
    private static let log = LoggerFactory.getLogger("fountain::fmq.server.MQServer")
    private static let CHECK_DURATION = Duration.second * 30
    private static let CLEANUP_INTERVAL = Duration.second * 2

    private let options: MQServerOptions
    private let meta: MetaStore
    private let registry: NodeRegistry
    private let syncer: MetaSyncer
    private let queues: QueueManager
    private let cursorStore: CursorStore
    private let cursorCatalog: CursorCatalog
    private let deadLetter: DeadLetterQueue
    private let subscribers: SubscriberRegistry
    private let consume: ConsumeService
    private let backupStore: BackupStore
    private let backup: BackupReplicator
    private let cleaner: LogCleaner
    private let executor: MQCommandExecutor
    private let server: Server<DataAny>
    private let started = AtomicBool(false)
    private let closed = AtomicBool(false)
    private var cleanupTimer: ?Timer = None
    private let closeLock = Mutex()
    private var closeCompleted = false
    private let closeDone = HashSet<String>()
    private var closeStepsOverride: ?(() -> Array<(String, () -> Unit)>) = None

    /** 从 `mqServer_*` / `mqClient_hosts` 读取配置并装配。 */
    public init() {
        this(MQServerOptions.fromConfig())
    }

    protected init(options: MQServerOptions) {
        this.options = options
        ensureDir(options.metaDir)
        ensureDir(options.segmentedLogDir)
        ensureDir(options.deadMsgDir)

        this.meta = MetaStore(options.metaDir, origin: options.selfIndex)
        this.meta.load()
        // 局部别名：闭包不能捕获尚未完成初始化的 `this`，只能捕获局部变量
        let metaStore = this.meta
        this.registry = NodeRegistry(options.nodes, options.selfIndex)
        this.syncer = MetaSyncer(meta, registry)
        // 先向 peer 补齐元数据，再按最终分配打开本机队列
        syncer.syncFromPeers()

        this.queues = QueueManager(options.segmentedLogDir, options.segmentedLogMaxSize, 1)
        for (assignment in meta.topics()) {
            queues.openTopic(assignment, options.selfIndex)
        }
        this.cursorStore = CursorStore(options.metaDir)
        this.cursorCatalog = CursorCatalog(cursorStore, metaStore)
        this.deadLetter = DeadLetterQueue(options.deadMsgDir, options.segmentedLogMaxSize, 1)
        this.subscribers = SubscriberRegistry()
        this.backupStore = BackupStore(options.segmentedLogDir, options.segmentedLogMaxSize, 1)
        this.backup = BackupReplicator(registry, options.backup)
        let consumer = ConsumeService(queues, cursorCatalog, subscribers, MQMatcher(), deadLetter,
            options.ackTimeout, options.deadMsgThreshold, metrics: MQMetrics())
        this.consume = consumer
        // 备份要携带真实消费状态与位点（A26）
        this.backup.setStateSource(consumer)
        this.cleaner = LogCleaner(queues, deadLetter,
            {topic, queueIndex => consumer.floorOf(topic, queueIndex)},
            options.segmentedLogTTL, options.deadMsgTTL)
        this.executor = MQCommandExecutor(meta, syncer, queues, cursorCatalog, subscribers, consume, backup,
            backupStore, options.selfIndex)
        this.server = Server<DataAny>(bindAt: options.port, checkDuration: CHECK_DURATION, executors: 200,
            checker: {=> Message.ping()})
        // 节点由死转活时补一次全量同步，避免离线期间错过的注册/删除
        this.registry.onRevived = {=> this.syncer.syncFromPeers()}
    }

    protected prop port: UInt16 {
        get() {
            options.port
        }
    }

    /** 启动监听与定时器（非阻塞；测试用）。 */
    protected func start(): Unit {
        if (!started.compareAndSwap(false, true)) {
            return
        }
        let server = this.server
        let executor = this.executor
        spawn {
            server.start(executor.execute)
        }
        backup.start()
        cleaner.start()
        cleanupTimer = Some(Timer.repeat(CLEANUP_INTERVAL, CLEANUP_INTERVAL, {=> cleanupSubscribers()}))
    }

    /** 阻塞运行（生产入口）。 */
    public func run(): Int64 {
        start()
        while (!closed.load()) {
            sleep(Duration.millisecond * 500)
        }
        0
    }

    /**
     * 关闭步骤（可覆写以便注入失败）：按相反顺序释放资源。
     *
     * 每一步单独 try/catch：单步失败不影响其它资源释放（A59）。
     */
    protected func closeSteps(): Array<(String, () -> Unit)> {
        [
            ("server", {=> server.close()}),
            ("cleanupTimer", {=> cancelCleanupTimer()}),
            ("backup", {=> backup.close()}),
            ("cleaner", {=> cleaner.close()}),
            ("consume", {=> consume.close()}),
            ("backupStore", {=> backupStore.close()}),
            ("queues.sync", {=> queues.sync()}),
            ("queues", {=> queues.close()}),
            ("deadLetter", {=> deadLetter.close()}),
            ("meta", {=> meta.close()}),
            ("registry", {=> registry.close()})
        ]
    }

    /**
     * 关闭：幂等、逐步容错、失败步骤可在下一次调用重试。
     *
     * `closed` 先置位让 `run()` 退出；只有全部步骤成功才算 `closeCompleted`。
     */
    public func close(): Unit {
        synchronized(closeLock) {
            if (closeCompleted) {
                return
            }
            closed.store(true)
            let failures = ArrayList<String>()
            for ((name, step) in currentCloseSteps()) {
                if (closeDone.contains(name)) {
                    continue
                }
                try {
                    step()
                    closeDone.add(name)
                } catch (e: Exception) {
                    failures.add(name)
                    log.error("close step '${name}' failed: ${e.message}")
                }
            }
            closeCompleted = failures.size == 0
            if (!closeCompleted) {
                log.error("close incomplete, retry later: ${failures.toString()}")
            }
        }
    }

    /** 测试用：替换关闭步骤（注入失败步骤，验证隔离与重试）。 */
    protected func setCloseStepsOverride(provider: () -> Array<(String, () -> Unit)>): Unit {
        this.closeStepsOverride = Some(provider)
    }

    private func currentCloseSteps(): Array<(String, () -> Unit)> {
        match (closeStepsOverride) {
            case Some(provider) => provider()
            case None => closeSteps()
        }
    }

    private func cancelCleanupTimer(): Unit {
        match (cleanupTimer) {
            case Some(timer) =>
                timer.cancel()
                cleanupTimer = None
            case None => ()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    /** 清理已断开连接名下的订阅，并释放其已分配记录。 */
    /**
     * 断链巡检：按快照里的代次摘除，摘掉之后才释放记录。
     *
     * 期间同 `subscribedId` 被重订阅时 `unregister` 会失败，此时既不能释放记录，
     * 也不能报告清理成功（A60/A70）。
     */
    protected func cleanupSubscribers(): Unit {
        for (info in subscribers.infos()) {
            if (!info.isDisconnected()) {
                continue
            }
            let result = subscribers.unregister(info.subscribedId, generation: info.generation)
            if (result.code != 0) {
                continue
            }
            try {
                consume.releaseSubscription(info)
                log.info("subscription ${info.subscribedId} removed after connection closed")
            } catch (e: Exception) {
                log.warn("failed to cleanup subscription ${info.subscribedId}: ${e.message}")
            }
        }
    }

    private static func ensureDir(path: String): Unit {
        if (!exists(path)) {
            Directory.create(path, recursive: true)
        }
    }
}

/**
 * 安装退出钩子：`SIGTERM`/`SIGINT` 时先执行全部 atExit 回调（含 `server.close()`）再退出。
 *
 * `install` 可注入，用例据此断言「只注册一次、且回调确实会关闭服务器」，不必真的发信号。
 */
public func installExitHooks(server: MQServer, install: (() -> Unit) -> Unit): Unit {
    install({=> server.close()})
}
