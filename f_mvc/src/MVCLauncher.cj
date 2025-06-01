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
    private static let server: Server

    static init() {
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
    }
    private static let initial_ = AtomicBool(false)
    public static func generateAndregister<T>(fnName: String, argTypes: Array<TypeInfo>) where T <: Object {
        if (!initial_.load()) {
            HttpRequestDistributorImpl.instance.generateAndregister<T>(fnName, argTypes)
        } else {
            throw Exception("The generateAndregister can only be called before calling MVCLauncher.launch().")
        }
    }
    public static func launch() {
        initial_.store(true)
        server.serve()
    }
}
