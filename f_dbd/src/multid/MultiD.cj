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

import std.database.sql.{Datasource, Driver, DriverManager}
import fountain::f_version.FountainVersion
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.exception.DbdException

/** 多节点驱动名（= URL 的 scheme 之一 = `DriverManager` 的 key）。 */
private const MULTID_NAME: String = 'multidbd'

/**
 * 多 fdbm 负载均衡驱动（设计 §6.3）。
 *
 * `preferredPooling = false`：`MultiDatasource` 内部已按节点建池，上层再池化只会套两层。
 * 注册发生在包级 `static init`（动态库包初始化时触发）。
 */
public class MultiD <: Driver {
    public init() {}

    static init() {
        DriverManager.register(MULTID_NAME, MultiD())
    }

    public prop name: String {
        get() {
            MULTID_NAME
        }
    }

    public prop preferredPooling: Bool {
        get() {
            false
        }
    }

    public prop version: String {
        get() {
            FountainVersion
        }
    }

    /** 解析连接串并构造 `MultiDatasource`；非法 URL 抛 `DbdException(CONFIG)`。 */
    public func open(connectionString: String, opts: Array<(String, String)>): Datasource {
        MultiDatasource(connectionString, opts: opts)
    }
}

/** 取出注册名为 `'multidbd'` 的驱动；没注册到（包未初始化）时抛 `DbdException(CONFIG)`。 */
public func multiDDriver(): MultiD {
    match (DriverManager.getDriver(MULTID_NAME)) {
        case Some(driver) =>
            match (driver) {
                case found: MultiD => found
                case _ => throw DbdException(DbdErrorCode.CONFIG,
                    'the driver registered as ${MULTID_NAME} is not a MultiD')
            }
        case None => throw DbdException(DbdErrorCode.CONFIG, 'driver ${MULTID_NAME} is not registered')
    }
}
