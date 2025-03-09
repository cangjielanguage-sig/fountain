/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm.wrap

import std.regex.Regex
import std.collection.HashMap
import std.collection.concurrent.ConcurrentHashMap
import config.Config
import fountain.regex.*

public class ORMConfig {
    private static const confPrefix = "fountain.orm"
    public static let connectionUrl = "${confPrefix}.connection.url"
    public static let transactionIncluding = "${confPrefix}.transaction.including"
    public static let transactionExcluding = "${confPrefix}.transaction.excluding"
    public static let transactionPropagation = "${confPrefix}.transaction.propagation"
    public static let transactionLevel = "${confPrefix}.transaction.level"
    public static let transactionAccessMode = "${confPrefix}.transaction.access.mode"
    public static let transactionDeferrableMode = "${confPrefix}.transaction.deferrable.mode"
    public static let useCache = "${confPrefix}.useCache"
    public static let databasePoolInitSize = "${confPrefix}.database.pool.init.size"
    public static let databasePoolMinSize = "${confPrefix}.database.pool.min.size"
    public static let databasePoolMaxSize = "${confPrefix}.database.pool.max.size"
    public static let databasePoolCheckPeriod = "${confPrefix}.database.pool.check.period"
    public static let databasePoolCreationRetries = "${confPrefix}.database.pool.creation.retries"
    public static let databasePoolCheckSql = "${confPrefix}.database.pool.check.sql"
    public static let stdPoolIdleTimeout = "${confPrefix}.pooled.datasource.idleTimeout"
    public static let stdPoolMaxLifeTime = "${confPrefix}.pooled.datasource.maxLifeTime"
    public static let stdPoolConnectionTimeout = "${confPrefix}.pooled.datasource.connectionTimeout"
    public static let stdPoolKeepaliveTime = "${confPrefix}.pooled.datasource.keepaliveTime"
    public static let stdPoolMaxSize = "${confPrefix}.pooled.datasource.maxSize"
    public static let stdPoolMaxIdleSize = "${confPrefix}.pooled.datasource.maxIdleSize"

