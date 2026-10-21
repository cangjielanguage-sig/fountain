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
import std.database.sql.DriverManager
import std.fs.*
import std.sync.Mutex
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataAny
import fountain::f_dbd.common.*
import fountain::f_log.LoggerFactory
import fountain::f_mockdb.*
import fountain::f_net.client.Client
import fountain::f_protocol.default.*
import fountain::fdbm.config.{ConfigSource, FdbmSettings, MapConfigSource}
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.route.PartitionCache

/** 阶段 8 Step 8.2-8.4：会话/在途计数/加载器/服务生命周期。 */
@Test
public class ServerLifecycleTest {

    // ==================== InFlight ====================

    @TestCase
    public func inFlightCountsEnterAndLeave(): Unit {
        InFlight.enter()
        @Assert(InFlight.count(), 1)
        InFlight.enter()
        @Assert(InFlight.count(), 2)
        InFlight.leave()
        InFlight.leave()
        @Assert(InFlight.count(), 0)
        @Assert(InFlight.await(Duration.millisecond * 100), true)
    }

    @TestCase
    public func inFlightAwaitTimesOut(): Unit {
        InFlight.enter()
        @Assert(InFlight.await(Duration.millisecond * 50), false)
        InFlight.leave()
        @Assert(InFlight.await(Duration.millisecond * 100), true)
    }

    /** T04：`leave` 必须唤醒阻塞中的 `await` 并返回 `true`（不是超时 `false`）。 */
    @TestCase
    public func inFlightLeaveWakesBlockedAwait(): Unit {
        InFlight.enter()
        let awaiting = spawn {
            InFlight.await(Duration.second * 5)
        }
        sleep(Duration.millisecond * 100)
        InFlight.leave()
        @Assert(awaiting.get(), true)
        @Assert(InFlight.count(), 0)
    }

    // ==================== SessionRegistry ====================

