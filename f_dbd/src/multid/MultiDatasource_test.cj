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
package fountain::f_dbd.multid

import std.collection.ArrayList
import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_dbd.common.DbdErrorCode

/** Step 4.4 `MultiDatasource`（设计 §6.4）：权重分布、池的生命周期与错误映射。 */
@Test
public class MultiDatasourceTest {

    /** 轮询 2:1：100 次借还严格 67/33（步长 1、累计权重桶 [1,3]）。 */
    @TestCase
    public func roundRobinFollowsWeights(): Unit {
        useConfig('roundrobin,2,1')
        let first = MultiStub()
        let second = MultiStub()
        let datasource = MultiDatasource(twoNodeUrl(first, second))
        try {
            let counts = borrowAndCount(datasource, 100, [first, second])
            @Assert(counts[0], 67)
            @Assert(counts[1], 33)
        } finally {
            datasource.close()
            first.close()
            second.close()
        }
    }

    /** 只有 node1 有权重（`1,0`）→ 100 次全部落 node1（钉死"零权重节点不得覆盖前一桶"）。 */
    @TestCase
    public func zeroWeightNodeIsNeverChosen(): Unit {
        useConfig('roundrobin,1,0')
        let first = MultiStub()
        let second = MultiStub()
        let datasource = MultiDatasource(twoNodeUrl(first, second))
        try {
            let counts = borrowAndCount(datasource, 100, [first, second])
            @Assert(counts[0], 100)
            @Assert(counts[1], 0)
        } finally {
            datasource.close()
            first.close()
            second.close()
        }
    }

    /** 随机权重 2:1：统计上接近（容差宽，只防"永远命中一个节点"）。 */
    @TestCase
    public func randomFollowsWeights(): Unit {
        useConfig('random,2,1')
        let first = MultiStub()
        let second = MultiStub()
        let datasource = MultiDatasource(twoNodeUrl(first, second))
        try {
            let counts = borrowAndCount(datasource, 100, [first, second])
            @Assert(counts[0] >= 45 && counts[0] <= 85, true)
            @Assert(counts[1] >= 15 && counts[1] <= 55, true)
        } finally {
            datasource.close()
            first.close()
            second.close()
        }
    }

    /** 权重个数与节点数不符 / 全 0 / 未知算法 → 构造即 `CONFIG`。 */
    @TestCase
    public func invalidWeightsOrAlgorithmAreConfigErrors(): Unit {
        let first = MultiStub()
        let second = MultiStub()
        let url = twoNodeUrl(first, second)
        try {
            useConfig('1,2,3')
            @Assert(codeOf { MultiDatasource(url) }, DbdErrorCode.CONFIG)
            useConfig('0,0')
            @Assert(codeOf { MultiDatasource(url) }, DbdErrorCode.CONFIG)
            useConfig('bogus')
            @Assert(codeOf { MultiDatasource(url) }, DbdErrorCode.CONFIG)
        } finally {
            first.close()
            second.close()
        }
    }

    /** 池耗尽 → `TIMEOUT`；归还后可再借；`close()` 幂等且之后 `connect()` → `CONFIG`。 */
    @TestCase
    public func poolExhaustionAndClose(): Unit {
        useConfig('roundrobin,1', maxWaiting: '200')
        let stub = MultiStub()
        let datasource = MultiDatasource('multidbm://127.0.0.1:${stub.port}/db0')
        try {
            let borrowed = datasource.connect()
            @Assert(codeOf { datasource.connect() }, DbdErrorCode.TIMEOUT)
            borrowed.close()

            let again = datasource.connect()
            @Assert(again.prepareStatement('update t set a = 1').update().rowCount, 1)
            again.close()

            datasource.close()
            @Assert(datasource.isClosed(), true)
            datasource.close() // 幂等
            @Assert(codeOf { datasource.connect() }, DbdErrorCode.CONFIG)
        } finally {
            datasource.close()
            stub.close()
        }
    }

    /** `setOption` 转发到节点：`query_timeout` 在按需建连后生效（桩静默 → `TIMEOUT`）。 */
    @TestCase
    public func setOptionReachesNodeDatasources(): Unit {
        useConfig('roundrobin,1', maxWaiting: '500')
        let stub = MultiStub(respond: false)
        let datasource = MultiDatasource('multidbm://127.0.0.1:${stub.port}/db0')
        try {
            datasource.setOption(SqlOption.QueryTimeout, '300')
            let connection = datasource.connect()
            try {
                @Assert(codeOf { connection.prepareStatement('select 1').query() }, DbdErrorCode.TIMEOUT)
            } finally {
                connection.close()
            }
        } finally {
            datasource.close()
            stub.close()
        }
    }
}

/** 写一组确定的池/负载均衡配置（避免用例间顺序影响）。 */
func useConfig(loadBalance: String, maxWaiting!: String = '200'): Unit {
    Config.set([
        ('multidbm_loadbalance', loadBalance),
        ('multidbm_databasePoolInitSize', '0'),
        ('multidbm_databasePoolMinSize', '0'),
        ('multidbm_databasePoolMaxSize', '1'),
        ('multidbm_databasePoolCheckOnCreation', 'false'),
        ('multidbm_databasePoolCheckOnBorrowing', 'false'),
        ('multidbm_databasePoolCheckOnReturning', 'false'),
        ('multidbm_databasePoolConnectTimeout', maxWaiting),
        ('multidbm_databasePoolMaxWaiting', maxWaiting)
    ])
}

/** 两个节点（无凭据、随机端口）的 multid URL。 */
func twoNodeUrl(first: MultiStub, second: MultiStub): String {
    'multidbm://127.0.0.1:${first.port},127.0.0.1:${second.port}/db0'
}

/** 借还 `rounds` 次，每次执行一条更新；返回各节点收到的请求数（按节点顺序）。 */
func borrowAndCount(datasource: MultiDatasource, rounds: Int64, stubs: Array<MultiStub>): Array<Int64> {
    var i: Int64 = 0
    while (i < rounds) {
        let connection = datasource.connect()
        try {
            connection.prepareStatement('update t set a = 1').update()
        } finally {
            connection.close()
        }
        i += 1
    }
    let counts = ArrayList<Int64>()
    for (stub in stubs) {
        counts.add(stub.received())
    }
    counts.toArray()
}
