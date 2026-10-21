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
package fountain::f_dbd.driver

import std.collection.Map
import std.database.sql.*
import std.database.sql.{DriverManager, SqlOption}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_version.FountainVersion
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.UpdateResultPayload

/** Step 3.2 `DbdDriver`（设计 §5.2）：注册、元信息与"open 不建链"。 */
@Test
public class DbdDriverTest {

    /** 注册名 = `dbd_driverName`（显式配置，不依赖外部 env），且元信息符合设计。 */
    @TestCase
    public func registersItself(): Unit {
        Config.set([('dbd_driverName', 'postgres')])
        let driver = dbdDriver()
        @Assert(driver.name, 'postgres')
        @Assert(driver.preferredPooling, true)
        @Assert(driver.version, FountainVersion)
        match (DriverManager.getDriver('postgres')) {
            case Some(found) => @Assert(found.name, 'postgres')
            case None => @Assert(false, true)
        }
    }

    /** G01：非法、0、负数超时都保留原值，`copy()` 返回独立副本。 */
    @TestCase
    public func illegalTimeoutKeepsPreviousValue(): Unit {
        let options = DbdOptions()
        options.apply(SqlOption.QueryTimeout, '30000')
        @Assert(options.queryTimeout.getOrThrow(), Duration.millisecond * 30000)
        options.apply(SqlOption.QueryTimeout, '30s')
        @Assert(options.queryTimeout.getOrThrow(), Duration.millisecond * 30000)
        options.apply(SqlOption.QueryTimeout, '0')
        @Assert(options.queryTimeout.getOrThrow(), Duration.millisecond * 30000)
        options.apply(SqlOption.QueryTimeout, '-1')
        @Assert(options.queryTimeout.getOrThrow(), Duration.millisecond * 30000)

        let cloned = options.copy()
        cloned.apply(SqlOption.QueryTimeout, '1000')
        @Assert(cloned.queryTimeout.getOrThrow(), Duration.millisecond * 1000)
        @Assert(options.queryTimeout.getOrThrow(), Duration.millisecond * 30000)
    }

    /** `open` 只解析 URL，不建立任何 TCP；一个没有监听者的端口也能立即返回。 */
    @TestCase
    public func openParsesWithoutConnecting(): Unit {
        let datasource = dbdDriver().open('fdbm://u:p@127.0.0.1:${freePort()}/db0', [])
        @Assert(datasource is DbdDatasource, true)
        @Assert(datasource.isClosed(), false)
        datasource.close()
        @Assert(datasource.isClosed(), true)
    }

    /** `opts` 里的 `username` / `password` 覆盖 URL 里的凭据（metadata 可见，且不含密码）。 */
    @TestCase
    public func optionsOverrideCredentials(): Unit {
        let stub = StubFdbm()
        let datasource = dbdDriver().open(stub.url(user: 'urluser', password: 'urlpass'),
            [('username', 'optuser'), ('password', 'optpass')])
        try {
            let connection = datasource.connect()
            try {
                let meta = connection.getMetaData()
                @Assert(metaValue(meta, 'user'), 'optuser')
                match (meta.get('url')) {
                    case Some(url) =>
                        @Assert(url.contains('***'), true)
                        @Assert(url.contains('optpass'), false)
                        @Assert(url.contains('urlpass'), false)
                    case None => @Assert(false, true)
                }
            } finally {
                connection.close()
            }
        } finally {
            datasource.close()
            stub.close()
        }
    }

    /** 非法 URL → `CONFIG`（不留给下层去猜）。 */
    @TestCase
    public func illegalUrlIsConfigError(): Unit {
        @Assert(codeOf { dbdDriver().open('not-a-url', []) }, DbdErrorCode.CONFIG)
        @Assert(codeOf { dbdDriver().open('fdbm://host', []) }, DbdErrorCode.CONFIG)
        @Assert(codeOf { dbdDriver().open('fdbm://:9000/db0', []) }, DbdErrorCode.CONFIG)
    }
}