    @TestCase
    public func sameBufferReusesSessionAndRemoveRecreates(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('select * from t where id = 1')), Duration.second * 5)
            let buffer = harness.lastBuffer()
            let first = harness.sessions.of(buffer)
            let second = harness.sessions.of(buffer)
            @Assert(first.id, second.id)
            harness.sessions.remove(buffer)
            @Assert(harness.sessions.size(), 0)
            let recreated = harness.sessions.of(buffer)
            @Assert(recreated.id == first.id, false)
        } finally {
            client.close()
            harness.close()
        }
    }

    /** T04：同一连接并发 `of()` 只创建一个会话（不因竞态重复建）。 */
    @TestCase
    public func concurrentOfSameBufferCreatesOneSession(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('select * from t where id = 1')), Duration.second * 5)
            let buffer = harness.lastBuffer()
            let lock = Mutex()
            let ids = ArrayList<String>()
            let futures = ArrayList<Future<Unit>>()
            for (_ in 0..8) {
                let fut = spawn {
                    let session = harness.sessions.of(buffer)
                    synchronized(lock) {
                        ids.add(session.id)
                    }
                }
                futures.add(fut)
            }
            for (fut in futures) {
                fut.get()
            }
            @Assert(ids.size, 8)
            let first = ids[0]
            for (id in ids) {
                @Assert(id, first)
            }
            @Assert(harness.sessions.size(), 1)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func sweepReclaimsDisconnectedSession(): Unit {
        let harness = Harness(rows: [1], sweep: Duration.millisecond * 50)
        let client = harness.client()
        try {
            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('select * from t where id = 1')), Duration.second * 5)
            @Assert(harness.sessions.size(), 1)
        } finally {
            client.close()
        }
        var attempts = 0
        while (harness.sessions.size() > 0 && attempts < 40) {
            sleep(Duration.millisecond * 50)
            attempts += 1
        }
        @Assert(harness.sessions.size(), 0)
        harness.close()
    }

    // ==================== 缓存落盘与重启 ====================

    @TestCase
    public func partitionCacheSurvivesRestart(): Unit {
        let dir = tempDir()
        try {
            let first = PartitionCache(dir.toString(), None, 0)
            @Assert(first.get('db0', 't', 'id', '5').isNone(), true)
            first.put('db0', 't', 'id', '5', 'db1')
            @Assert(first.get('db0', 't', 'id', '5').getOrThrow(), 'db1')
            first.close()

            let restarted = PartitionCache(dir.toString(), None, 0)
            @Assert(restarted.get('db0', 't', 'id', '5').getOrThrow(), 'db1')
            restarted.close()
        } finally {
            removeTree(dir)
        }
    }

    // ==================== DriverLoader / CustomLoader ====================

    @TestCase
    public func driverLoaderRequiresExactlyOneLibrary(): Unit {
        @Assert(codeOf { DriverLoader.load('/tmp/definitely-missing-${stamp()}', 'mockdb') },
            DbdErrorCode.NO_DRIVER)
        let empty = tempDir()
        try {
            @Assert(codeOf { DriverLoader.load(empty.toString(), 'mockdb') }, DbdErrorCode.NO_DRIVER)
            File.writeTo(empty.join('a.so'), Array<Byte>())
            File.writeTo(empty.join('b.so'), Array<Byte>())
            @Assert(codeOf { DriverLoader.load(empty.toString(), 'mockdb') }, DbdErrorCode.NO_DRIVER)
        } finally {
            removeTree(empty)
        }
    }

    @TestCase
    public func driverLoaderWrapsLoadFailureAsConfig(): Unit {
        let dir = tempDir()
        try {
            File.writeTo(dir.join('broken.so'), 'not a library'.toArray())
            @Assert(codeOf { DriverLoader.load(dir.toString(), 'mockdb') }, DbdErrorCode.CONFIG)
        } finally {
            removeTree(dir)
        }
    }

    @TestCase
    public func customLoaderTreatsMissingDirectoryAsEmpty(): Unit {
        let custom = CustomLoader.load('/tmp/definitely-missing-${stamp()}')
        @Assert(custom.partitionNames().size, 0)
        @Assert(custom.idGeneratorNames().size, 0)
    }

    @TestCase
    public func customLoaderFailsOnBrokenLibrary(): Unit {
        let dir = tempDir()
        try {
            File.writeTo(dir.join('broken.so'), 'not a library'.toArray())
            @Assert(codeOf { CustomLoader.load(dir.toString()) }, DbdErrorCode.CONFIG)
        } finally {
            removeTree(dir)
        }
    }

    // ==================== FdbmServer ====================

    @TestCase
    public func serverStartsServesAndStops(): Unit {
        let port = uniquePort()
        let source = settingsSource(port)
        let settings = FdbmSettings.load(source: source)
        let driver = DriverManager.getDriver('mockdb').getOrThrow()
        let server = FdbmServer(settings, source: source, driver: driver)
        let started = server
        spawn {
            try {
                started.start()
            } catch (_: Exception) {
                ()
            }
        }
        try {
            @Assert(waitForPort(port), true)
            let answer = request(port, 'select * from t where id = 1')
            @Assert(decodeStrict<QueryResultServerPayload>(answer.data).getOrThrow().columnInfos.size, 1)
            server.stop()
            @Assert(server.isClosed(), true)
            // 幂等：再次停止无副作用
            server.stop()
            @Assert(connectFails(port), true)
        } finally {
            server.stop()
        }
    }

    /** G14：构造失败时缓存/连接池必须已释放（同一 cache 目录可立即重新打开并写入）。 */
    @TestCase
    public func constructorFailureReleasesCacheAndPools(): Unit {
        let dir = tempDir()
        try {
            let port = uniquePort()
            let source = settingsSource(port, idmaker: 'sequence', cache: true,
                cachePath: dir.toString())
            let settings = FdbmSettings.load(source: source)
            let driver = DriverManager.getDriver('mockdb').getOrThrow()
            MOCKDB.clear()
            MOCKDB.execution = {sql, _ =>
                if (sql.contains('fountain_sequence')) {
                    throw Exception('injected missing sequence table')
                }
                MOCKDB.rowCount = 1
            }
            @Assert(codeOf { FdbmServer(settings, source: source, driver: driver) },
                DbdErrorCode.ID_GENERATOR)

            // 上一个实例的缓存若未关闭，这里会看到残留状态/句柄；能正常写入即证明已释放
            let cache = PartitionCache(dir.toString(), None, 0)
            cache.put('db0', 't', 'id', '1', 'p0')
            @Assert(cache.count(), 1)
            cache.close()
        } finally {
            removeTree(dir)
        }
    }

    /** G12：端口被占用时 `start()` 必须报 `CONFIG`（main 据此返回 1）。 */
    @TestCase
    public func listenFailureIsConfigError(): Unit {
        let port = uniquePort()
        let source = settingsSource(port)
        let settings = FdbmSettings.load(source: source)
        let driver = DriverManager.getDriver('mockdb').getOrThrow()
        let first = FdbmServer(settings, source: source, driver: driver)
        let started = first
        spawn {
            try {
                started.start()
            } catch (_: Exception) {
                ()
            }
        }
        try {
            @Assert(waitForPort(port), true)
            let second = FdbmServer(settings, source: source, driver: driver)
            try {
                @Assert(codeOf { second.start() }, DbdErrorCode.CONFIG)
            } finally {
                second.stop()
            }
        } finally {
            first.stop()
        }
    }

    /** G16：巡检与在途请求并发 100 轮，不得误关活跃会话。 */
    @TestCase
    public func sweepKeepsLiveSessionWhileRequestsInFlight(): Unit {
        let harness = Harness(rows: [1], sweep: Duration.millisecond * 1)
        let client = harness.client()
        try {
            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('select * from t where id = 1')), Duration.second * 5)
            @Assert(harness.sessions.size(), 1)
            var i: Int64 = 0
            while (i < 100) {
                InFlight.enter()
                harness.sessions.sweep()
                @Assert(harness.sessions.size(), 1)
                InFlight.leave()
                i += 1
            }
        } finally {
            client.close()
            harness.close()
        }
    }

    /** G16：同一连接重复 remove 只关闭一次（第二次是 no-op）。 */
    @TestCase
    public func removeTwiceIsIdempotent(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('select * from t where id = 1')), Duration.second * 5)
            let buffer = harness.lastBuffer()
            @Assert(harness.sessions.size(), 1)
            harness.sessions.remove(buffer)
            @Assert(harness.sessions.size(), 0)
            harness.sessions.remove(buffer)
            @Assert(harness.sessions.size(), 0)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func constructorRejectsDriverNameMismatch(): Unit {
        let port = uniquePort()
        let source = settingsSource(port, driverName: 'postgres')
        let settings = FdbmSettings.load(source: source)
        let driver = DriverManager.getDriver('mockdb').getOrThrow()
        @Assert(codeOf { FdbmServer(settings, source: source, driver: driver) }, DbdErrorCode.NO_DRIVER)
    }

    // ==================== 工具 ====================

    private func codeOf<T>(body: () -> T): DbdErrorCode {
        try {
            body()
        } catch (e: FdbmException) {
            return e.code
        } catch (_: Exception) {
            return DbdErrorCode.INTERNAL
        }
        DbdErrorCode.INTERNAL
    }

    private func request(port: UInt16, sql: String): Message {
        let client = Client<DataAny>.builder(queueSize: 64, socketCount: 1, host: '127.0.0.1',
            port: port, checkDuration: Duration.second * 30, checker: {=> Message.ping()}).build()
        try {
            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce, data: SqlPayload(sql)),
                Duration.second * 5).getOrThrow()
        } finally {
            client.close()
        }
    }

    private func connectFails(port: UInt16): Bool {
        let client = try {
            Client<DataAny>.builder(queueSize: 8, socketCount: 1, host: '127.0.0.1', port: port,
                checkDuration: Duration.second * 30, checker: {=> Message.ping()}).build()
        } catch (_: Exception) {
            return true
        }
        try {
            client.transfer(Message.ping(), Duration.millisecond * 500)
            false
        } catch (_: Exception) {
            true
        } finally {
            try {
                client.close()
            } catch (_: Exception) {
                ()
            }
        }
    }

    private func settingsSource(port: UInt16, driverName!: String = 'mockdb',
        idmaker!: String = 'uuid,4', cache!: Bool = false,
        cachePath!: String = './cache'): ConfigSource {
        let values = HashMap<String, String>()
        values['fdbm_port'] = port.toString()
        values['fdbm_db'] = 'name0@127.0.0.1:3306'
        values['fdbm_db_driver_name0'] = driverName
        values['fdbm_db_database_name0'] = 'db0,db1'
        values['fdbm_idmaker'] = idmaker
        values['fdbm_cache'] = if (cache) { 'true' } else { 'false' }
        values['fdbm_cachePath'] = cachePath
        values['fdbm_driverDir'] = '/tmp/definitely-missing-driver'
        values['fdbm_customDir'] = '/tmp/definitely-missing-custom'
        values['fdbm_bootScript'] = '/tmp/definitely-missing-boot.sh'
        values['fdbm_sessionSweepInterval'] = '50ms'
        values['fdbm_shutdownTimeout'] = '2s'
        values['fdbm_checkDuration'] = '1s'
        values['fdbm_databasePoolInitSize'] = '0'
        values['fdbm_databasePoolMaxSize'] = '2'
        MOCKDB.clear()
        MOCKDB.execution = {sql, _ =>
            if (sql.startsWith('select')) {
                MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultRow([1])
            } else {
                MOCKDB.rowCount = 1
            }
        }
        MapConfigSource(values)
    }

    private func tempDir(): Path {
        Directory.createTemp('/tmp')
    }

    private func removeTree(dir: Path): Unit {
        try {
            remove(dir, recursive: true)
        } catch (_: Exception) {
            ()
        }
    }

    private func stamp(): String {
        '${MonoStamp.now()}'
    }
}

/** 单调时间戳（避免用例间目录重名；不引入随机数依赖）。 */
struct MonoStamp {
    static func now(): Int64 {
        DateTime.now().toUnixTimeStamp().toNanoseconds()
    }
}
