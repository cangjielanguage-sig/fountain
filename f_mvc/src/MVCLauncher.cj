/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

public class MVCLauncher {
    private static let log = LoggerFactory.getLogger<MVCLauncher>()
    private static var server = None<Server>
    static init(){
        atExit(closeGracefully)
    }
    private static func initialize(): Future<Unit> {
        let builder = ServerBuilder().addr(MVCConfig.host).port(MVCConfig.port).logger(log)
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
        server = builder.distributor(HttpRequestDistributorImpl.instance).build()
        spawn{
            server?.serve()
        }
    }
    public static func register(mediaType: MediaType) {
        MediaTypes.register(mediaType)
    }
    private static let initial_ = AtomicBool(false)
    private static let registered = AtomicBool(false)
    public static func generateAndRegister<T>(fnName: String, argTypes: Array<TypeInfo>): ArrayList<RequestMeta> where T <: Object {
        if (!initial_.load()) {
            let list = HttpRequestDistributorImpl.instance.generateAndRegister<T>(fnName, argTypes)
            registered.compareAndSwap(false, list.size > 0)
            list
        } else {
            throw Exception("The generateAndregister can only be called before calling MVCLauncher.launch().")
        }
    }
    public static func launch(): Future<Unit>{
        initial_.store(true)
        if(registered.load()) {
            initialize()
        }else{
            spawn{}
        }
    }
    public static func closeGracefully(): Unit {
        server?.closeGracefully()
    }
}
