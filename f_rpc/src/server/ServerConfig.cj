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
package fountain::f_rpc.server

internal class ServerConfig {
    public static const RPC_SERVER_PREFIX = "rpcServer"
    public static const RPC_SERVER_PREFIX_PORT = RPC_SERVER_PREFIX + "_port"
    public static const RPC_SERVER_PORT = RPC_SERVER_PREFIX + '_port'
    public static const RPC_SERVER_BUFFER_QUEUE_SIZE = RPC_SERVER_PREFIX + '_bufferQueueSize'
    public static const RPC_SERVER_CONNECTION_CHECK_DURATION = RPC_SERVER_PREFIX + '_connectionCheckDuration'
    public static const RPC_SERVER_BASE_HOSTS = RPC_SERVER_PREFIX + '_baseHosts'

    internal static prop port: Unit16 {
        get(){
            Config.getValue<Int16>(RPC_SERVER_PREFIX_PORT) ?? 1203u16
        }
    }
    internal static prop bufferQueueSize: Int64 {
        get(){
            Config.getValue<Int64>(RPC_SERVER_BUFFER_QUEUE_SIZE) ?? 1000000
        }
    }
    internal static prop connectionCheckDuration: Int64 {
        get(){
            Config.getValue<Int64>(RPC_SERVER_CONNECTION_CHECK_DURATION) ?? 1000
        }
    }
    internal static prop baseHosts: Array<String> {
        get(){
            Config.getStringArray(RPC_SERVER_BASE_HOSTS)
        }
    }
}