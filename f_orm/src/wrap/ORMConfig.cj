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
package fountain::f_orm.wrap

/**
 * orm_option_或<driverName>_orm_option_开头的配置项可以作为数据库驱动的初始化options，配置项名_option_后面的部分是驱动初始化key
 */
public class ORMConfig {
    public static const mockdb = 'mockdb'
    private static const confPrefix = "orm"
    public static const defaultDriver = confPrefix + "_defaultDriver"
    public static const drivers = confPrefix + "_drivers"
    public static const connectionUrl = confPrefix + "_connectionUrl"
    public static const transactionIncluding = confPrefix + "_transactionIncluding"
    public static const transactionExcluding = confPrefix + "_transactionExcluding"
    public static const transactionPropagation = confPrefix + "_transactionPropagation"
    public static const transactionLevel = confPrefix + "_transactionLevel"
    public static const transactionAccessMode = confPrefix + "_transactionAccessMode"
    public static const transactionDeferrableMode = confPrefix + "_transactionDeferrableMode"
    public static const transactionNoRollbackFor = confPrefix + "_transactionNoRollbackFor"
    public static const transactionRollbackFor = confPrefix + "_transactionRollbackFor"
    public static const useCache = confPrefix + "_useCache"
    public static const noPool = confPrefix + "_noPool"
    public static const useStdPool = confPrefix + "_useStdPool"
    public static const useThirdPartyPool = confPrefix + "_useThirdPartyPool"
    public static const databasePoolInitSize = confPrefix + "_databasePoolInitSize"
    public static const databasePoolMinSize = confPrefix + "_databasePoolMinSize"
    public static const databasePoolMaxSize = confPrefix + "_databasePoolMaxSize"
    public static const databasePoolCheckInterval = confPrefix + "_databasePoolCheckInterval"
    public static const databasePoolConnectTimeout = confPrefix + "_databasePoolConnectTimeout"
    public static const databasePoolIdleTimeout = confPrefix + "_databasePoolIdleTimeout"
    public static const databasePoolConnectionLife = confPrefix + "_databasePoolConnectionLife"
    public static const databasePoolCheckOnCreation = confPrefix + "_databasePoolCheckOnCreation"
    public static const databasePoolCheckOnBorrowing = confPrefix + "_databasePoolCheckOnBorrowing"
    public static const databasePoolCheckOnReturning = confPrefix + "_databasePoolCheckOnReturning"
    public static const databasePoolCheckSql = confPrefix + "_databasePoolCheckSql"
    public static const stdPoolIdleTimeout = confPrefix + "_stdPoolIdleTimeout"
    public static const stdPoolMaxLifeTime = confPrefix + "_pooledDatasourceMaxLifeTime"
    public static const stdPoolConnectionTimeout = confPrefix + "_stdPoolConnectionTimeout"
    public static const stdPoolKeepaliveTime = confPrefix + "_stdPoolKeepaliveTime"
    public static const stdPoolMaxSize = confPrefix + "_stdPoolMaxSize"
    public static const stdPoolMaxIdleSize = confPrefix + "_stdPoolMaxIdleSize"

    public static const transactionalFuncExecution = confPrefix + '_transactionalFuncExecution'

    public static const indexStartsWithZero = confPrefix + '_indexStartsWithZero'

    public static const sm4Operation = confPrefix + '_sm4Operation'
    public static const sm4Padding = confPrefix + '_sm4Padding'
    public static const sm4Key = confPrefix + '_sm4Key'
    public static const sm4Iv = confPrefix + '_sm4Iv'
    public static const sm4Aad = confPrefix + '_sm4Aad'
    public static const sm4TagSize = confPrefix + '_sm4TagSize'

    public static const ormOption = confPrefix + '_option_'

    private static let converterMap = ConcurrentHashMap<String, Any>()
    private static var transactionIncludingRegex = None<Regex>
    private static var transactionExcludingRegex = None<Regex>

    private static let sensitiveMap = ConcurrentHashMap<String, Array<Byte>>()

