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

public class MockTransaction <: Transaction {
    private var accessMode_ = TransactionAccessMode.Unspecified
    private var deferrableMode_ = TransactionDeferrableMode.Unspecified
    private var isoLevel_ = TransactionIsoLevel.Unspecified
    private var begun_ = false
    private var finished_ = false
    public mut prop accessMode: TransactionAccessMode {
        get(){
            accessMode_
        }
        set(value){
            accessMode_ = value
        }
    }
    public mut prop deferrableMode: TransactionDeferrableMode{
        get(){
            deferrableMode_
        }
        set(value){
            deferrableMode_ = value
        }
    }
    public mut prop isoLevel: TransactionIsoLevel {
        get(){
            isoLevel_
        }
        set(value){
            isoLevel_ = value
        }
    }
    private func requireBegun(step: String): Unit {
        //事务状态机：未 begin 或已结束后都不允许继续操作（真驱动的行为）
        if(!begun_){
            throw SqlException('transaction is not begun, cannot ${step}')
        }
        if(finished_){
            throw SqlException('transaction has been finished, cannot ${step}')
        }
    }
    public func begin(): Unit {
        MOCKDB.log('Transaction beginning, threadID: ${MOCKDB.currentThreadId}')
        if(begun_){
            throw SqlException('transaction is already begun')
        }
        if(MOCKDB.toThrowOnBeginning){
            throw MockDbException('failed to begin transaction, threadID: ${MOCKDB.currentThreadId}')
        }
        begun_ = true
    }
    public func commit(): Unit {
        MOCKDB.log('Transaction committing, threadID: ${MOCKDB.currentThreadId}')
        requireBegun('commit')
        if(MOCKDB.toThrowOnCommitting){
            throw MockDbException('failed to commit transaction, threadID: ${MOCKDB.currentThreadId}')
        }
        finished_ = true
    }
    public func release(savePointName: String): Unit {
        MOCKDB.log('Transaction releasing, threadID: ${MOCKDB.currentThreadId}')
        requireBegun('release savepoint')
        if(MOCKDB.toThrowOnReleasing(savePointName)){
            throw MockDbException('failed to release savepoint ${savePointName}, threadID: ${MOCKDB.currentThreadId}')
        }
    }
    public func rollback(): Unit {
        MOCKDB.log('Transaction rollbacking, threadID: ${MOCKDB.currentThreadId}')
        requireBegun('rollback')
        if(MOCKDB.toThrowOnRollbacking){
            throw MockDbException('failed to rollback transaction, threadID: ${MOCKDB.currentThreadId}')
        }
        finished_ = true
    }
    public func rollback(savePointName: String): Unit {
        MOCKDB.log('Transaction rollbacking, threadID: ${MOCKDB.currentThreadId}; savePoint: ${savePointName}')
        requireBegun('rollback to savepoint')
        if(MOCKDB.toThrowOnRollbackingSavePoint(savePointName)){
            throw MockDbException('failed to rollback to savepoint ${savePointName}, threadID: ${MOCKDB.currentThreadId}')
        }
    }
    public func save(savePointName: String): Unit {
        MOCKDB.log('Transaction save, threadID: ${MOCKDB.currentThreadId}; savePoint: ${savePointName}')
        requireBegun('save savepoint')
        if(MOCKDB.toThrowOnSavingSavePoint(savePointName)){
            throw MockDbException('failed to save savepoint ${savePointName}, threadID: ${MOCKDB.currentThreadId}')
        }
    }
}