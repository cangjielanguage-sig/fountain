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

import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_version.FountainVersion
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.exception.DbdException

/** Step 4.1 `MultiDConfig`（设计 §6.1）：14 个 getter 的取值、单位与解析规则。 */
@Test
public class MultiDConfigTest {

    /** 显式配置 → 逐项解析（时间项按需求单位换算）。 */
    @TestCase
    public func readsExplicitValues(): Unit {
        Config.set([
            ('multidbm_loadbalance', 'roundrobin,1,2,3'),
            ('multidbm_databasePoolInitSize', '2'),
            ('multidbm_databasePoolMinSize', '3'),
            ('multidbm_databasePoolMaxSize', '9'),
            ('multidbm_databasePoolCheckOnCreation', 'true'),
            ('multidbm_databasePoolCheckOnBorrowing', 'false'),
            ('multidbm_databasePoolCheckOnReturning', 'true'),
            ('multidbm_databasePoolIdleTimeout', '5'),
            ('multidbm_databasePoolConnectionLife', '3600'),
            ('multidbm_databasePoolCheckInterval', '120'),
            ('multidbm_databasePoolConnectTimeout', '75'),
            ('multidbm_databasePoolMaxWaiting', '9000'),
            ('multidbm_databasePoolCheckSql', 'select 2')
        ])
        @Assert(MultiDConfig.getLoadBalance(), 'roundrobin')
        let weights = MultiDConfig.getWeights()
        @Assert(weights.size, 3)
        @Assert(weights[0], 1)
        @Assert(weights[2], 3)
        @Assert(MultiDConfig.getInitSize(), 2)
        @Assert(MultiDConfig.getMinSize(), 3)
        @Assert(MultiDConfig.getMaxSize(), 9)
        @Assert(MultiDConfig.getCheckOnCreation(), true)
        @Assert(MultiDConfig.getCheckOnBorrowing(), false)
        @Assert(MultiDConfig.getCheckOnReturning(), true)
        @Assert(MultiDConfig.getIdleTimeout(), Duration.second * 5)
        @Assert(MultiDConfig.getConnectionLife(), Duration.second * 3600)
        @Assert(MultiDConfig.getCheckInterval(), Duration.second * 120)
        @Assert(MultiDConfig.getConnectTimeout(), Duration.millisecond * 75)
        @Assert(MultiDConfig.getMaxWaiting(), Duration.millisecond * 9000)
        @Assert(MultiDConfig.getCheckSql(), 'select 2')
    }

    /** `loadbalance` 的三种写法：算法+权重 / 纯权重（算法取默认 random）/ 纯算法。 */
    @TestCase
    public func loadBalanceForms(): Unit {
        Config.set([('multidbm_loadbalance', 'random,1,2,3')])
        @Assert(MultiDConfig.getLoadBalance(), 'random')
        @Assert(MultiDConfig.getWeights().size, 3)

        Config.set([('multidbm_loadbalance', '1,2,3')])
        @Assert(MultiDConfig.getLoadBalance(), 'random')
        @Assert(MultiDConfig.getWeights().size, 3)

        Config.set([('multidbm_loadbalance', 'roundrobin')])
        @Assert(MultiDConfig.getLoadBalance(), 'roundrobin')
        @Assert(MultiDConfig.getWeights().size, 0)

        Config.set([('multidbm_loadbalance', '')])
        @Assert(MultiDConfig.getLoadBalance(), 'random')
        @Assert(MultiDConfig.getWeights().size, 0)
    }

    /** 非法值 → 回落默认值（配置写错不该让驱动起不来）。 */
    @TestCase
    public func illegalValuesFallBackToDefaults(): Unit {
        Config.set([
            ('multidbm_databasePoolInitSize', 'abc'),
            ('multidbm_databasePoolMinSize', ''),
            ('multidbm_databasePoolMaxSize', 'x'),
            ('multidbm_databasePoolCheckOnCreation', 'yes'),
            ('multidbm_databasePoolCheckOnReturning', 'no'),
            ('multidbm_databasePoolIdleTimeout', 'NaN'),
            ('multidbm_databasePoolConnectionLife', 'NaN'),
            ('multidbm_databasePoolCheckInterval', 'NaN'),
            ('multidbm_databasePoolConnectTimeout', 'NaN'),
            ('multidbm_databasePoolMaxWaiting', 'NaN'),
            ('multidbm_databasePoolCheckSql', '')
        ])
        @Assert(MultiDConfig.getInitSize(), 1)
        @Assert(MultiDConfig.getMinSize(), 1)
        @Assert(MultiDConfig.getMaxSize(), 1)
        @Assert(MultiDConfig.getCheckOnCreation(), false)
        @Assert(MultiDConfig.getCheckOnReturning(), false)
        @Assert(MultiDConfig.getIdleTimeout(), Duration.Zero)
        @Assert(MultiDConfig.getConnectionLife(), Duration.second * 86400)
        @Assert(MultiDConfig.getCheckInterval(), Duration.second * 300)
        @Assert(MultiDConfig.getConnectTimeout(), Duration.millisecond * 50)
        @Assert(MultiDConfig.getMaxWaiting(), Duration.millisecond * 30000)
        @Assert(MultiDConfig.getCheckSql(), 'select 1')
    }

