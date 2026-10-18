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

import std.database.sql.*
import std.env.exit
import fountain::f_config.Config
import fountain::f_log.LoggerFactory
import fountain::f_version.FountainVersion
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.exception.DbdException

/**
 * 驱动注册名 = 后端物理库的方言名（如 `postgres` / `mysql`）。
 *
 * fdbm 是代理，自身没有方言；f_orm 按驱动名选择方言。应用项目必须显式配置本项，
 * 否则 f_dbd 无法向 f_orm 暴露正确的方言，按约定记录 ERROR 后结束进程。
 * SQL 方言本身仍只在 fdbm 内处理（fdbm 启动时已掌握真实数据库信息）。
 */
private const NAME_KEY: String = 'dbd_driverName'
private let logger = LoggerFactory.getLogger('fountain::f_dbd.driver')

/**
 * fdbm 的单节点驱动（设计 §5.2）。
 *
 * 注册发生在包级 `static init`（动态库包初始化时触发），应用侧只要 import 到本包即可用
 * `DriverManager.getDriver('fdbm')` 取到它（与 `f_mockdb.MockDriver` 同构）。
 */
public class DbdDriver <: Driver {
    private let registeredName: String

    public init() {
        this.registeredName = configuredName()
    }

    public init(name: String) {
        this.registeredName = name
    }

    static init() {
        let name = configuredName()
        DriverManager.register(name, DbdDriver(name))
    }

    public prop name: String {
        get() {
            registeredName
        }
    }

    /**
     * `true`：一条 f_dbd 连接独占一条 TCP（含 f_net 的读写线程与心跳），
     * 交给上游 `f_dbpool.DatabasePool` / f_orm 池化最划算。
     */
    public prop preferredPooling: Bool {
        get() {
            true
        }
    }

    public prop version: String {
        get() {
            FountainVersion
        }
    }

    /**
     * 解析连接串与选项 → `DbdDatasource`；**不建任何网络连接**（`DbdDatasource.connect()` 才建链）。
     *
     * 非法 URL 抛 `DbdException(CONFIG)`；`opts` 里的 `username` / `password` 覆盖 URL 里的凭据。
     */
    public func open(connectionString: String, opts: Array<(String, String)>): Datasource {
        let parsed = DbdUrl.parse(connectionString)
        let ds = DbdDatasource(parsed)
        for ((k, v) in opts) {
            ds.setOption(k, v)
        }
        ds
    }
}

private func configuredName(): String {
    match (Config.getString(NAME_KEY)) {
        case Some(value) =>
            let name = value.trimAscii()
            if (name.isEmpty()) {
                missingName()
            } else {
                name
            }
        case None => missingName()
    }
}

private func missingName(): Nothing {
    let message = 'dbd_driverName is not configured. f_dbd is a proxy driver and cannot know ' +
        'the physical database dialect; set export dbd_driverName=<backend dialect> ' +
        '(for example postgres or mysql) so f_orm can select the matching SQL dialect. ' +
        'SQL dialect handling itself stays inside fdbm.'
    logger.error(message)
    // 应用未配置 f_log appender 时也保证错误可见
    eprintln('ERROR: ${message}')
    exit(1)
}

/**
 * 取出 `dbd_driverName` 对应的驱动；没注册到（包未初始化）时抛 `DbdException(CONFIG)`。
 *
 * 用例与 `f_orm` 都用它做入口，省掉"拿到 DriverManager 里那个实例"的样板。
 */
public func dbdDriver(): DbdDriver {
    let name = configuredName()
    match (DriverManager.getDriver(name)) {
        case Some(d) =>
            match (d) {
                case x: DbdDriver => x
                case _ => throw DbdException(DbdErrorCode.CONFIG,
                    'the driver registered as ${name} is not a DbdDriver')
            }
        case None => throw DbdException(DbdErrorCode.CONFIG, 'driver ${name} is not registered')
    }
}