    private static let dot = Regex(#"\."#)
    private static let BLANK_SPLITTOR = Regex(#"\s*,\s*"#)

    public static let instance = ORMConfig()

    private let converterMap = ConcurrentHashMap<String, Any>()
    private var transactionIncludingRegex = None<Regex>
    private var transactionExcludingRegex = None<Regex>
    private let cfg = Config.instance
    private init() {
        Config.appendPrefix(confPrefix)
        refresh {
            if (let Some(reg) <- cfg.getConf(transactionIncluding)) {
                transactionIncludingRegex = Regex(reg)
            }
            if (let Some(reg) <- cfg.getConf(transactionExcluding)) {
                transactionExcludingRegex = Regex(reg)
            }
        }
    }
    public func refresh(fn: () -> Unit): Unit {
        cfg.refresh(confPrefix, fn)
        cfg.refresh()
        fn()
    }
    public func getMonitorInterval(): Option<Int64> {
        cfg.getMonitorInterval()
    }
    public func registerConverter<D, T>(name: String, converter: (D) -> T) {
        converterMap[name] = converter
    }
    public func getConverter<D, T>(name: String): (D) -> T {
        (converterMap[name] as (D) -> T).getOrThrow()
    }
    public func getAllConfigs(driverName!: String = String.empty): Array<(String, String)> {
        var keys = cfg.getAllNames(confPrefix)
        let confs = HashMap<String, String>()
        var i = 0
        while (i < keys.size) {
            let key = keys[i]
            confs[key["${confPrefix}.".size..]] = cfg.getConf(key) ?? String.empty
            i++
        }
        if (!driverName.isEmpty()) {
            keys = cfg.getAllNames("${driverName}.${confPrefix}")
            i = 0
            while (i < keys.size) {
                let key = keys[i]
                confs[key["${driverName}.${confPrefix}".size..]] = cfg.getConf(key) ?? String.empty
                i++
            }
        }
        Array<(String, String)>(confs)
    }
    public func getUseCache(driverName!: String = String.empty): ?Bool {
        match (getConf(driverName: driverName, key: useCache)) {
            case Some(x) => Bool.parse(x)
            case _ where !driverName.isEmpty() => getUseCache()
            case _ => None<Bool>
        }
    }
    public func getConf(driverName!: String = String.empty, key!: String): ?String {
        if (driverName.isEmpty()) {
            cfg.getConf(key)
        } else if (let Some(x) <- cfg.getConf("${driverName}.${key}")) {
            x
        } else {
            cfg.getConf(key)
        }
    }
    public func getUrl(driverName!: String = String.empty): String {
        match (getConf(driverName: driverName, key: connectionUrl)) {
            case Some(x) => x
            case _ where !driverName.isEmpty() => getUrl()
            case _ => throw ORMException(
                "connection url for ${driverName} is not be configed, config which key is ${driverName}.${connectionUrl} or ${connectionUrl} must be specified"
            )
        }
    }

    public func getPoolInitSize(driverName!: String = String.empty): Int64 {
        match (getConf(driverName: driverName, key: databasePoolInitSize)) {
            case Some(x) => Int64.parse(x)
            case _ where !driverName.isEmpty() => getPoolInitSize()
            case _ => 10
        }
    }
    public func getPoolMinSize(driverName!: String = String.empty): Int64 {
        match (getConf(driverName: driverName, key: databasePoolMinSize)) {
            case Some(x) => Int64.parse(x)
            case _ where !driverName.isEmpty() => getPoolMinSize()
            case _ => 10
        }
    }
    public func getPoolMaxSize(driverName!: String = String.empty): Int64 {
        match (getConf(driverName: driverName, key: databasePoolMaxSize)) {
            case Some(x) => Int64.parse(x)
            case _ where !driverName.isEmpty() => getPoolMaxSize()
            case _ => 10
        }
    }
    public func getPoolCheckPeriod(driverName!: String = String.empty): Duration {
        match (getConf(driverName: driverName, key: databasePoolCheckPeriod)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ where !driverName.isEmpty() => getPoolCheckPeriod()
            case _ => Duration.second
        }
    }
    public func getPoolCreationRetries(driverName!: String = String.empty): Int64 {
        match (getConf(driverName: driverName, key: databasePoolCreationRetries)) {
            case Some(x) => Int64.parse(x)
            case _ where !driverName.isEmpty() => getPoolCreationRetries()
            case _ => 1
        }
    }
    public func getPoolCheckSql(driverName!: String = String.empty): String {
        match (getConf(driverName: driverName, key: databasePoolCheckSql)) {
            case Some(x) => x
            case _ where !driverName.isEmpty() => getPoolCheckSql()
            case _ => "select 1"
        }
    }

    public func transactionable(funcName: String): Bool {
        (transactionIncludingRegex?.matched(funcName) ?? true) &&
            !(transactionExcludingRegex?.matched(funcName) ?? false)
    }
    public func getTransactionPropagation(driverName!: String = String.empty): Propagation {
        match (getConf(driverName: driverName, key: transactionPropagation)) {
            case Some(x) => match (x) {
                case "Required" | "required" | "REQUIRED" => Required
                case "Supports" | "supports" | "SUPPORTS" => Supports
                case "Mandatory" | "mandatory" | "MANDATORY" => Mandatory
                case "RequiresNew" | "requires_new" | "REQUIRES_NEW" | "requires-new" | "REQUIRES-NEW" | "requiresNew" => RequiresNew
                case "Never" | "never" | "NEVER" => Never
                case "NotSupported" | "not_supported" | "not-supported" | "NOT_SUPPORTED" | "NOT-SUPPORTED" | "notSupported" => NotSupported
                case "Nested" | "nested" | "NESTED" => Nested
                case x => throw IllegalArgumentException("${x} is not llegal transaction propagation")
            }
            case _ => Required
        }
    }
    public func getTransactionLevel(driverName!: String = String.empty): ?TransactionIsoLevel {
        match (getConf(driverName: driverName, key: transactionLevel)) {
            case Some(x) => match (x) {
                case "Default" | "default" | "DEFAULT" => Unspecified
                case "Unspecified" | "unspecified" | "UNSPECIFIED" => Unspecified
                case "ReadCommitted" | "READ_COMMITTED" | "read_committed" | "read-committed" | "READ-COMMITTED" | "readCommitted" => ReadCommitted
                case "ReadUncommitted" | "READ_UNCOMMITTED" | "read_uncommitted" | "read-uncommitted" | "READ-UNCOMMITTED" | "readUncommitted" => ReadUncommitted
                case "RepeatableRead" | "REPEATABLE_READ" | "REPEATABLE-READ" | "repeatable_read" | "repeatable-read" | "repeatableRead" => RepeatableRead
                case "Snapshot" | "SNAPSHOT" | "snapshot" => Snapshot
                case "Serializable" | "SERIALIZABLE" | "serializable" => Serializable
                case "Linearizable" | "linearizable" | "LINEARIZABLE" => Linearizable
                case "Chaos" | "chaos" | "CHAOS" => Chaos
                case x => throw IllegalArgumentException("${x} is not llegal transaction level")
            }
            case _ where !driverName.isEmpty() => getTransactionLevel()
            case _ => None<TransactionIsoLevel>
        }
    }
    public func getTransactionAccessMode(driverName!: String = String.empty): ?TransactionAccessMode {
        match (getConf(driverName: driverName, key: transactionAccessMode)) {
            case Some(x) => match (x) {
                case "Default" | "default" | "DEFAULT" => Unspecified
                case "Unspecified" | "unspecified" | "UNSPECIFIED" => Unspecified
                case "ReadWrite" | "read_write" | "READ_WRITE" | "READ-WRITE" | "read-write" | "readWrite" => ReadWrite
                case "ReadOnly" | "read_only" | "READ_ONLY" | "read-only" | "READ-ONLY" | "readOnly" => ReadOnly
                case _ => throw IllegalArgumentException()
            }
            case _ where !driverName.isEmpty() => getTransactionAccessMode()
            case _ => None<TransactionAccessMode>
        }
    }
    public func getTransactionDeferrableMode(driverName!: String = String.empty): ?TransactionDeferrableMode {
        match (getConf(driverName: driverName, key: transactionDeferrableMode)) {
            case Some(x) => match (x) {
                case "Default" | "default" | "DEFAULT" => Unspecified
                case "Unspecified" | "unspecified" | "UNSPECIFIED" => Unspecified
                case "Deferrable" | "deferrable" | "DEFERRABLE" => Deferrable
                case "NotDeferrable" | "not_deferrable" | "not-deferrable" | "NOT_DEFERRABLE" | "NOT-DEFERRABLE" | "notDeferrable" => NotDeferrable
                case _ => throw IllegalArgumentException()
            }
            case _ where !driverName.isEmpty() => getTransactionDeferrableMode()
            case _ => None<TransactionDeferrableMode>
        }
    }
    public func registerSqlDataToDataConverter(driverName: String, converter: (SqlDbType) -> AnyData) {
        RowWrap.registerSqlDataToDataConverter(driverName, converter)
    }

    public func getStdPoolIdleTimeout(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolIdleTimeout)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ => None
        }
    }
    public func getStdPoolMaxLifeTime(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolMaxLifeTime)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ => None
        }
    }
    public func getStdPoolConnectionTimeout(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolConnectionTimeout)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ => None
        }
    }
    public func getStdPoolKeepaliveTime(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolKeepaliveTime)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ => None
        }
    }
    public func getStdPoolMaxSize(driverName!: String = String.empty): ?Int32 {
        match (getConf(driverName: driverName, key: stdPoolMaxSize)) {
            case Some(x) => Int32.parse(x)
            case _ => None
        }
    }
    public func getStdPoolMaxIdleSize(driverName!: String = String.empty): ?Int32 {
        match (getConf(driverName: driverName, key: stdPoolMaxIdleSize)) {
            case Some(x) => Int32.parse(x)
            case _ => None
        }
    }
}
