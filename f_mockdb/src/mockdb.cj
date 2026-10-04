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
package fountain::f_mockdb

import std.env.getStdOut
import std.sync.AtomicOptionReference
internal import std.reflect.*
internal import std.collection.{HashMap, Map, ArrayList}
internal import std.env.ConsoleWriter
public import std.database.sql.*

internal let output = getStdOut()

/**复制一份字符串映射：外部（连接元数据、数据源选项等）拿到的是副本，改它不影响夹具*/
func copyMap(source: Map<String, String>): HashMap<String, String> {
    let copy = HashMap<String, String>()
    for ((k, v) in source) {
        copy[k] = v
    }
    copy
}

public class MOCKDB {
    private init(){}
    private static let EMPTY_EXECUTION = {_: String, _: ArrayList<Any> =>
        MOCKDB.log('EMPTY_EXECUTION')
    }
    private static var verbose_ = false
    /**mock 内部动作（open / setOption / 事务各步 / 默认夹具）的输出开关，默认关闭；排查「夹具为什么没生效」时可置 true*/
    public static mut prop verbose: Bool {
        get(){
            verbose_
        }
        set(value){
            verbose_ = value
        }
    }
    /**按 verbose 开关输出*/
    static func log(message: String): Unit {
        if(verbose){
            output.writeln(message)
        }
    }
    private static var execution_ = AtomicOptionReference<Box<(String, ArrayList<Any>) -> Unit>>()
    private static let queryResultList_ = ThreadLocal<ArrayList<Array<Any>>>()
    private static let queryResultColumnInfos_ = ThreadLocal<ArrayList<ColumnInfo>>()
    private static let lastInsertId_ = ThreadLocal<Int64>()
    private static let rowCount_ = ThreadLocal<Int64>()
    private static let toThrowOnExecuting_ = ThreadLocal<Bool>()
    private static let metadata_ = ThreadLocal<Map<String, String>>()
    private static let toThrowOnBeginning_ = ThreadLocal<Bool>()
    private static let toThrowOnCommitting_ = ThreadLocal<Bool>()
    private static let toThrowOnReleasing_ = ThreadLocal<HashMap<String, Bool>>()
    private static let toThrowOnRollbacking_ = ThreadLocal<Bool>()
    private static let toThrowOnRollbackingSavePoint_ = ThreadLocal<HashMap<String, Bool>>()
    private static let toThrowOnSavingSavePoint_ = ThreadLocal<HashMap<String, Bool>>()

    /**清空当前线程的查询结果（行与列信息），不动 execution 与 toThrowOn* 标志；MockStatement 每次执行前会调用本函数*/
    public static func clearQueryResult(): Unit {
        queryResultList_.set(None)
        queryResultColumnInfos_.set(None)
    }

    /**清空当前线程的全部夹具（查询结果、lastInsertId/rowCount、toThrowOn* 标志、metadata），不动 execution；用例开头调一次即可*/
    public static func clear(): Unit {
        clearQueryResult()
        lastInsertId_.set(None)
        rowCount_.set(None)
        toThrowOnExecuting_.set(None)
        metadata_.set(None)
        toThrowOnBeginning_.set(None)
        toThrowOnCommitting_.set(None)
        toThrowOnReleasing_.set(None)
        toThrowOnRollbacking_.set(None)
        toThrowOnRollbackingSavePoint_.set(None)
        toThrowOnSavingSavePoint_.set(None)
    }

    /**恢复到「未设置 execution」的初态（此后走缺省夹具 EMPTY_EXECUTION）；包内可见，供用例冻结缺省路径，不在公开 API 内*/
    static func clearExecution(): Unit {
        execution_.store(None)
    }

