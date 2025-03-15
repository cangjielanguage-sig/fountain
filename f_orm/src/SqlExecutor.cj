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

import std.collection.HashMap
import f_collection.*
import f_data.*
import f_log.*
import f_orm.exception.*

public class SqlCacheKey <: Hashable & Equatable<SqlCacheKey> & ToString {
    private let h: Int64
    public SqlCacheKey(private let sql: String, private let args: SqlArgs) {
        h = HashBuilder().append(sql).append(args).finish()
    }
    public func hashCode(): Int64 {
        h
    }
    public operator func ==(other: SqlCacheKey): Bool {
        h == other.h && sql == other.sql && args == other.args
    }
    public func toString(): String {
        "${sql} | ${args}"
    }
}
public class SqlExecutor <: Resource & RootDAO {
    private static let logger = LoggerFactory.getLogger("fountain/orm.SqlExecutor")
    private static let blankRegex = Regex(#"\s{2,}"#)
    private static let current = ThreadLocal<HashMap<String, SqlExecutor>>()
    private var sql_ = String.empty
    private var args: SqlArgs = SqlArgs.empty
    private var hasRealTx = false
    private var _connection_: Connection
    private var tx = None<TransactionWrap>
    private let cache: Map<SqlCacheKey, Any>
    private var clearCache = false
    private let useCache: Bool

    private SqlExecutor(let driverName: String) {
        useCache = ORMConfig.getUseCache(driverName: driverName) ?? true
        cache = if (useCache) {
            HashMap<SqlCacheKey, Any>()
        } else {
            EmptyMap<SqlCacheKey, Any>.INSTANCE
        }
        _connection_ = getConnection(driverName)
    }

    private mut prop sql: String {
        get() {
            sql_
        }
        set(value) {
            sql_ = blankRegex.matcher(value).replaceAll(" ")
        }
    }

    static func getInstance(driverName: String): SqlExecutor {
        let em = current.getOrCompute{HashMap<String, SqlExecutor>()}
        let exe = if(let Some(e) <- em.get(driverName)) {
            e
        }else{
            let e = SqlExecutor(driverName)
            em[driverName] = e
            e
        }
        if(!(exe._connection_ is NoneConnection)){
            match(exe._connection_.state){
                case Closed => exe._connection_ = NoneConnection.instance
                case Broken =>
                    try{
                        exe._connection_.close()
                    }catch(_){}
                    exe._connection_ = NoneConnection.instance
                case _ => ()
            }
        }
        exe
    }

    /**
     * DAO接口必须声明相同的属性，不必真的提供实现。所有的DAO都是SqlExecutor的扩展
     */
    public prop executor: SqlExecutor {
        get() {
            this
        }
    }

    private static func getConnection(driverName: String) {
        ORM.connection(driverName)
    }
    public func isClosed(): Bool {
        _connection_.isClosed()
    }
    public func close(): Unit {
        if (let None <- this.tx) {
            current.get()?.remove(driverName)
            cache.clear()
            _connection_.close()
            _connection_ = NoneConnection.instance
        }
    }

    private func createTransaction(
        propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
        isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
        accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
        deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(
            driverName: driverName)
    ): TransactionWrap {
        func newDummyTx(
            mode!: DummyTransactionMode = Common,
            connection!: Connection = this.connection,
            suspend!: Bool = false,
            ex!: ?Exception = None
        ) {
            let tx = TransactionWrap(DummyTransaction(mode, ex), connection, suspend: suspend)
            tx.wrapping = this.tx
            this.tx = tx
        }
        match (propagation) {
            case Required =>
                //Support a current transaction, create a new one if none exists.
                try {
                if (!hasRealTx) {
                    if (let tx: TransactionWrap <- connection.createTransaction()) {
                        hasRealTx = true
                        tx.wrapping = this.tx
                        this.tx = tx
                    }
                } else {
                    newDummyTx()
                }
            } catch (e: Exception) {
                newDummyTx(mode: StartFailure, ex: e)
            }
            case Supports => //Support a current transaction, execute non-transactionally if none exists.
                newDummyTx()
            case Mandatory =>
                //Support a current transaction, throw an exception if none exists.
                newDummyTx(
                mode: if (hasRealTx) {
                    Common
                } else {
                    Mandatory
                }
            )
            case RequiresNew =>
                //Create a new transaction, and suspend the current transaction if one exists.
                try {
                let connection = if (hasRealTx) {
                    getConnection(driverName)
                } else {
                    this.connection
                }
                if (let tx: TransactionWrap <- connection.createTransaction()) {
                    tx.wrapping = this.tx
                    tx.suspend = hasRealTx
                    hasRealTx = true
                    this.tx = tx
                }
            } catch (e: Exception) {
                newDummyTx(mode: StartFailure, ex: e)
            }
            case NotSupported =>
                // Execute non-transactionally, suspend the current transaction if one exists.
                newDummyTx(
                connection: if (hasRealTx) {
                    getConnection(driverName)
                } else {
                    this.connection
                },
                suspend: hasRealTx
            )
            case Never =>
                //Execute non-transactionally, throw an exception if a transaction exists.
                newDummyTx(
                mode: if (hasRealTx) {
                    Never
                } else {
                    Common
                }
            )
            case Nested =>
                //Execute within a nested transaction if a current transaction exists, behave like REQUIRED otherwise.
                try {
                if (let tx: TransactionWrap <- connection.createTransaction()) {
                    tx.wrapping = this.tx
                    hasRealTx = true
                    this.tx = tx
                }
            } catch (e: Exception) {
                newDummyTx(mode: StartFailure, ex: e)
            }
        }
        let tx = this.tx.getOrThrow()
        if (let Some(lv) <- isoLevel) {
            tx.isoLevel = lv
        }
        if (let Some(mode) <- accessMode) {
            tx.accessMode = mode
        }
        if (let Some(mode) <- deferrableMode) {
            tx.deferrableMode = mode
        }
        this.tx.getOrThrow()
    }
    public func newTxAndBegin(
        propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
        isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
        accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
        deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(
            driverName: driverName)
    ): SqlExecutor {
        createTransaction(
            propagation: propagation,
            isoLevel: isoLevel,
            accessMode: accessMode,
            deferrableMode: deferrableMode
        ).begin()
        this
    }
    public func commit() {
        finishTransaction(false, false) {tx => tx.commit()}
    }
    public func rollback() {
        finishTransaction(true, false) {tx => tx.rollback()}
    }
    public func rollback(savepoint: String) {
        finishTransaction(false, true) {tx => tx.rollback(savepoint)}
    }
    private func finishTransaction(unwrapAnyway: Bool, withSavepoint: Bool, callback: (Transaction) -> Unit) {
        try {
            if (let Some(tx) <- this.tx) {
                try {
                    callback(tx)
                    if(!withSavepoint){
                        this.tx = tx.wrapping
                    }
                } catch (e: Exception) {
                    if (unwrapAnyway && !withSavepoint) {
                        this.tx = tx.wrapping
                    }
                    throw e
                } finally {
                    if (tx.suspend && !withSavepoint) {
                        try {
                            if (!tx.connection.isClosed()) {
                                tx.connection.close()
                                tx.connection = NoneConnection.instance
                            }
                        } catch (e: Exception) {
                            throw TransactionException(e)
                        }
                    }
                }
            }
        } finally {
            if (!isClosed()) {
                close()
            }
        }
    }
    public func noRollbackFor(e: Exception): Exception {
        try {
            commit()
        } catch (ex: Exception) {
            let re: BaseException
            match(ex){
                case x: BaseException =>
                    x.addSuppressed(e)
                    re = x
                case x =>
                    let txe = TransactionException(x)
                    txe.addSuppressed(e)
                    re = txe
            }
            try {
                rollback()
            } catch (e: Exception) {
                re.addSuppressed(e)
            }
            return re
        }
        return e
    }
    public func rollbackFor(e: Exception): Exception {
        try {
            rollback()
        } catch (ex: BaseException) {
            ex.addSuppressed(e)
            return ex
        } catch (ex: Exception) {
            let txe = TransactionException(ex)
            txe.addSuppressed(e)
            return txe
        }
        return e
    }

    /**
     * 执行本函数前必须先启动一个事务，然后执行callee，最后commit。
     * 本函数不执行回滚。
     */
    public func callAndCommit<T>(callee: () -> T): T {
        tx.getOrThrow {TransactionException("no transaction started")}
        let result = callee()
        commit()
        return result
    }
    public func save(savepoint: String) {
        tx?.save(savepoint)
    }
    public func release(savepoint: String) {
        tx?.release(savepoint)
    }
    private prop connection: Connection {
        get() {
            while (!(this._connection_ is NoneConnection)) {
                match (this._connection_.state) {
                    case Connecting => continue
                    case Connected => return this._connection_
                    case Closed => throw ORMException("connection is closed")
                    case Broken =>
                        try {
                            this._connection_.close()
                        } catch (_) {}
                        throw ORMException("connection is broken")
                }
            }
            this._connection_ = getConnection(driverName)
            this._connection_
        }
    }
    private func logMsg(duration: Duration): String {
        "${driverName} is executing a sql: ${sql}, args: ${args}, consumed: ${duration}"
    }
    private var start = DateTime.UnixEpoch
    private prop statement: Statement {
        get() {
            start = DateTime.now()
            let stmt = connection.prepareStatement(sql)
            stmt
        }
    }

    private prop updateOrDelete: Int64 {
        get() {
            execute<Int64> {r: UpdateResult => r.rowCount}
        }
    }
    public prop update: Int64 {
        get() {
            updateOrDelete
        }
    }
    public prop delete: Int64 {
        get() {
            updateOrDelete
        }
    }
    public prop insert: InsertResult {
        get() {
            execute<InsertResult> {r: UpdateResult => InsertResult(r)}
        }
    }

    private prop query: QueryResult {
        get() {
            execute<QueryResult> {
                statement.query(args.toArray())
            }
        }
    }

    public func singleFirst<T>(): Option<T> {
        singleFirst<T>(0)
    }
    public func singleFirst<T>(index: Int64): Option<T> {
        execute<Option<T>> {
            let wrap = (query as QueryResultWrap).getOrThrow()
            for (row in wrap) {
                let value = (row[index] as T).getOrThrow()
                return value
            }
            return None<T>
        }
    }
    public func singleFirst<T>(column: String): Option<T> {
        execute<Option<T>> {
            let wrap = (query as QueryResultWrap).getOrThrow()
            for (row in wrap) {
                let value = (row[column] as T).getOrThrow()
                return value
            }
            return None<T>
        }
    }
    public func singleList<T>(): ArrayList<T> {
        singleList<T>(0)
    }
    public func singleList<T>(index: Int64): ArrayList<T> {
        execute<ArrayList<T>> {
            let list = ArrayList<T>()
            let wrap = (query as QueryResultWrap).getOrThrow()
            for (row in wrap) {
                let value = (row[index] as T).getOrThrow()
                list.add(value)
            }
            return list
        }
    }
    public func singleList<T>(column: String): ArrayList<T> {
        execute<ArrayList<T>> {
            let list = ArrayList<T>()
            let wrap = (query as QueryResultWrap).getOrThrow()
            for (row in wrap) {
                let value = (row[column] as T).getOrThrow()
                list.add(value)
            }
            return list
        }
    }
    public func singleIterator<T>(): Iterator<T> {
        singleIterator<T>(0)
    }
    public func singleIterator<T>(index: Int64): Iterator<T> {
        execute<Iterator<T>> {
            match (query as QueryResultWrap) {
                case Some(x) => SingleColumnIterator<T>(x, index: index)
                case _ => EmptyIterator<T>.INSTANCE
            }
        }
    }
    public func singleIterator<T>(column: String): Iterator<T> {
        execute<Iterator<T>> {
            match (query as QueryResultWrap) {
                case Some(x) => SingleColumnIterator<T>(x, column: column)
                case _ => EmptyIterator<T>.INSTANCE
            }
        }
    }
    public func first<T>(mappers: QueryMappers<T>): Option<T> {
        execute<Option<T>> {
            mappers.doMap(query)
        }
    }
    public func first<T>(): Option<T> where T <: QueryMappersInit<T> {
        if (T.isSimpleData) {
            singleFirst<T>()
        } else {
            first<T>(T.queryMappers())
        }
    }
    public func firstToMap(): Map<String, Any> {
        execute<Map<String, Any>> {
            match ((query as QueryResultWrap).getOrThrow().next()) {
                case Some(x) => x.toMap()
                case _ => EmptyMap<String, Any>.INSTANCE
            }
        }
    }
    public func list<T>(mappers: QueryMappers<T>): ArrayList<T> {
        execute<ArrayList<T>> {
            mappers.list(query)
        }
    }
    public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T> {
        if (T.isSimpleData) {
            singleList<T>()
        } else {
            list<T>(T.queryMappers())
        }
    }
    public func mapList(): ArrayList<HashMap<String, Any>> {
        execute<ArrayList<HashMap<String, Any>>> {
            match (query as QueryResultWrap) {
                case Some(x) =>
                    let list = ArrayList<HashMap<String, Any>>()
                    for (row in x) {
                        list.add(row.toMap())
                    }
                    list
                case _ => ArrayList<HashMap<String, Any>>()
            }
        }
    }
    public func iterator<T>(mappers: QueryMappers<T>): QueryResultIterator<T> {
        execute<QueryResultIterator<T>> {
            mappers.iterator(query)
        }
    }
    public func iterator<T>(): Iterator<T> where T <: QueryMappersInit<T> {
        if (T.isSimpleData) {
            singleIterator<T>()
        } else {
            iterator<T>(T.queryMappers())
        }
    }
    public func one<T>(mappers: QueryMappers<T>): Option<T> {
        execute<Option<T>> {
            mappers.one(query)
        }
    }
    public func one<T>(): Option<T> where T <: QueryMappersInit<T> {
        if (T.isSimpleData) {
            singleFirst<T>()
        } else {
            one<T>(T.queryMappers())
        }
    }

    public func setSql(sql: String): SqlExecutor {
        this.sql = sql
        this
    }
    public func setArgs(args: Iterable<(DataType, Any)>): SqlExecutor {
        this.args = SqlArgs(driverName: driverName)
        for (arg in args) {
            this.args.append(arg[0], arg[1])
        }
        this
    }
    public func setArgs(args: Array<(DataType, Any)>): SqlExecutor {
        let itr: Iterable<(DataType, Any)> = args
        setArgs(itr)
    }
    public func addArg(arg: Any): SqlExecutor {
        args.append(arg)
        this
    }
    public func generateSql(sql: String): SqlExecutor {
        args = SqlArgs(driverName: driverName)
        this.sql = sql
        args.finished = true
        this
    }
    public operator func ()(sql: String): SqlExecutor {
        generateSql(sql)
    }

    private func execute<T>(executor: () -> T): T {
        try {
            func exec() {
                if (let Some(_) <- tx) {
                    return executor()
                }
                try {
                    return executor()
                } finally {
                    if (!this.isClosed()) {
                        this.close()
                    }
                }
                throw UnreachableException()
            }
            let v = if (useCache && !clearCache) {
                if (!args.finished) {
                    throw ORMException("current SqlArgs is not finished, the SqlArgs is ${args}")
                }
                let key = SqlCacheKey(sql, args)
                match (cache.get(key)) {
                    case Some(v) => (v as T).getOrThrow {
                        ORMException("type of cached data with key '${key}' does not match")
                    }
                    case _ =>
                        let v = exec()
                        cache[key] = v
                        v
                }
            } else {
                exec()
            }
            if (useCache && clearCache) {
                cache.clear()
                clearCache = false
            }
            v
        } catch (e: Exception) {
            if (logger.debugEnabled) {
                logger.debug(logMsg(DateTime.now() - start), e)
            }
            throw e
        } finally {
            if (logger.debugEnabled) {
                logger.debug(logMsg(DateTime.now() - start))
            }
            start = DateTime.UnixEpoch
            args = SqlArgs.empty
            sql = String.empty
        }
    }
    private func execute<T>(extract: (UpdateResult) -> T): T {
        clearCache = true
        execute<T> {
            let result = statement.update(args.toArray())
            extract(result)
        }
    }
    public func execute<T>(executor: (SqlExecutor) -> T): T {
        execute<T> {
            exec: SqlExecutor => (executor(exec), true)
        }
    }

    //executor返回元组的第二个值，如果是true就执行commit，否则执行rollback
    public func execute<T>(executor: (SqlExecutor) -> (T, Bool)): T {
        if (tx.isNone()) {
            execute<T> {
                try {
                    newTxAndBegin()
                    let result = executor(this)
                    if (result[1]) {
                        commit()
                        result[0]
                    } else {
                        throw ORMException()
                    }
                } catch (e1: Exception) {
                    try {
                        rollback()
                    } catch (e2: Exception) {
                        let e = ORMException(e2)
                        e.addSuppressed(e1)
                        throw e
                    }
                    if (e1 is ORMException) {
                        throw e1
                    }
                    throw ORMException(e1)
                }
            }
        } else {
            execute<T> {
                executor(this)[0]
            }
        }
    }
}
