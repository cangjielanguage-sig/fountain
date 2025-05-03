/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

import std.collection.concurrent.ConcurrentHashMap
import std.database.sql.*
import std.env
import std.process.Process
import f_base.*
import f_config.Config
import f_log.*
import f_pool.PoolException
import f_orm.exception.ORMException
public import f_exception.{BaseException, UnreachableException}
public import f_orm.wrap.*
public import f_orm.exception.*

//事务维持在连接内，要在一个事务内完成的数据库访问应确保使用一个连接
public class ORM {
    private static let logger = LoggerFactory.getLogger<ORM>()
    private static var default = String.empty
    private static let datasources = ConcurrentHashMap<String, Datasource>()
    static let hooks = TransactionHooks()

    public static func registerTransactionHook<T>(hook: T): Unit where T <: TransactionHook {
        hooks.register<T>(hook)
    }

    public static func register(datasource: NamedDatasource, default!: Bool = true): Unit {
        if (datasources.isEmpty()) {
            env.atExit {
                for ((_, datasource) in datasources.iterator()) {
                    datasource.close()
                }
            }
        }
        if (default) {
            ORM.default = datasource.driverName
        }
        datasources[datasource.driverName] = datasource
    }
    public static func register(creator: DatasourceCreator, default!: Bool = true): Unit {
        let ds = creator.create()
        register(ds, default: default)
    }
    public static func register(driver: Driver, default!: Bool = true, needPool!: Bool = true): Unit {
        DriverManager.register(driver.name, driver)
        register(NamedDatasource.new(driver, needPool: needPool), default: default)
    }
    public static func deregister(name: String): Unit {
        datasources.remove(name)?.close()
        if (name == default) {
            default = String.empty
        }
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
        if(name.isEmpty()){
            datasources[default].connect()
        }else{
            datasources[name].connect()
        }
    }
    public static func executor(driverName: String): SqlExecutor {
        if(driverName.isEmpty()){
            SqlExecutor.getInstance(default)
        }else{
            SqlExecutor.getInstance(driverName)
        }
    }
    public static func executor(): SqlExecutor {
        hasDefault()
        executor(default)
    }
}