    static init() {
        refresh {
            if (let Some(reg) <- Config.getString(transactionIncluding)) {
                transactionIncludingRegex = Regex(reg)
            }
            if (let Some(reg) <- Config.getString(transactionExcluding)) {
                transactionExcludingRegex = Regex(reg)
            }
        }
    }
    public static func refresh(fn: () -> Unit): Unit {
        Config.refresher(confPrefix, fn)
        fn()
    }
    public static func registerConverter<D, T>(name: String, converter: (D) -> T) {
        converterMap[name] = converter
    }
    public static func getConverter<D, T>(name: String): (D) -> T {
        (converterMap[name] as (D) -> T).getOrThrow()
    }
    private static func sensitive2Str(bytes: Array<Byte>){
        if(let Some(sm4) <- getSM4()){
            bytes |> sm4.decrypt
        }else{
            bytes
        } |> String.fromUtf8
    }
    private static func getSensitive(driverName: String, key: String): String {
        let bytes = if(let Some(bytes) <- sensitiveMap.remove(key)){
            bytes
        }else if(let Some(bytes) <- sensitiveMap.remove(genKey(driverName, key))){
            bytes
        }else{
            return ''
        }
        if(bytes.size == 0){
            return ''
        }
        sensitive2Str(bytes)
    }
    public static func genKey(driverName: String, suffix: String): String {
        '${driverName}_${suffix}'
    }
    public static func getAllConfigs(driverName!: String = String.empty): Map<String, String> {
        let confMap = Config.getAll(confPrefix)
        if (!driverName.isEmpty()) {
            let driverConfs = Config.getAll(genKey(driverName, confPrefix))
            for ((k, v) in driverConfs) {
                confMap[k.replace(genKey(driverName, ''), '')] = v
            }
        }
        for((k, v) in sensitiveMap){
            let kk = if(let p <- genKey(driverName, '') && k.startsWith(p)){
                 k.replace(p, '')
            }else if(k.startsWith(genKey(confPrefix, ''))){
                k
            }else{
                continue
            }
            let view = confMap.entryView(kk)
            if(view.value.isNone()){
                view.value = sensitive2Str(v)
            }
        }
        confMap
    }
    private static func getAllConfigTupleIterator(driverName: String): Iterator<(String, String)>{
        getAllConfigs(driverName: driverName).iterator().filter{tpl => tpl[0].contains(ormOption)}.map{tpl =>
            var key = tpl[0]
            key = key[key.indexOf(ormOption).getOrThrow() + ormOption.size ..]
            (key, tpl[1])
        }
    }
    public static func getAllConfigTuples(driverName!: String = String.empty): Array<(String, String)> {
        getAllConfigTupleIterator(driverName).toArray()
    }
    public static func getOption(option: String, driverName!: String = String.empty): ?String {
        getAllConfigs(driverName: driverName).get('${ormOption}${option}')
    }
    public static func getUsername(driverName!: String = String.empty): ?String {
        getOption(SqlOption.Username, driverName: driverName)
    }
    public static func getPassword(driverName!: String = String.empty): ?String {
        getOption(SqlOption.Password, driverName: driverName)
    }
    public static func getUseCache(driverName!: String = String.empty): ?Bool {
        match (getConf(driverName: driverName, key: useCache)) {
            case Some(x) => Bool.parse(x)
            case _ where !driverName.isEmpty() => getUseCache()
            case _ => None<Bool>
        }
    }
    public static func getConf(driverName!: String = String.empty, key!: String): ?String {
        if (!driverName.isEmpty() && let Some(x) <- Config.getString(genKey(driverName, key))) {
            x
        } else {
            Config.getString(key)
        }
    }
    public static func getUseThirdPartyPool(driverName: String){
        get<Bool>(driverName: driverName, key: useThirdPartyPool, default: false)
    }
    private static func getDriverNameArray(): Array<String>{
        Config.getString(drivers)?.split(',') ?? []
    }
    public static func getDefaultDriver(): String {
        Config.getString(defaultDriver) ?? if(let drivers <- getDriverNameArray() && drivers.size > 0){
            drivers[0]
        }else{
            ''
        }
    }
    public static func isDefaultDriver(driver: String){
        getDefaultDriver() == driver
    }
    public static func isDefaultDriver(driver: Driver){
        isDefaultDriver(driver.name)
    }
    public static func getDriverNames(): Iterator<String>{
        getDriverNameArray().iterator()
    }
    protected static func getDriver(driverName: String){
        DriverManager.getDriver(driverName).getOrThrow{ORMException('database driver ${driverName} does not initialize')}
    }
    public static func getDrivers(): Iterator<Driver> {
        getDriverNames().map{d => getDriver(d)}
    }
    public static func getUrl(driverName!: String = String.empty): String {
        if(let url <- getSensitive(driverName, connectionUrl) && url.size > 0){
            return url
        }
        match (getConf(driverName: driverName, key: connectionUrl)) {
            case Some(x) => x
            case _ where !driverName.isEmpty() => getUrl()
            case _ => throw ORMException(
                "connection url for ${driverName} is not be configed, config which key is ${genKey(driverName, connectionUrl)} or ${connectionUrl} must be specified")
        }
    }
    private static func get<T>(driverName!: String = String.empty, key!: String, default!: T): T where T <: Parsable<T> {
        match (getConf(driverName: driverName, key: key)) {
            case Some(x) => T.parse(x)
            case _ => default
        }
    }

