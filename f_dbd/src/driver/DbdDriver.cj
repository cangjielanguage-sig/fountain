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
import fountain::f_version.FountainVersion
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.exception.DbdException

/** 驱动名（= URL 的 scheme = `DriverManager` 的 key）。 */
private const DRIVER_NAME: String = 'fdbm'

/**
 * fdbm 的单节点驱动（设计 §5.2）。
 *
 * 注册发生在包级 `static init`（动态库包初始化时触发），应用侧只要 import 到本包即可用
 * `DriverManager.getDriver('fdbm')` 取到它（与 `f_mockdb.MockDriver` 同构）。
 */
public class DbdDriver <: Driver {
    public init() {}

    static init() {
        DriverManager.register(DRIVER_NAME, DbdDriver())
    }

    public prop name: String {
        get() {
            DRIVER_NAME
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

/**
 * 取出注册名为 `'fdbm'` 的驱动；没注册到（包未初始化）时抛 `DbdException(CONFIG)`。
 *
 * 用例与 `f_orm` 都用它做入口，省掉"拿到 DriverManager 里那个实例"的样板。
 */
public func dbdDriver(): DbdDriver {
    match (DriverManager.getDriver(DRIVER_NAME)) {
        case Some(d) =>
            match (d) {
                case x: DbdDriver => x
                case _ => throw DbdException(DbdErrorCode.CONFIG,
                    'the driver registered as ${DRIVER_NAME} is not a DbdDriver')
            }
        case None => throw DbdException(DbdErrorCode.CONFIG, 'driver ${DRIVER_NAME} is not registered')
    }
}
