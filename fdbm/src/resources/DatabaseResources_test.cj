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
package fountain::fdbm.resources

import std.collection.HashMap
import std.database.sql.Connection
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.config.{DatabaseNodeConfig, LoadBalanceConfig, NodeWeight, PoolConfig}
import fountain::fdbm.exception.FdbmException
import fountain::f_mockdb.*

/** Step 4.1/4.2 `DatabaseResources`（设计 §5）：每库一池、读写权重与生命周期。 */
@Test
public class DatabaseResourcesTest {

    private func nodes(): Array<DatabaseNodeConfig> {
        [
            DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb', ['db0'], 'u0', 'p0'),
            DatabaseNodeConfig('name1', '127.0.0.1', 3307u16, 'mockdb', ['db0'], 'u1', 'p1')
        ]
    }

    private func poolConfig(): PoolConfig {
        PoolConfig(initSize: 0, minSize: 0, maxSize: 2, checkOnBorrowing: false,
            checkOnReturning: false, connectTimeout: Duration.second, maxWaiting: Duration.second)
    }

    /** G07：池耗尽等待超时 → `TIMEOUT`（不是冒泡成 INTERNAL）。 */
    @TestCase
    public func poolExhaustionMapsToTimeout(): Unit {
        let single = [DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb', ['db0'], '', '')]
        let pool = PoolConfig(initSize: 0, minSize: 0, maxSize: 1, checkOnBorrowing: false,
            checkOnReturning: false, connectTimeout: Duration.second,
            maxWaiting: Duration.millisecond * 50)
        let resources = DatabaseResources(single, pool, LoadBalanceConfig())
        try {
            let held = resources.selectRead('db0')
            @Assert(fdbmCodeOf { resources.selectRead('db0') }, DbdErrorCode.TIMEOUT)
            held.close()
            resources.selectRead('db0').close()
        } finally {
            resources.close()
        }
    }

    @TestCase
    public func readAndWriteAcrossTwoNodes(): Unit {
        let resources = DatabaseResources(nodes(), poolConfig(), LoadBalanceConfig())
        try {
            @Assert(resources.databases().size, 1)
            @Assert(resources.databases()[0], 'db0')
            @Assert(resources.contains('db0'), true)
            @Assert(resources.contains('db1'), false)
            @Assert(resources.readNodes('db0').size, 2)

            let read = resources.selectRead('db0')
            read.close()
            let write = resources.selectWrite('db0')
            write.close()

            let all = resources.selectAllWrite('db0')
            @Assert(all.size, 2)
            for (connection in all) {
                connection.close()
            }
        } finally {
            resources.close()
        }
    }

    @TestCase
    public func zeroWeightsExcludeNodes(): Unit {
        let weights = HashMap<String, NodeWeight>()
        weights['name0'] = NodeWeight(write: 1, read: 0)
        weights['name1'] = NodeWeight(write: 0, read: 1)
        let resources = DatabaseResources(nodes(), poolConfig(),
            LoadBalanceConfig(algorithm: 'roundrobin', weights: weights))
        try {
            @Assert(resources.readNodes('db0').size, 1)
            let read = resources.selectRead('db0')
            read.close()
            let all = resources.selectAllWrite('db0')
            @Assert(all.size, 1)
            all[0].close()
        } finally {
            resources.close()
        }
    }

    @TestCase
    public func missingReadNodeIsRouteFailed(): Unit {
        let weights = HashMap<String, NodeWeight>()
        weights['name0'] = NodeWeight(write: 1, read: 0)
        weights['name1'] = NodeWeight(write: 1, read: 0)
        let resources = DatabaseResources(nodes(), poolConfig(),
            LoadBalanceConfig(algorithm: 'random', weights: weights))
        try {
            @Assert(fdbmCodeOf { resources.selectRead('db0') }, DbdErrorCode.ROUTE_FAILED)
        } finally {
            resources.close()
        }
    }

    @TestCase
    public func closeIsIdempotentAndBlocksAccess(): Unit {
        let resources = DatabaseResources(nodes(), poolConfig(), LoadBalanceConfig())
        resources.close()
        @Assert(resources.isClosed(), true)
        resources.close()
        @Assert(resources.isClosed(), true)
        @Assert(fdbmCodeOf { resources.selectWrite('db0') }, DbdErrorCode.CONFIG)
        @Assert(resources.closeAndAwait(timeout: Duration.second), true)
    }
}

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
