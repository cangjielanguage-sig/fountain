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
package fountain::f_mvc

public struct MVCInitializer <: Initializer {
    static init(){
        InitializerCollection.register(MVCInitializer())
    }
    private init(){}
    public prop name: String {
        get(){
            'fountain::f_mvc'
        }
    }
    public prop dependencies: Array<String> {
        get(){
            ['fountain::f_bean']
        }
    }
    public func initialize(): Unit {
        MVCStarter.initialize()
    }
    /**
     * 返回阻塞启动函数，调用此函数将阻塞，比如调用mvc的启动函数会启动http服务并一直阻塞。
     */
    public func start(): Unit {
        MVCStarter.start()
    }
}