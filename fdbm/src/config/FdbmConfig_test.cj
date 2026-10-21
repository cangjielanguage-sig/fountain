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
package fountain::fdbm.config

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException

/** Step 1.1 配置模型（设计 §3.3）：URL 生成、权重查找与默认值。 */
@Test
public class ConfigModelTest {

    @TestCase
    public func nodeUrlEncodesCredentials(): Unit {
        let node = DatabaseNodeConfig('name0', 'h1', 9001u16, 'mysql', ['db0'], 'u0', 'p@ss')
        @Assert(node.url('db0'), 'mysql://u0:p%40ss@h1:9001/db0')
        let anonymous = DatabaseNodeConfig('name1', 'h2', 9002u16, 'postgres', ['db1'], '', '')
        @Assert(anonymous.url('db1'), 'postgres://h2:9002/db1')
    }

    @TestCase
    public func weightLookupPrefersDatabaseLevel(): Unit {
        let weights = HashMap<String, NodeWeight>()
        weights['name0'] = NodeWeight(write: 2, read: 3)
        weights['name0__db0'] = NodeWeight(write: 0, read: 5)
        let config = LoadBalanceConfig(algorithm: 'roundrobin', weights: weights)
        @Assert(config.weight('name0', 'db0').write, 0)
        @Assert(config.weight('name0', 'db0').read, 5)
        @Assert(config.weight('name0', 'db1').write, 2)
        @Assert(config.weight('name1', 'db0').write, 1)
        @Assert(config.weight('name0', 'db0').canWrite(), false)
        @Assert(config.weight('name0', 'db0').canRead(), true)
    }

    @TestCase
    public func poolDefaults(): Unit {
        let pool = PoolConfig()
        @Assert(pool.initSize, 1)
        @Assert(pool.minSize, 1)
        @Assert(pool.maxSize, 1)
        @Assert(pool.checkOnCreation, false)
        @Assert(pool.checkOnBorrowing, true)
        @Assert(pool.checkOnReturning, false)
        @Assert(pool.idleTimeout, Duration.Zero)
        @Assert(pool.connectionLife, Duration.second * 86400)
        @Assert(pool.checkInterval, Duration.second * 300)
        @Assert(pool.connectTimeout, Duration.millisecond * 50)
        @Assert(pool.maxWaiting, Duration.millisecond * 30000)
        @Assert(pool.checkSql, 'select 1')
    }
}

/** Step 1.2 `FdbmConfig`（设计 §3.1/§3.2）：各 `get*` 的解析、默认值与非法值。 */
@Test
public class FdbmConfigTest {

