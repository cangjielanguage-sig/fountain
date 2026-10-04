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
package fountain::rpcclient

import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_bean.*
import fountain::f_log.*
import fountain::rpcdef.*
import fountain::rpcdef.model.*

/**
 * 演示如何调用EchoRPC。
 * 演示代码放在Initializer.start里（由f_app在应用启动后另起线程调用），而不是包级初始化器里：
 * 包级初始化器在Init Image阶段执行，其中的配置错误或网络异常会让整个包加载失败，
 * 进程随后带着未初始化完的静态状态继续运行（实测会导致异步日志线程段错误）。
 */
public struct ClientInitializer <: Initializer {
    private static let log = LoggerFactory.getLogger<ClientInitializer>()
    static init(){
        InitializerCollection.register(ClientInitializer())
    }
    private init(){}
    public prop name: String {
        get(){
            'fountain::rpcclient'
        }
    }
    public prop dependencies: Array<String> {
        get(){
            ['fountain::f_bean']
        }
    }
    public func initialize(): Unit {
        //todo nothing
    }
    /**
     * 非阻塞启动函数：本次演示调用失败只记日志，不应阻止应用启动。
     */
    public func start(): Unit {
        try{
            var po = EchoPO()
            po.a = 100
            po.b = 'hello world'
            po.c = false
            po.d = 2.71828
            let echo = lookup<EchoRPC>()
            po = echo.echo(po)
            let obj = po.toData()
            let json = JsonValue.from(obj)
            println('***************************')
            println(json.toString())
            println('***************************')
        }catch(e: Exception){
            log.error('echo RPC failed', e)
        }
    }
}