    /** `MaxWaiting = 0` → 真无限等待（`Duration.Max`）。 */
    @TestCase
    public func zeroMaxWaitingMeansInfinite(): Unit {
        Config.set([('multidbm_databasePoolMaxWaiting', '0')])
        @Assert(MultiDConfig.getMaxWaiting(), Duration.Max)
    }
}

/** Step 4.2 `MultiDUrl`（设计 §6.2）：多节点解析、双 scheme 与非法输入。 */
@Test
public class MultiDUrlTest {

    @TestCase
    public func parsesTwoNodesInOrder(): Unit {
        let url = MultiDUrl.parse('multidbm://u1:p1@h1:9001,u2:p2@h2:9002/db0')
        @Assert(url.nodes.size, 2)
        @Assert(url.database, 'db0')
        @Assert(url.nodes[0].user, 'u1')
        @Assert(url.nodes[0].password, 'p1')
        @Assert(url.nodes[0].host, 'h1')
        @Assert(url.nodes[0].port, 9001u16)
        @Assert(url.nodes[1].user, 'u2')
        @Assert(url.nodes[1].port, 9002u16)
    }

    /** `multidbd://` 与 `multidbm://` 等价。 */
    @TestCase
    public func acceptsBothSchemes(): Unit {
        let byName = MultiDUrl.parse('multidbd://h1:9001,h2:9002/db0')
        @Assert(byName.nodes.size, 2)
        @Assert(byName.nodes[1].port, 9002u16)
    }

    /** 单节点 / 缺省端口 / database 只取第一个路径段。 */
    @TestCase
    public func singleNodeAndPathSegments(): Unit {
        let single = MultiDUrl.parse('multidbm://localhost/db0/extra')
        @Assert(single.nodes.size, 1)
        @Assert(single.nodes[0].port, 8112u16)
        @Assert(single.database, 'db0')
    }

    /** 非法输入统一 `CONFIG`：缺库名、空库名、空节点、坏节点、外部 scheme。 */
    @TestCase
    public func illegalUrlsAreConfigErrors(): Unit {
        let illegal = [
            'multidbm://h1:9001',
            'multidbm://h1:9001/',
            'multidbm:///db0',
            'multidbm://:9001/db0',
            'multidbm://h1:9001,,h2:9002/db0',
            'fdbm://h1:9001/db0'
        ]
        for (url in illegal) {
            @Assert(codeOf { MultiDUrl.parse(url) }, DbdErrorCode.CONFIG)
            @Assert(MultiDUrl.tryParse(url).isNone(), true)
        }
    }
}

/** Step 4.3 `MultiD`（设计 §6.3）：注册、`preferredPooling` 与 scheme 分派。 */
@Test
public class MultiDTest {

    @TestCase
    public func registersItself(): Unit {
        let driver = multiDDriver()
        @Assert(driver.name, 'multidbd')
        @Assert(driver.preferredPooling, false)
        @Assert(driver.version, FountainVersion)
        match (DriverManager.getDriver('multidbd')) {
            case Some(found) => @Assert(found.name, 'multidbd')
            case None => @Assert(false, true)
        }
    }

    /** `open` 对两种 scheme 都返回 `MultiDatasource`；外部 scheme → `CONFIG`。 */
    @TestCase
    public func openAcceptsBothSchemes(): Unit {
        Config.set([
            ('multidbm_databasePoolInitSize', '0'),
            ('multidbm_databasePoolMaxSize', '1'),
            ('multidbm_databasePoolCheckOnBorrowing', 'false')
        ])
        let datasource = multiDDriver().open('multidbd://127.0.0.1:${freePortOf()}/db0', [])
        @Assert(datasource is MultiDatasource, true)
        datasource.close()

        @Assert(codeOf { multiDDriver().open('fdbm://127.0.0.1:8112/db0', []) }, DbdErrorCode.CONFIG)
    }
}

/** 取 `DbdException.code`；不是该异常时返回 `INTERNAL`。 */
func codeOf<T>(body: () -> T): DbdErrorCode {
    try {
        body()
    } catch (e: DbdException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}