    public static func getNoPool(driverName!: String = String.empty){
        get<Bool>(driverName: driverName, key: noPool, default: false)
    }
    public static func getUseStdPool(driverName!: String = String.empty): Bool {
        get<Bool>(driverName: driverName, key: useStdPool, default: true)
    }
    public static func getPoolInitSize(driverName!: String = String.empty): Int64 {
        get<Int64>(driverName: driverName, key: databasePoolInitSize, default: 10)
    }
    public static func getPoolMinSize(driverName!: String = String.empty): Int64 {
        get<Int64>(driverName: driverName, key: databasePoolMinSize, default: 10)
    }
    public static func getPoolMaxSize(driverName!: String = String.empty): Int64 {
        get<Int64>(driverName: driverName, key: databasePoolMaxSize, default: 10)
    }
    public static func getCheckOnCreation(driverName!: String = String.empty): Bool {
        get<Bool>(driverName: driverName, key: databasePoolCheckOnCreation, default: false)
    }
    public static func getCheckOnBorrowing(driverName!: String = String.empty): Bool {
        get<Bool>(driverName: driverName, key: databasePoolCheckOnBorrowing, default: true)
    }
    public static func getCheckOnReturning(driverName!: String = String.empty): Bool {
        get<Bool>(driverName: driverName, key: databasePoolCheckOnReturning, default: false)
    }
    public static func getIdleTimeout(driverName!: String = String.empty): Duration {
        Duration.second * get<Int64>(driverName: driverName, key: databasePoolIdleTimeout, default: 0)
    }
    public static func getConnectionLife(driverName!: String = String.empty): Duration {
        Duration.second * get<Int64>(driverName: driverName, key: databasePoolConnectionLife, default: 3600)
    }
    public static func getPoolCheckInterval(driverName!: String = String.empty): Duration {
        Duration.second * get<Int64>(driverName: driverName, key: databasePoolCheckInterval, default: 300)
    }
    public static func getConnectTimeout(driverName!: String = String.empty): Duration {
        Duration.millisecond * get<Int64>(driverName: driverName, key: databasePoolConnectTimeout, default: 50)
    }
    public static func getPoolCheckSql(driverName!: String = String.empty, default!: String = 'select 1'): String {
        getConf(driverName: driverName, key: databasePoolCheckSql) ?? default
    }

    public static func transactionable(funcName: String): Bool {
        (transactionIncludingRegex?.matches(funcName) ?? true) &&
            !(transactionExcludingRegex?.matches(funcName) ?? false)
    }
    public static func getTransactionPropagation(driverName!: String = String.empty): Propagation {
        match (getConf(driverName: driverName, key: transactionPropagation)) {
            case Some(x) => match (x) {
                case "Required" | "required" | "REQUIRED" => Required
                case "Supports" | "supports" | "SUPPORTS" => Supports
                case "Mandatory" | "mandatory" | "MANDATORY" => Mandatory
                case "RequiresNew" | "requires_new" | "REQUIRES_NEW" | "requires-new" | "REQUIRES-NEW" | "requiresNew" => RequiresNew
                case "Never" | "never" | "NEVER" => Never
                case "NotSupported" | "not_supported" | "not-supported" | "NOT_SUPPORTED" | "NOT-SUPPORTED"
                    | "notSupported" => NotSupported
                case "Nested" | "nested" | "NESTED" => Nested
                case x => throw IllegalArgumentException("${x} is not llegal transaction propagation")
            }
            case _ => Required
        }
    }
    public static func getTransactionLevel(driverName!: String = String.empty): ?TransactionIsoLevel {
        match (getConf(driverName: driverName, key: transactionLevel)) {
            case Some(x) => match (x) {
                case "Default" | "default" | "DEFAULT" => Unspecified
                case "Unspecified" | "unspecified" | "UNSPECIFIED" => Unspecified
                case "ReadCommitted" | "READ_COMMITTED" | "read_committed" | "read-committed" | "READ-COMMITTED"
                    | "readCommitted" => ReadCommitted
                case "ReadUncommitted" | "READ_UNCOMMITTED" | "read_uncommitted" | "read-uncommitted"
                    | "READ-UNCOMMITTED" | "readUncommitted" => ReadUncommitted
                case "RepeatableRead" | "REPEATABLE_READ" | "REPEATABLE-READ" | "repeatable_read" | "repeatable-read"
                    | "repeatableRead" => RepeatableRead
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
    public static func getTransactionAccessMode(driverName!: String = String.empty): ?TransactionAccessMode {
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
    public static func getTransactionDeferrableMode(driverName!: String = String.empty): ?TransactionDeferrableMode {
        match (getConf(driverName: driverName, key: transactionDeferrableMode)) {
            case Some(x) => match (x) {
                case "Default" | "default" | "DEFAULT" => Unspecified
                case "Unspecified" | "unspecified" | "UNSPECIFIED" => Unspecified
                case "Deferrable" | "deferrable" | "DEFERRABLE" => Deferrable
                case "NotDeferrable" | "not_deferrable" | "not-deferrable" | "NOT_DEFERRABLE" | "NOT-DEFERRABLE"
                    | "notDeferrable" => NotDeferrable
                case _ => throw IllegalArgumentException()
            }
            case _ where !driverName.isEmpty() => getTransactionDeferrableMode()
            case _ => None<TransactionDeferrableMode>
        }
    }
    public static func getTransactionNoRollbackFor(driverName!: String = String.empty): ?String {
        getConf(driverName: driverName, key: transactionNoRollbackFor)
    }
    public static func getTransactionRollbackFor(driverName!: String = String.empty): ?String {
        getConf(driverName: driverName, key: transactionRollbackFor)
    }
    /**
     * 单位是秒
     */
    public static func getStdPoolIdleTimeout(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolIdleTimeout)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ => None
        }
    }
    /**
     * 单位是秒
     */
    public static func getStdPoolMaxLifeTime(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolMaxLifeTime)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ => None
        }
    }

