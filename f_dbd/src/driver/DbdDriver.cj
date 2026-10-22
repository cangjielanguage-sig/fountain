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
import fountain::f_config.Config
import fountain::f_log.LoggerFactory
import fountain::f_version.FountainVersion
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.exception.DbdException

/**
 * 驱动注册名 = 后端物理库的方言名（如 `postgres` / `mysql`）。
 *
 * fdbm 是代理，自身没有方言；f_orm 按驱动名选择方言。未配置时**不注册、不结束进程**：
 * 只用 MultiD 的进程不受影响，取用时由 [dbdDriver] / [DbdDriver] 抛 `DbdException(CONFIG)`。
 */
private const NAME_KEY: String = 'dbd_driverName'
private let logger = LoggerFactory.getLogger('fountain::f_dbd.driver')

/**
 * fdbm 的单节点驱动（设计 §5.2）。
 *
 * 注册发生在包级 `static init`（动态库包初始化时触发）；未配置时跳过注册，并在名字可用时
 * 额外注册兼容别名 `fdbm`（旧应用 `getDriver('fdbm')` 仍可用）。
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
        match (configuredNameOrNone()) {
            case Some(name) =>
                DriverManager.register(name, DbdDriver(name))
                if (name != 'fdbm' && DriverManager.getDriver('fdbm').isNone()) {
                    DriverManager.register('fdbm', DbdDriver('fdbm'))
                    logger.info('registered compatibility driver alias fdbm for ${name}')
                }
            case None =>
                logger.info('${NAME_KEY} is not configured; DbdDriver is not registered')
        }
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

private func configuredNameOrNone(): ?String {
    match (Config.getString(NAME_KEY)) {
        case Some(value) =>
            let name = value.trimAscii()
            if (name.isEmpty()) {
                None<String>
            } else {
                Some(name)
            }
        case None => None<String>
    }
}

private func missingNameError(): DbdException {
    DbdException(DbdErrorCode.CONFIG, '${NAME_KEY} is not configured. f_dbd is a proxy driver and ' +
        'cannot know the physical database dialect; set ${NAME_KEY}=<backend dialect> ' +
        '(for example postgres or mysql) so f_orm can select the matching SQL dialect. ' +
        'SQL dialect handling itself stays inside fdbm.')
}

/** 取配置的注册名；未配置 → `DbdException(CONFIG)`（进程继续运行）。 */
private func configuredName(): String {
    match (configuredNameOrNone()) {
        case Some(name) => name
        case None =>
            let error = missingNameError()
            logger.error(error.message)
            throw error
    }
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
        case None =>
            // 配置可能晚于包初始化写入（用例/嵌入式装配）：按需补注册，避免误报"未注册"
            let driver = DbdDriver(name)
            DriverManager.register(name, driver)
            driver
    }
}
