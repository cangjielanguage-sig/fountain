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
 * 包级初始化器的Init Image阶段执行，其中的配置错误或网络异常会让整个包加载失败，
 * 进程随后带着未初始化完的静态状态继续运行（实测会导致异步日志线程段错误）。
 */
public struct ClientInitializer <: Initializer {
    private static let log = LoggerFactory.getLogger<ClientInitializer>()
    /** 连调次数：用于观察多服务节点下的负载均衡（各节点被服务了多少次）。 */
    private static let rounds = 100
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
     * 非阻塞启动函数：连续调用 echo {@link rounds} 次，每次调用失败只记日志、继续下一次，
     * 最后打印成功次数与最后一次响应的 JSON（服务端每处理一次都会打印收到的 JSON，
     * 因此各服务节点被调用的次数可以直接从服务端输出里数出来）。
     */
    public func start(): Unit {
        try{
            let echo = lookup<EchoRPC>()
            var ok = 0
            var last = None<EchoPO>
            for(i in 0..rounds){
                var po = EchoPO()
                po.a = 100
                po.b = 'hello world'
                po.c = false
                po.d = 2.71828
                try{
                    last = Some(echo.echo(po))
                    ok++
                }catch(e: Exception){
                    log.error('echo RPC failed at #${i}', e)
                }
            }
            println('***************************')
            println('echo 调用完成：成功 ${ok}/${rounds}')
            if(let Some(po) <- last){
                println(JsonValue.from(po.toData()).toString())
            }
            println('***************************')
        }catch(e: Exception){
            log.error('echo RPC failed', e)
        }
    }
}