    static prop currentThreadId: Int64 {
        get(){
            Thread.currentThread.id
        }
    }
    /**
     * 本函数会在MockStatement的update和query函数执行，可以在本函数执行本类的其他函数
     */
    public static mut prop execution: (String, ArrayList<Any>) -> Unit {
        get(){
            execution_.load()?.value ?? EMPTY_EXECUTION
        }
        set(value){
            execution_.store(Box<(String, ArrayList<Any>) -> Unit>(value))
        }
    }
    public static func addQueryResultRow(row: Array<Any>): Unit {
        if(let Some(list) <- queryResultList_.get()){
            list
        }else {
            let list = ArrayList<Array<Any>>()
            queryResultList_.set(list)
            list
        }.add(row)
    }
    public static func getQueryResultRows(): ArrayList<Array<Any>> {
        queryResultList_.get() ?? ArrayList<Array<Any>>()
    }
    public static func addQueryResultColumnInfo(
        name!: String, nullable!: Bool, typeName!: String
    ): Unit {
        let info = MockColumnInfo(name, nullable, typeName)
        if(let Some(list) <- queryResultColumnInfos_.get()){
            list
        }else{
            let list = ArrayList<ColumnInfo>()
            queryResultColumnInfos_.set(list)
            list
        }.add(info)
    }
    public static prop queryResultColumnInfos: Array<ColumnInfo> {
        get(){
            (queryResultColumnInfos_.get()?.toArray()) ?? []
        }
    }
    public static mut prop lastInsertId: Int64 {
        get(){
            lastInsertId_.get() ?? 0
        }
        set(value){
            lastInsertId_.set(value)
        }
    }
    public static mut prop rowCount: Int64 {
        get(){
            rowCount_.get() ?? 0
        }
        set(value){
            rowCount_.set(value)
        }
    }
    public static mut prop toThrowOnExecuting: Bool {
        get() {
            toThrowOnExecuting_.get() ?? false
        }
        set(value){
            toThrowOnExecuting_.set(value)
        }
    }
    public static mut prop metadata: Map<String, String> {
        get(){
            metadata_.get() ?? HashMap<String, String>()
        }
        set(value){
            metadata_.set(value)
        }
    }
    public static mut prop toThrowOnBeginning: Bool {
        get(){
            toThrowOnBeginning_.get() ?? false
        }
        set(value){
            toThrowOnBeginning_.set(value)
        }
    }
    public static mut prop toThrowOnCommitting: Bool {
        get(){
            toThrowOnCommitting_.get() ?? false
        }
        set(value){
            toThrowOnCommitting_.set(value)
        }
    }
    public static func toThrowOnReleasing(savepoint: String, toThrow: Bool): Unit {
        match(toThrowOnReleasing_.get()){
            case Some(m) => m[savepoint] = toThrow
            case _ =>
                let m = HashMap<String, Bool>()
                toThrowOnReleasing_.set(m)
                m[savepoint] = toThrow
        }
    }
    public static func toThrowOnReleasing(savepoint: String): Bool {
        if(let Some(m) <- toThrowOnReleasing_.get()){
            m.get(savepoint) ?? false
        }else{
            false
        }
    }
    public static mut prop toThrowOnRollbacking: Bool {
        get(){
            toThrowOnRollbacking_.get() ?? false
        }
        set(value){
            toThrowOnRollbacking_.set(value)
        }
    }
    public static func toThrowOnRollbackingSavePoint(savepoint: String, toThrow: Bool): Unit {
        match(toThrowOnRollbackingSavePoint_.get()){
            case Some(m) => m[savepoint] = toThrow
            case _ =>
                let m = HashMap<String, Bool>()
                toThrowOnRollbackingSavePoint_.set(m)
                m[savepoint] = toThrow
        }
    }
    public static func toThrowOnRollbackingSavePoint(savepoint: String): Bool {
        if(let Some(m) <- toThrowOnRollbackingSavePoint_.get()){
            m.get(savepoint) ?? false
        }else{
            false
        }
    }
    
    public static func toThrowOnSavingSavePoint(savepoint: String, toThrow: Bool): Unit {
        match(toThrowOnSavingSavePoint_.get()){
            case Some(m) => m[savepoint] = toThrow
            case _ =>
                let m = HashMap<String, Bool>()
                toThrowOnSavingSavePoint_.set(m)
                m[savepoint] = toThrow
        }
    }
    public static func toThrowOnSavingSavePoint(savepoint: String): Bool {
        if(let Some(m) <- toThrowOnSavingSavePoint_.get()){
            m.get(savepoint) ?? false
        }else{
            false
        }
    }
}