    @TestCase
    public func parsesNodes(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001;name1@[::1]:9002'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0, db1'),
            ('fdbm_db_username_name0', 'u0'),
            ('fdbm_db_password_name0', 'p@ss'),
            ('fdbm_db_driver_name1', 'mysql'),
            ('fdbm_db_database_name1', 'db2')
        ])
        let nodes = FdbmConfig.getNodes(source: source)
        @Assert(nodes.size, 2)
        @Assert(nodes[0].name, 'name0')
        @Assert(nodes[0].host, 'h1')
        @Assert(nodes[0].port, 9001u16)
        @Assert(nodes[0].databases.size, 2)
        @Assert(nodes[0].databases[1], 'db1')
        @Assert(nodes[0].url('db0'), 'mysql://u0:p%40ss@h1:9001/db0')
        @Assert(nodes[1].host, '[::1]')
        @Assert(nodes[1].username, '')
    }

    @TestCase
    public func nodeErrorsAreConfigErrors(): Unit {
        let missingDriver = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_database_name0', 'db0')
        ])
        @Assert(fdbmCodeOf { FdbmConfig.getNodes(source: missingDriver) }, DbdErrorCode.CONFIG)

        let missingPort = configOf([
            ('fdbm_db', 'name0@h1'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0')
        ])
        @Assert(fdbmCodeOf { FdbmConfig.getNodes(source: missingPort) }, DbdErrorCode.CONFIG)

        let duplicate = configOf([
            ('fdbm_db', 'name0@h1:1;name0@h2:2'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0')
        ])
        @Assert(fdbmCodeOf { FdbmConfig.getNodes(source: duplicate) }, DbdErrorCode.CONFIG)

        let empty = configOf([('fdbm_db', '')])
        @Assert(fdbmCodeOf { FdbmConfig.getNodes(source: empty) }, DbdErrorCode.CONFIG)
    }

    @TestCase
    public func portParsing(): Unit {
        @Assert(FdbmConfig.getPort(source: configOf([])), 8112)
        @Assert(FdbmConfig.getPort(source: configOf([('fdbm_port', '9000')])), 9000u16)
        @Assert(fdbmCodeOf { FdbmConfig.getPort(source: configOf([('fdbm_port', 'abc')])) },
            DbdErrorCode.CONFIG)
        @Assert(fdbmCodeOf { FdbmConfig.getPort(source: configOf([('fdbm_port', '0')])) },
            DbdErrorCode.CONFIG)
    }

    @TestCase
    public func poolDefaultsAndOverrides(): Unit {
        let defaults = FdbmConfig.getPool(source: configOf([]))
        @Assert(defaults.initSize, 1)
        @Assert(defaults.checkOnBorrowing, true)
        @Assert(defaults.idleTimeout, Duration.Zero)

        let source = configOf([
            ('fdbm_databasePoolInitSize', '2'),
            ('fdbm_databasePoolMinSize', '3'),
            ('fdbm_databasePoolMaxSize', '9'),
            ('fdbm_databasePoolCheckOnCreation', 'true'),
            ('fdbm_databasePoolCheckOnBorrowing', 'false'),
            ('fdbm_databasePoolCheckOnReturning', 'true'),
            ('fdbm_databasePoolIdleTimeout', '5'),
            ('fdbm_databasePoolConnectionLife', '3600'),
            ('fdbm_databasePoolCheckInterval', '120'),
            ('fdbm_databasePoolConnectTimeout', '75'),
            ('fdbm_databasePoolMaxWaiting', '9000'),
            ('fdbm_databasePoolCheckSql', 'select 2')
        ])
        let pool = FdbmConfig.getPool(source: source)
        @Assert(pool.initSize, 2)
        @Assert(pool.minSize, 3)
        @Assert(pool.maxSize, 9)
        @Assert(pool.checkOnCreation, true)
        @Assert(pool.checkOnBorrowing, false)
        @Assert(pool.checkOnReturning, true)
        @Assert(pool.idleTimeout, Duration.second * 5)
        @Assert(pool.connectionLife, Duration.second * 3600)
        @Assert(pool.checkInterval, Duration.second * 120)
        @Assert(pool.connectTimeout, Duration.millisecond * 75)
        @Assert(pool.maxWaiting, Duration.millisecond * 9000)
        @Assert(pool.checkSql, 'select 2')
    }

    @TestCase
    public func maxWaitingZeroMeansInfinite(): Unit {
        let pool = FdbmConfig.getPool(source: configOf([('fdbm_databasePoolMaxWaiting', '0')]))
        @Assert(pool.maxWaiting, Duration.Max)
    }

    @TestCase
    public func parsesLoadBalanceWeights(): Unit {
        let source = configOf([
            ('fdbm_loadbalance', 'roundrobin'),
            ('fdbm_loadbalance_weight_name0', 'w,2;r;3'),
            ('fdbm_loadbalance_weight_name0__db0', 'w,0;r,5')
        ])
        let config = FdbmConfig.getLoadBalance(source: source)
        @Assert(config.algorithm, 'roundrobin')
        @Assert(config.weight('name0', 'db0').write, 0)
        @Assert(config.weight('name0', 'db0').read, 5)
        @Assert(config.weight('name0', 'db1').write, 2)
        @Assert(config.weight('name0', 'db1').read, 3)
    }

    @TestCase
    public func weightErrorsAreConfigErrors(): Unit {
        @Assert(fdbmCodeOf {
            FdbmConfig.getLoadBalance(source: configOf([
                ('fdbm_loadbalance_weight_name0_', 'w,1')
            ]))
        }, DbdErrorCode.CONFIG)
        @Assert(fdbmCodeOf {
            FdbmConfig.getLoadBalance(source: configOf([
                ('fdbm_loadbalance_weight_name0', 'x,1')
            ]))
        }, DbdErrorCode.CONFIG)
        @Assert(fdbmCodeOf {
            FdbmConfig.getLoadBalance(source: configOf([('fdbm_loadbalance', 'randomx')]))
        }, DbdErrorCode.CONFIG)
    }

    @TestCase
    public func parsesPartitionsAndSubstr(): Unit {
        let source = configOf([
            ('fdbm_partition__orders', 'order,hash,user_id'),
            ('fdbm_partition__accounts', 'order,substr,account_no'),
            ('fdbm_partition_substr__accounts', '0,4,crc32')
        ])
        let rules = FdbmConfig.getPartitions(source: source)
        @Assert(rules.size, 2)
        var accounts: ?PartitionRuleConfig = None
        for (rule in rules) {
            if (rule.table == 'accounts') {
                accounts = Some(rule)
            }
        }
        let rule = accounts.getOrThrow()
        @Assert(rule.algorithm, 'substr')
        @Assert(rule.column, 'account_no')
        let spec = rule.substr.getOrThrow()
        @Assert(spec.start, 0)
        @Assert(spec.length, 4)
        @Assert(spec.hash, 'crc32')
    }

    @TestCase
    public func partitionErrorsAreConfigErrors(): Unit {
        @Assert(fdbmCodeOf {
            FdbmConfig.getPartitions(source: configOf([('fdbm_partition', 'order,hash,id')]))
        }, DbdErrorCode.CONFIG)
        @Assert(fdbmCodeOf {
            FdbmConfig.getPartitions(source: configOf([
                ('fdbm_partition__accounts', 'order,substr,account_no')
            ]))
        }, DbdErrorCode.CONFIG)
        @Assert(fdbmCodeOf {
            FdbmConfig.getPartitions(source: configOf([
                ('fdbm_partition__accounts', 'order,substr,account_no'),
                ('fdbm_partition_substr__accounts', '0,4,sha1')
            ]))
        }, DbdErrorCode.CONFIG)
        @Assert(fdbmCodeOf {
            FdbmConfig.getPartitions(source: configOf([('fdbm_partition__orders', 'order,hash')]))
        }, DbdErrorCode.CONFIG)
    }

    @TestCase
    public func parsesGlobalTables(): Unit {
        let tables = FdbmConfig.getGlobalTables(source: configOf([
            ('fdbm_global__dict', 'cfg'),
            ('fdbm_global__area', 'cfg')
        ]))
        @Assert(tables.size, 2)
        for (table in tables) {
            @Assert(table.database, 'cfg')
        }
    }

    @TestCase
    public func parsesIdMaker(): Unit {
        @Assert(FdbmConfig.getIdMaker(source: configOf([])).kind, 'uuid')
        @Assert(FdbmConfig.getIdMaker(source: configOf([('fdbm_idmaker', 'uuid,4')])).arg.getOrThrow(), '4')
        @Assert(FdbmConfig.getIdMaker(source: configOf([('fdbm_idmaker', 'snowflake,7')])).arg.getOrThrow(), '7')
        @Assert(FdbmConfig.getIdMaker(source: configOf([('fdbm_idmaker', 'sequence')])).kind, 'sequence')
        @Assert(fdbmCodeOf {
            FdbmConfig.getIdMaker(source: configOf([('fdbm_idmaker', 'uuid,2')]))
        }, DbdErrorCode.CONFIG)
        @Assert(fdbmCodeOf {
            FdbmConfig.getIdMaker(source: configOf([('fdbm_idmaker', 'snowflake,1024')]))
        }, DbdErrorCode.CONFIG)
        // 自定义扩展名在解析期放行（validate 用扩展名单再判定）。
        @Assert(FdbmConfig.getIdMaker(source: configOf([('fdbm_idmaker', 'bogus')])).kind, 'bogus')
    }

    @TestCase
    public func parsesCacheAndPaths(): Unit {
        let defaults = FdbmConfig.getCache(source: configOf([]))
        @Assert(defaults.enabled, true)
        @Assert(defaults.expire.isNone(), true)
        @Assert(defaults.size, 0)
        @Assert(defaults.path, './cache')

        let source = configOf([
            ('fdbm_cache', 'false'),
            ('fdbm_cache_expire', '1d'),
            ('fdbm_cache_size', '100'),
            ('fdbm_cachePath', '/var/fdbm/cache'),
            ('fdbm_driverDir', '/opt/driver'),
            ('fdbm_customDir', '/opt/custom'),
            ('fdbm_bootScript', '/opt/boot.sh')
        ])
        let cache = FdbmConfig.getCache(source: source)
        @Assert(cache.enabled, false)
        @Assert(cache.expire.getOrThrow(), Duration.day)
        @Assert(cache.size, 100)
        @Assert(cache.path, '/var/fdbm/cache')
        @Assert(FdbmConfig.getDriverDir(source: source), '/opt/driver')
        @Assert(FdbmConfig.getCustomDir(source: source), '/opt/custom')
        @Assert(FdbmConfig.getBootScript(source: source), '/opt/boot.sh')
    }

    @TestCase
    public func durationsAcceptBareNumbersAndUnits(): Unit {
        @Assert(FdbmConfig.getSessionSweepInterval(source: configOf([])), Duration.second * 30)
        @Assert(FdbmConfig.getShutdownTimeout(source: configOf([])), Duration.second * 30)
        @Assert(FdbmConfig.getCheckDuration(source: configOf([])), Duration.second * 30)
        @Assert(FdbmConfig.getUnavailableChecked(source: configOf([])), 3)

        let source = configOf([
            ('fdbm_sessionSweepInterval', '15'),
            ('fdbm_shutdownTimeout', '20s'),
            ('fdbm_checkDuration', '45'),
            ('fdbm_unavailableChecked', '5')
        ])
        @Assert(FdbmConfig.getSessionSweepInterval(source: source), Duration.second * 15)
        @Assert(FdbmConfig.getShutdownTimeout(source: source), Duration.second * 20)
        @Assert(FdbmConfig.getCheckDuration(source: source), Duration.second * 45)
        @Assert(FdbmConfig.getUnavailableChecked(source: source), 5)
    }

    @TestCase
    public func settingsLoadAggregatesEverything(): Unit {
        let source = configOf([
            ('fdbm_port', '9000'),
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_sequenceDatabase', 'db0')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(settings.port, 9000u16)
        @Assert(settings.nodes.size, 1)
        @Assert(settings.sequenceDatabase, 'db0')
        @Assert(settings.loadBalance.algorithm, 'random')
    }

    /** D03：显式逻辑库之外不得出现物理库键；默认库取逻辑库。 */
    @TestCase
    public func logicalCatalogHidesPhysicalNames(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0,db1,db2,db3'),
            ('fdbm_db_logicalDatabase_app', 'db0,db1,db2,db3')
        ])
        let settings = FdbmSettings.load(source: source)
        let names = settings.catalog.names()
        @Assert(names.size, 1)
        @Assert(names[0], 'app')
        @Assert(settings.logicalDatabases.size, 1)
        @Assert(settings.defaultDatabase, 'app')
        @Assert(settings.catalog.physicals('app').getOrThrow().size, 4)
    }

    /** D03：多逻辑库时默认库取排序首项，绝不取物理库名。 */
    @TestCase
    public func defaultLogicalDatabaseIsSortedFirstName(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0,db1,db2,db3'),
            ('fdbm_db_logicalDatabase_zeta', 'db2,db3'),
            ('fdbm_db_logicalDatabase_alpha', 'db0,db1')
        ])
        let settings = FdbmSettings.load(source: source)
        let names = settings.catalog.names()
        @Assert(names.size, 2)
        @Assert(names[0], 'alpha')
        @Assert(names[1], 'zeta')
        @Assert(settings.defaultDatabase, 'alpha')
        @Assert(settings.defaultDatabase == 'db0', false)
    }

    /** D03：只配分库规则时，被引用的逻辑库隐式展开为全部物理库（排序去重）。 */
    @TestCase
    public func implicitLogicalDatabaseExpandsToAllPhysicals(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db3,db1,db0,db2'),
            ('fdbm_partition__orders', 'order,hash,id')
        ])
        let settings = FdbmSettings.load(source: source)
        let names = settings.catalog.names()
        @Assert(names.size, 1)
        @Assert(names[0], 'order')
        let physicals = settings.catalog.physicals('order').getOrThrow()
        @Assert(physicals.size, 4)
        @Assert(physicals[0], 'db0')
        @Assert(physicals[3], 'db3')
    }

    /** D03：`sequenceDatabase` 接受逻辑库名，解析为其物理库排序首项；未知 → `ID_GENERATOR`。 */
    @TestCase
    public func sequenceDatabaseResolvesLogicalName(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db4,db5,db6'),
            ('fdbm_db_logicalDatabase_order', 'db5,db4'),
            ('fdbm_sequenceDatabase', 'order')
        ])
        @Assert(FdbmSettings.load(source: source).sequenceDatabase, 'db4')

        let unknown = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db4'),
            ('fdbm_sequenceDatabase', 'missing')
        ])
        @Assert(fdbmCodeOf { FdbmSettings.load(source: unknown) }, DbdErrorCode.ID_GENERATOR)
    }
}

