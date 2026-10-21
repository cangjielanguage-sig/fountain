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
package fountain::fdbm.server

import std.collection.{ArrayList, HashMap}
import std.database.sql.Driver
import std.sync.AtomicBool
import fountain::f_base.ExitCallbacks
import fountain::f_data.DataAny
import fountain::f_dbd.common.{DbdErrorCode, DbdErrorPayload}
import fountain::f_log.LoggerFactory
import fountain::f_net.server.Server
import fountain::f_protocol.default.Message
import fountain::fdbm.config.*
import fountain::fdbm.execute.ExecutorDispatcher
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.resources.DatabaseResources
import fountain::fdbm.route.*

/**
 * fdbm 服务进程（设计 §10.1 / §10.4）。
 *
 * 构造期完成**全部**启动自检与依赖装配（自定义扩展 → 配置校验 → 驱动唯一性 → 资源/路由/缓存），
 * 任一失败直接抛 `FdbmException`，此时还没有监听端口；`start()` 只负责建监听并阻塞。
 */
protected class FdbmServer <: Resource {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.server.FdbmServer')

    private let settings: FdbmSettings
    private let custom: CustomExtensions
    private let resources: DatabaseResources
    private let router: PartitionRouter
    private let sessions: SessionRegistry
    private let context: ServerContext
    private let closed = AtomicBool(false)
    private let started = AtomicBool(false)
    private var server: ?Server<DataAny> = None

    /**
     * @param driver 物理驱动；省略时按设计从 `fdbm_driverDir` 加载（唯一性由 `DriverLoader` 校验）。
     *        该参数是给进程内嵌/用例的接入口，生产路径始终走目录加载。
     */
    public init(settings: FdbmSettings, source!: ConfigSource = EnvConfigSource(),
        driver!: ?Driver = None) {
        this.settings = settings
        let custom = CustomLoader.load(settings.customDir)
        this.custom = custom
        FdbmConfig.validate(settings, custom.partitionNames(), custom.idGeneratorNames(),
            source: source)

        let physical = physicalDatabases(settings.nodes)
        let cache = if (settings.cache.enabled) {
            Some(PartitionCache(settings.cache.path, settings.cache.expire, settings.cache.size))
        } else {
            None<PartitionCache>
        }
        let rules = ArrayList<PartitionRule>()
        for (config in settings.partitions) {
            let databases = match (settings.catalog.physicals(config.database)) {
                case Some(value) => value
                case None => physical
            }
            let algorithm = PartitionAlgorithmFactory.create(config.algorithm, databases,
                settings.partitionStep, config.substr, custom.partitions)
            rules.add(PartitionRule(config.database, config.table, config.column, algorithm))
        }
        let globalRules = ArrayList<GlobalTableRule>()
        for (config in settings.globalTables) {
            globalRules.add(GlobalTableRule(config.database, config.table))
        }
        let globals = GlobalTableRouter(globalRules.toArray(),
            logicalDatabases: settings.logicalDatabases)
        this.router = PartitionRouter(rules.toArray(), cache, custom.partitions,
            knownDatabases: physical, globalTables: globals)

        // 自定义扩展/配置校验通过后才加载物理驱动（加载失败不留下半初始化的资源）
        match (driver) {
            case Some(value) =>
                if (value.name != settings.nodes[0].driverName) {
                    throw FdbmException(DbdErrorCode.NO_DRIVER,
                        'driver \'${value.name}\' does not match fdbm_db_driver_* = ' +
                        '\'${settings.nodes[0].driverName}\'')
                }
            case None => DriverLoader.load(settings.driverDir, settings.nodes[0].driverName)
        }

        this.resources = DatabaseResources(settings.nodes, settings.pool, settings.loadBalance)

        let bootScript = bootScriptOf(settings.bootScript)
        this.sessions = SessionRegistry(settings.sessionSweepInterval, settings.defaultDatabase)
        let dispatcher = ExecutorDispatcher(this.router, globals, this.resources, settings.idmaker,
            settings.sequenceDatabase, custom.idGenerators, bootScript, catalog: settings.catalog)
        this.context = ServerContext(this.sessions, dispatcher, custom, logger)
        logger.info('fdbm is ready on port ${settings.port}: ${physical.size} physical database(s), ' +
            '${settings.partitions.size} partition rule(s)')
    }

    /**
     * 启动并**阻塞**到 `stop()` / 进程信号：bind → 注册 handler → 等优雅退出。
     *
     * 重复调用无副作用（第二次直接返回）。
     */
    public func start(): Unit {
        if (closed.load() || started.swap(true)) {
            return
        }
        let server = try {
            Server<DataAny>(bindAt: settings.port, checkDuration: settings.checkDuration,
                unavailableChecked: settings.unavailableChecked, checker: {=> Message.ping()},
                defaultResp: {id => Message.error(id,
                    data: DbdErrorPayload(DbdErrorCode.INTERNAL, 'no response'))})
        } catch (e: FdbmException) {
            throw e
        } catch (e: Exception) {
            throw FdbmException(DbdErrorCode.CONFIG,
                'cannot listen on port ${settings.port}: ${e.message}', e)
        }
        this.server = Some(server)
        ExitCallbacks.toExitGracefully()
        ExitCallbacks.atExit(0, {=> stop()})
        logger.info('fdbm is listening on port ${settings.port}')
        try {
            server.start {buffer, message =>
                Some(FdbmHandler.handle(context, buffer, message))
            }
        } catch (e: Exception) {
            if (!closed.load()) {
                logger.error('fdbm listener failed: ${e.message}', e)
            }
        }
    }

    /** 优雅停止（设计 §10.4 六步，幂等）。 */
    public func stop(): Unit {
        if (closed.swap(true)) {
            return
        }
        logger.info('fdbm is stopping')
        match (server) {
            case Some(value) =>
                try {
                    value.close()
                } catch (e: Exception) {
                    logger.warn('failed to close the listener: ${e.message}')
                }
            case None => ()
        }
        InFlight.await(settings.shutdownTimeout)
        sessions.closeAll()
        resources.closeAndAwait(timeout: settings.shutdownTimeout)
        router.close()
        logger.info('fdbm stopped')
    }

    public func close(): Unit {
        stop()
    }

    public func isClosed(): Bool {
        closed.load()
    }

    private static func bootScriptOf(path: String): ?BootScriptWriter {
        try {
            let writer = BootScriptWriter(path)
            // normalize() 自己吞异常（失败只记 ERROR，不阻塞启动）
            writer.normalize()
            Some(writer)
        } catch (e: Exception) {
            logger.warn('boot script \'${path}\' is not writable: ${e.message}')
            None<BootScriptWriter>
        }
    }

    private static func physicalDatabases(nodes: Array<DatabaseNodeConfig>): Array<String> {
        let databases = ArrayList<String>()
        for (node in nodes) {
            for (database in node.databases) {
                if (!databases.contains(database)) {
                    databases.add(database)
                }
            }
        }
        databases.toArray()
    }
}
