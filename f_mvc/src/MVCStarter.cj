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
package f_mvc

public class MVCStarter {
    private static let log = LoggerFactory.getLogger<MVCStarter>()
    private MVCStarter(private let server: Server, private let host: String, private let port: UInt16) {
        atExit(closeGracefully)
    }
    private static var starter = None<MVCStarter>
    public static func initialize(): Unit {
        if (!initial_.compareAndSwap(false, true)) {
            throw MVCException('mvc has been started')
        }
        if (!registered.load()) {
            return 
        }
        let host = MVCConfig.host
        let port = MVCConfig.port
        let builder = ServerBuilder().addr(host).port(port)
        let httplog = LoggerFactory.getLogger('stdx.net.http')
        builder.logger(httplog)
        if (let Some(x) <- MVCConfig.readTimeout) {
            builder.readTimeout(x)
        }
        if (let Some(x) <- MVCConfig.writeTimeout) {
            builder.writeTimeout(x)
        }
        if (let Some(x) <- MVCConfig.readHeaderTimeout) {
            builder.readHeaderTimeout(x)
        }
        if (let Some(x) <- MVCConfig.keepAliveTimeout) {
            builder.httpKeepAliveTimeout(x)
        }
        if (let Some(x) <- MVCConfig.maxRequestHeaderSize) {
            builder.maxRequestHeaderSize(x)
        }
        if (let Some(x) <- MVCConfig.maxRequestBodySize) {
            builder.maxRequestBodySize(x)
        }
        if (let Some(x) <- MVCConfig.headerTableSize) {
            builder.headerTableSize(x)
        }
        if (let Some(x) <- MVCConfig.maxConcurrentStreams) {
            builder.maxConcurrentStreams(x)
        }
        if (let Some(x) <- MVCConfig.initialWindowSize) {
            builder.initialWindowSize(x)
        }
        if (let Some(x) <- MVCConfig.maxFrameSize) {
            builder.maxFrameSize(x)
        }
        if (let Some(x) <- MVCConfig.maxHeaderListSize) {
            builder.maxHeaderListSize(x)
        }
        if (let Some(x) <- MVCConfig.servicePoolConfig) {
            builder.servicePoolConfig(x)
        }
        if (let Some(tls) <- MVCConfig.tlsConfig) {
            builder.tlsConfig(tls)
        }
        let server = builder.distributor(HttpRequestDistributorImpl.instance).build()
        starter = MVCStarter(server, host, port)
    }
    public static func register(mediaType: MediaType) {
        MediaTypes.register(mediaType)
    }
    private static let initial_ = AtomicBool(false)
    private static let registered = AtomicBool(false)
    public static func generateAndRegister<T>(fnName: String, argTypes: Array<TypeInfo>): ArrayList<RequestMeta> where T <: Object {
        println('AAAAAAAAAAAAAAAAAAAAAAAAAAA')
        log.debug{'MVC.registering.init:${initial_.load()}: ${TypeInfo.of<T>()} ${fnName} ${argTypes}'}
        println('BBBBBBBBBBBBBBBBBBBBBBBBBBBB')
        if (!initial_.load()) {
            println('CCCCCCCCCCCCCCCCCCCCCCCCCCCC')
            let list = HttpRequestDistributorImpl.instance.generateAndRegister<T>(fnName, argTypes)
            println('DDDDDDDDDDDDDDDDDDDDDDDDDDDD')
            registered.compareAndSwap(false, list.size > 0)
            println('EEEEEEEEEEEEEEEEEEEEEEEEEEEEE')
            log.debug{'MVC.registered:${list}'}
            println('FFFFFFFFFFFFFFFFFFFFFFFFFFFF')
            list
        } else {
            println('GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG')
            let e = MVCException("The generateAndRegister can only be called before calling MVCStarter.start().")
            e.printStackTrace()
            throw e
        }
    }
    public static func generateAndRegisterWSEndPoint<T>(path: String): WSMeta<T> where T <: Object {
        if(!initial_.load()) {
            let meta = HttpRequestDistributorImpl.instance.generateAndRegisterWSEndPoint<T>(path)
            registered.compareAndSwap(false, true)
            meta
        }else{
            throw WSException('The generateAndRegisterWSEndPoint can only be called before calling MVCStarter.start()')
        }
    }
    private prop listening: String {
        get() {
            '${host}:${port}'
        }
    }
    public static func start(): Unit {
        starter?.doStart()
    }
    private func doStart(): Unit {
        println("MVC is listening: ${listening}")
        server.serve()
    }
    public func closeGracefully(): Unit {
        server.closeGracefully()
    }
}