/** Step 3.3 `DbdDatasource`（设计 §5.3）：惰性建链、选项表与幂等关闭。 */
@Test
public class DbdDatasourceTest {

    /** 构造只保存配置：对端不在线也能构造成功，`connect()` 才建链。 */
    @TestCase
    public func constructionDoesNotConnect(): Unit {
        let datasource = DbdDatasource(DbdUrl.parse('fdbm://u:p@127.0.0.1:${freePort()}/db0'))
        @Assert(datasource.isClosed(), false)
        datasource.close()
    }

    /** 桩在线 → `Connected`，且返回的连接可直接 prepare。 */
    @TestCase
    public func connectToOnlineStub(): Unit {
        let stub = StubFdbm()
        let datasource = DbdDatasource(DbdUrl.parse(stub.url()))
        try {
            let connection = datasource.connect()
            try {
                @Assert(connection.state == ConnectionState.Connected, true)
                @Assert(connection.prepareStatement('select 1') is DbdStatement, true)
            } finally {
                connection.close()
            }
        } finally {
            datasource.close()
            stub.close()
        }
    }

    /** 桩离线（配了 `connection_timeout` 时按 PING 计时）→ `IO`，不把不可用链路当可用。 */
    @TestCase
    public func connectToOfflinePortIsIoError(): Unit {
        let datasource = DbdDatasource(DbdUrl.parse('fdbm://u:p@127.0.0.1:${freePort()}/db0'))
        datasource.setOption(SqlOption.ConnectionTimeout, '500')
        @Assert(codeOf { datasource.connect() }, DbdErrorCode.IO)
    }

    /** `close()` 之后 `connect()` → `CONFIG`（已关闭的数据源不再产生连接）。 */
    @TestCase
    public func connectAfterCloseIsConfigError(): Unit {
        let datasource = DbdDatasource(DbdUrl.parse('fdbm://u:p@127.0.0.1:${freePort()}/db0'))
        datasource.close()
        @Assert(datasource.isClosed(), true)
        @Assert(codeOf { datasource.connect() }, DbdErrorCode.CONFIG)
    }

    /** 关闭数据源不影响已建连接（各自持有自己的传输）。 */
    @TestCase
    public func closeDoesNotAffectLiveConnections(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(1, 0))})
        let datasource = DbdDatasource(DbdUrl.parse(stub.url()))
        let connection = datasource.connect()
        try {
            datasource.close()
            @Assert(datasource.isClosed(), true)
            // 连接仍然可用
            @Assert(connection.prepareStatement('update t set a = 1').update().rowCount, 1)
        } finally {
            connection.close()
            stub.close()
        }
        // 幂等
        datasource.close()
        @Assert(datasource.isClosed(), true)
    }

    /** 未知选项被忽略（上层可能透传与本驱动无关的 key），不抛异常。 */
    @TestCase
    public func unknownOptionIsIgnored(): Unit {
        let datasource = DbdDatasource(DbdUrl.parse('fdbm://u:p@127.0.0.1:${freePort()}/db0'))
        datasource.setOption('some_other_pool_option', 'x')
        datasource.setOption(SqlOption.FetchRows, '7')
        datasource.close()
    }

    /** `query_timeout` 传到连接：桩不回包时按它超时（并让传输 fail-fast）。 */
    @TestCase
    public func queryTimeoutPropagatesToRequests(): Unit {
        let stub = StubFdbm()
        let datasource = DbdDatasource(DbdUrl.parse(stub.url()))
        datasource.setOption(SqlOption.QueryTimeout, '300')
        let connection = datasource.connect()
        try {
            let statement = connection.prepareStatement('select 1')
            @Assert(codeOf { statement.query() }, DbdErrorCode.TIMEOUT)
            @Assert(connection.state == ConnectionState.Broken, true)
        } finally {
            connection.close()
            datasource.close()
            stub.close()
        }
    }
}

/** 取 metadata 的可读值（缺键返回空串，便于直接断言）。 */
func metaValue(meta: Map<String, String>, key: String): String {
    match (meta.get(key)) {
        case Some(value) => value
        case None => ''
    }
}
