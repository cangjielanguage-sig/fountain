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
package fountain::f_app

import std.collection.ArrayList
import std.collection.concurrent.{ConcurrentHashMap, ConcurrentLinkedQueue}
import std.sync.Mutex

import fountain::f_base.*

/**
 * 应用初始化API。应用代码通常不需要实现本接口。
 */
public interface Initializer {
    /**
     * 待初始化的功能名称
     * 有些功能只能显式地调用函数完成初始化，fountain::f_bean fountain::f_mvc fountain::f_orm fountain::f_ticktock都是这类
     * @return
     */
    prop name: String
    /**
     * 依赖项，必须在这些功能初始化后才能初始化当前功能
     * @return
     */
    prop dependencies: Array<String> {
        get(){
            []
        }
    }
    /**
     * 调用本函数实现完成初始化
     */
    func initialize(): Unit
    /**
     * 返回启动函数，调用返回的函数是否阻塞取决于具体实现，比如调用mvc的启动函数会启动http服务并一直阻塞。
     */
    func start(): Unit {}
}
public struct InitializerCollection {
    private static var instance = InitializerCollection()
    private init(){}
    private let mutex = Mutex()
    private let initializers = ConcurrentLinkedQueue<Initializer>()
    private let dependencies = ConcurrentHashMap<String, ArrayList<String>>()//VALUE依赖KEY

    private func doRegister(initializer: Initializer){
        synchronized(mutex){
            initializers.add(initializer)
            for (dependency in initializer.dependencies) {
                dependencies.entryView(dependency){entry =>
                    if(let Some(l) <- entry.value){
                        l
                    }else{
                        let l = ArrayList<String>()
                        entry.value = l
                        l
                    }
                }?.add(initializer.name)
            }
        }
    }
    /**
     * 注册模块的初始化函数。通常应用APP不需要调用它。
     */
    public static func register(initializer: Initializer): Unit {
        instance.doRegister(initializer)
    }
    private func doInit() {
        let starters = ArrayList<() -> Unit>()
        while(let Some(initializer) <- initializers.remove()){
            var toInit = true
            for(dependency in initializer.dependencies where dependencies.contains(dependency)){
                toInit = false
                initializers.add(initializer)
                break
            }
            if(toInit){
                initializer.initialize()
                starters.add(initializer.start)
                dependencies.remove(initializer.name)
            }
        }
        instance = unsafeZeroValue<InitializerCollection>()
        starters
    }
    /**
     * 给fountain::f_app.App调用的函数
     */
    static func initialize(): ArrayList<() -> Unit> {
        instance.doInit()
    }
}