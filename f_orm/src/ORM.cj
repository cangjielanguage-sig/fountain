/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_orm

import std.collection.concurrent.ConcurrentHashMap
import std.env
import f_orm.exception.ORMException
public import std.database.sql.*
public import std.reflect.*
public import f_exception.{BaseException, UnreachableException}
public import f_orm.wrap.*
public import f_orm.exception.*

/**
 * 事务维持在连接内，要在一个事务内完成的数据库访问应确保使用一个连接。
 * 应用项目应当有一个初始化文件用来调用ORM.register(...)完成初始化
 */
public class ORM {
    private static var default = String.empty
    private static let datasources = ConcurrentHashMap<String, NamedDatasource>()
    static let hooks = TransactionHooks()

    static init() {
        env.atExit(close)
    }

    public static func close() {
        for ((_, s) in datasources) {
            s.close()
        }
    }
    public static func registerTransactionHook<T>(hook: T): Unit where T <: TransactionHook {
        hooks.register<T>(hook)
    }

    public static func register(datasource: NamedDatasource, default!: Bool = true): Unit {
        if (default) {
            ORM.default = datasource.driverName
        }
        datasources[datasource.driverName] = datasource
    }
    public static func register(creator: DatasourceCreator, default!: Bool = true): Unit {
        let ds = creator.create()
        register(ds, default: default)
    }
    public static func register(driver: Driver, default!: Bool = true): Unit {
        register(NamedDatasource.new(driver), default: default)
    }
    public static func register(driver: Driver, url: String, opts: Array<(String, String)>, default!: Bool = true): Unit {
        let ds = driver.open(url, opts)
        let pool = PooledDatasource(ds)
        register(NamedDatasource(opts.size > 0, driver.name, pool), default: default)
    }
    public static func deregister(name: String): Unit {
        if(let Some(d) <- datasources.remove(name)){
            DriverManager.deregister(name)
            d.close()
        }
        if (name == default) {
            default = String.empty
        }
    }
    public static func deregisterAndReplaceDefault(newDefault: String): Unit {
        deregister(default)
        default = newDefault
    }
    public static prop databasesNames: Array<String> {
        get() {
            DriverManager.drivers()
        }
    }
    private static func hasDefault() {
        if (default == String.empty) {
            throw ORMException("default datasource is not specified")
        }
    }

    public static func connection(): Connection {
        hasDefault()
        connection(default)
    }
    public static func connection(name: String): Connection {
        if (name.isEmpty()) {
            datasources[default].connect()
        } else {
            datasources[name].connect()
        }
    }
    public static func executor(driverName: String): SqlExecutor {
        if (driverName.isEmpty()) {
            hasDefault()
            SqlExecutor.getInstance(default)
        } else {
            SqlExecutor.getInstance(driverName)
        }
    }
    public static func executor(): SqlExecutor {
        hasDefault()
        executor(default)
    }
}
