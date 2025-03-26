/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_base

import std.collection.ArrayList
import std.reflect.TypeInfo
import std.time.DateTime
import f_exception.TypeNotMatchException

public class FutureTask<T> {
    public FutureTask(private let task: () -> T) {}

    private let continueWiths = ArrayList<(Any) -> Any>()
    private var future = Option<Future<Any>>.None

    public func continueWith<T, R>(task: (T) -> R){
        continueWiths.add({val: Any => 
            if (let arg: T <- val) {
                task(arg)
            } else {
                throw TypeNotMatchException('${TypeInfos.get<T>()} is required for task arg in continueWiths, but current is ${TypeInfo.of(val)}')
            }
        })
    }
    public func cancel(){
        future?.cancel()
    }
    public func get<R>(timeout!: Duration = Duration.Zero){
        let f: Future<Any> = spawn {
            var val: Any = task()
            for(cw in continueWiths where !Thread.currentThread.hasPendingCancellation){
                val = cw(val)
            }
            val
        }
        future = f
        let any = f.get(timeout)
        if(let r: R <- any){
            r
        }else{
            throw TypeNotMatchException('${TypeInfos.get<R>()} is required for final result of current FutureTask, but current result type is ${TypeInfo.of(any)}')
        }
    }
    public func tryGet<R>(){
        let f: Future<Any> = spawn {
            var val: Any = task()
            for(cw in continueWiths where !Thread.currentThread.hasPendingCancellation){
                val = cw(val)
            }
            val
        }
        future = f
        let any = f.tryGet()
        if(let r: R <- any){
            r
        }else{
            None<R>
        }
    }
}