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
package fountain::f_llm.tool

import std.collection.concurrent.ConcurrentHashMap
import std.sync.{Mutex, AtomicBool}
import fountain::f_bean.*
import fountain::f_llm.exception.FunctionNotFoundException

/**
 * 大模型函数调用的统一入口，所有函数实现都都需要注册到 FunctionMediator 中
 */
public struct FunctionMediator {
    private init(){}
    private static let mutex = Mutex()
    private static let functions = ConcurrentHashMap<String, (JsonObject) -> FunctionResult>()
    private static let loaded = AtomicBool(false)

    public static func call(function: String, args: JsonObject): FunctionResult {
        if (let Some(fn) <- functions.get(function)){
            return fn(args)
        }else if(loaded.load()){
            throw FunctionNotFoundException(function)
        }
        synchronized(mutex){
            if (let Some(fn) <- functions.get(function)){
                return fn(args)
            }else if(loaded.load()){
                throw FunctionNotFoundException(function)
            }
            for(bm in BeanFactory.instance.iterator<CommonFunctionCalling>()){
                let bean = bm.bean
                if(let calling: CommonFunctionCalling <- bean){
                    functions[calling.name] = callee(bm)
                    closeIfNeed(bm.meta.scope.isPrototype, bean)
                }
            }
            loaded.store(true)
            return functions[function](args)
        }
    }
    private static func callee(bm: BeanManager): (JsonObject) -> FunctionResult {
        let prototype = bm.meta.scope.isPrototype
        {json: JsonObject =>
            let bean = bm.bean
            try{
                (bean as CommonFunctionCalling).getOrThrow().call(json)
            }finally{
                closeIfNeed(prototype, bean)
            }
        }
    }
    private static func closeIfNeed(prototype: Bool, bean: Object){
        if(prototype && let r: Resource <- bean){
            r.close()
        }
    }
}