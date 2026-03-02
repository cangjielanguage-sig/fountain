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
import std.sync.Mutex
import fountain::f_bean.*

/**
 * 大模型函数调用的统一入口，所有函数实现都都需要注册到 FunctionMediator 中
 */
public struct FunctionMediator {
    private init(){}
    private static let mutex = Mutex()
    private static let functions = ConcurrentHashMap<String, FunctionCalling>()

    public static func call(function: String, args: JsonObject): FunctionResult {
        if(let Some(fn) <- functions.get(function)){
            return fn.call(args)
        }
        synchronized(mutex){
            if(let Some(fn) <- functions.get(function)){
                return fn.call(args)
            }
            for(fc in lookupList<FunctionCalling>()){
                functions[fc.name] = fc
            }
            return functions[function].call(args)
        }
    }
}