    /**
     * 单位是微秒
     */
    public static func getStdPoolConnectionTimeout(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolConnectionTimeout)) {
            case Some(x) => Duration.microsecond * Int64.parse(x)
            case _ => None
        }
    }
    /**
     * 单位是秒
     */
    public static func getStdPoolKeepaliveTime(driverName!: String = String.empty): ?Duration {
        match (getConf(driverName: driverName, key: stdPoolKeepaliveTime)) {
            case Some(x) => Duration.second * Int64.parse(x)
            case _ => None
        }
    }
    public static func getStdPoolMaxSize(driverName!: String = String.empty): ?Int32 {
        match (getConf(driverName: driverName, key: stdPoolMaxSize)) {
            case Some(x) => Int32.parse(x)
            case _ => None
        }
    }
    public static func getStdPoolMaxIdleSize(driverName!: String = String.empty): ?Int32 {
        match (getConf(driverName: driverName, key: stdPoolMaxIdleSize)) {
            case Some(x) => Int32.parse(x)
            case _ => None
        }
    }
    public static func getIndexStartsWith(driverName!: String = String.empty): Int64 {
        let zero = get<Bool>(driverName: driverName, key: indexStartsWithZero, default: true)
        if(zero){
            0
        }else{
            1
        }
    }

    public static func getSM4(): ?SM4 {
        let operation = Config.getString(sm4Operation) ?? 'CBC'
        let padding = Config.getString(sm4Padding) ?? 'PKCS7Padding'
        let key = if(let Some(k) <- ((Config.getString(sm4Key) ?? '') |> fromHexString)){
            k
        }else{
            throw IllegalArgumentException("orm config item ${sm4Key} is not a legal hex string")
        }
        if(key.isEmpty()){
            return None<SM4>
        }
        let iv = ((Config.getString(sm4Iv) ?? '') |> fromHexString).getOrThrow{IllegalArgumentException("orm config item ${sm4Iv} is not a legal hex string")}
        let aad = ((Config.getString(sm4Aad) ?? '') |> fromHexString).getOrThrow{IllegalArgumentException("orm config item ${sm4Aad} is not a legal hex string")}
        let tagSize = Config.getValue<Int64>(sm4TagSize) ?? 16
        SM4(match(operation){
            case 'CBC' => OperationMode.CBC
            case 'CFB' => OperationMode.CFB
            case 'CTR' => OperationMode.CTR
            case 'GCM' => OperationMode.GCM
            case 'OFB' => OperationMode.OFB
            case _ => throw IllegalArgumentException("${operation} is not a legal sm4 OperationMode, and ECB is not safe to use, so it is not supported")
        }, key, iv: iv, paddingMode: match(padding){
            case 'NoPadding' => PaddingMode.NoPadding
            case 'PKCS7Padding' => PaddingMode.PKCS7Padding
            case _ => throw IllegalArgumentException("${padding} is not a legal sm4 PaddingMode, only NoPadding and PKCS7Padding are supported")
        }, aad: aad, tagSize: tagSize)
    }
    public static func registerSensitive(key: String, value: Array<Byte>): Unit {
        sensitiveMap[key] = value
    }
}