/** Step 1.2 `validate`（设计 §11）：跨项自检的负例。 */
@Test
public class FdbmValidateTest {

    @TestCase
    public func driverMustBeUnique(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001;name1@h2:9002'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_db_driver_name1', 'postgres'),
            ('fdbm_db_database_name1', 'db1')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], [], source: source) },
            DbdErrorCode.NO_DRIVER)
    }

    @TestCase
    public func logicalDatabaseReferencesMustExist(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_db_logicalDatabase_order', 'db0,missing')
        ])
        // 显式逻辑库引用的物理库必须存在：装载期即失败（D03）
        @Assert(fdbmCodeOf { FdbmSettings.load(source: source) }, DbdErrorCode.CONFIG)
    }

    @TestCase
    public func weightReferencesMustExist(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_loadbalance_weight_name9', 'w,1')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], [], source: source) },
            DbdErrorCode.CONFIG)
    }

    @TestCase
    public func unknownAlgorithmIsPartitionConfig(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_partition__orders', 'db0,bogus,id')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], [], source: source) },
            DbdErrorCode.PARTITION_CONFIG)
        // 自定义算法参与合法性校验
        FdbmConfig.validate(settings, ['bogus'], [], source: source)
    }

    /** 分库规则引用未显式配置的逻辑库 → 隐式展开为全部物理库（D03）。 */
    @TestCase
    public func partitionLogicalDatabaseIsImplicit(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_partition__orders', 'nope,hash,id')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(settings.catalog.physicals('nope').getOrThrow(), ['db0'])
        FdbmConfig.validate(settings, [], [], source: source)
    }

    @TestCase
    public func snowflakeRequiresNodeSerial(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_idmaker', 'snowflake')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], [], source: source) },
            DbdErrorCode.CONFIG)

        let withSerial = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_idmaker', 'snowflake,7')
        ])
        FdbmConfig.validate(FdbmSettings.load(source: withSerial), [], [], source: withSerial)
    }

    @TestCase
    public func sequenceDatabaseMustExist(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_idmaker', 'sequence'),
            ('fdbm_sequenceDatabase', 'missing')
        ])
        @Assert(fdbmCodeOf { FdbmSettings.load(source: source) }, DbdErrorCode.ID_GENERATOR)
    }

    /** G08：全局表引用未知逻辑库 → 启动失败（CONFIG）。 */
    @TestCase
    public func globalTableLogicalDatabaseMustExist(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0,db1'),
            ('fdbm_global__dict', 'cfg')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], [], source: source) },
            DbdErrorCode.CONFIG)
    }

    /** D09：自定义分区算法不得与内置名冲突。 */
    @TestCase
    public func customAlgorithmCannotOverrideBuiltin(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_partition__orders', 'db0,hash,id')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, ['hash'], [], source: source) },
            DbdErrorCode.PARTITION_CONFIG)
        // 非冲突的自定义名仍然生效
        FdbmConfig.validate(settings, ['myhash'], [], source: source)
    }

    /** D09：自定义 ID 生成器不得与内置名冲突。 */
    @TestCase
    public func customIdGeneratorCannotOverrideBuiltin(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], ['uuid'], source: source) },
            DbdErrorCode.CONFIG)
        FdbmConfig.validate(settings, [], ['myuuid'], source: source)
    }

    /** G29：`sessionSweepInterval` 必须是正且有限的时长。 */
    @TestCase
    public func sessionSweepIntervalMustBePositive(): Unit {
        let zero = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_sessionSweepInterval', '0')
        ])
        let settings = FdbmSettings.load(source: zero)
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], [], source: zero) },
            DbdErrorCode.CONFIG)
    }

    /** G29/D09：未知 idmaker 在解析期放行，由 validate 结合自定义扩展名单判定。 */
    @TestCase
    public func customIdMakerIsValidatedAfterExtensionsLoad(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_idmaker', 'markergen')
        ])
        let settings = FdbmSettings.load(source: source)
        @Assert(settings.idmaker.kind, 'markergen')
        @Assert(fdbmCodeOf { FdbmConfig.validate(settings, [], [], source: source) },
            DbdErrorCode.CONFIG)
        FdbmConfig.validate(settings, [], ['markergen'], source: source)
    }

    /** T08：§11 的时长类负例逐条覆盖（shutdown / checkDuration / unavailableChecked）。 */
    @TestCase
    public func durationSettingsMustBePositiveAndFinite(): Unit {
        let base = ArrayList<(String, String)>()
        base.add(('fdbm_db', 'name0@h1:9001'))
        base.add(('fdbm_db_driver_name0', 'mysql'))
        base.add(('fdbm_db_database_name0', 'db0'))
        for (entry in [('fdbm_shutdownTimeout', '0'), ('fdbm_shutdownTimeout', 'max'),
            ('fdbm_checkDuration', '0'), ('fdbm_unavailableChecked', '0')]) {
            let entries = ArrayList<(String, String)>()
            for (existing in base) {
                entries.add(existing)
            }
            entries.add(entry)
            let source = configOf(entries.toArray())
            // 有的项在解析期就拒绝，有的在 validate 期拒绝；两者都必须是 CONFIG。
            @Assert(fdbmCodeOf {
                FdbmConfig.validate(FdbmSettings.load(source: source), [], [], source: source)
            }, DbdErrorCode.CONFIG)
        }
    }

    @TestCase
    public func positiveSettingsPassValidation(): Unit {
        let source = configOf([
            ('fdbm_db', 'name0@h1:9001'),
            ('fdbm_db_driver_name0', 'mysql'),
            ('fdbm_db_database_name0', 'db0'),
            ('fdbm_partition__orders', 'db0,hash,id'),
            ('fdbm_global__dict', 'db0')
        ])
        FdbmConfig.validate(FdbmSettings.load(source: source), [], [], source: source)
    }
}

/** 构造内存配置源（键值成对给出）。 */
func configOf(entries: Array<(String, String)>): MapConfigSource {
    let values = HashMap<String, String>()
    for ((key, value) in entries) {
        values[key] = value
    }
    MapConfigSource(values)
}

/** 执行并取 `FdbmException.code`；没抛或不是该异常时返回 `INTERNAL`。 */
func fdbmCodeOf<T>(body: () -> T): DbdErrorCode {
    try {
        body()
    } catch (e: FdbmException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}
