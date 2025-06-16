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

import std.collection.ArrayList

struct TransactionHookWrap <: TransactionHook {
    TransactionHookWrap(private let hook: TransactionHook, let count: Int64){}

    public func beforeTx(): Unit {
        hook.beforeTx()
    }
    public func beforeCommit(readOnly: Bool): Unit {
        hook.beforeCommit(readOnly)
    }
    public func afterCommit(): Unit{
        hook.afterCommit()
    }
    public func afterThrowing(e: Exception): Unit {
        hook.afterThrowing(e)
    }
    public func beforeRollback(e: Exception): Unit {
        hook.beforeRollback(e)
    }
    public func afterRollback(e: Exception): Unit {
        hook.afterRollback(e)
    }
    public func afterComplete(status: TransactionStatus) {
        hook.afterComplete(status)
    }
}
class TransactionHooks <: TransactionHook {
    private let list = ArrayList<TransactionHookWrap>()
    func register<T>(hook: TransactionHook): Unit where T <: TransactionHook {
        list.add(TransactionHookWrap(hook, list.size))
        list.sortBy{h1, h2 => 
          match(h1.order.compare(h2.order)){
            case EQ => h1.count.compare(h2.count)
            case cmp => cmp
          }
        }
    }
    public func beforeTx(): Unit {
        for(h in list) {
            h.beforeTx()
        }
    }
    public func beforeCommit(readOnly: Bool): Unit {
        for(h in list){
            h.beforeCommit(readOnly)
        }
    }
    public func afterCommit(): Unit{
        for(h in list){
            h.afterCommit()
        }
    }
    public func afterThrowing(e: Exception): Unit {
        for(h in list){
            h.afterThrowing(e)
        }
    }
    public func beforeRollback(e: Exception): Unit {
        for(h in list){
            h.beforeRollback(e)
        }
    }
    public func afterRollback(e: Exception): Unit {
        for(h in list){
            h.afterRollback(e)
        }
    }
    public func afterComplete(status: TransactionStatus) {
        for(h in list){
            h.afterComplete(status)
        }
    }
}