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
package fountain::fhydra

import fountain::f_mvc.CurrentHttpContext
import fountain::f_jsonrpc.base.JsonRpcException

/**
 * 共享密钥校验（`X-Hydra-Key`）。
 *
 * 在 RPC 方法入口调用：`JsonRpcContext` 里拿不到请求头，但方法体运行在请求线程内，
 * 可通过 f_mvc 的 `CurrentHttpContext` 取到当前请求。
 */
public class HydraAuth {
    public static const UNAUTHORIZED: Int64 = -32023

    public static func require(): Unit {
        let secret = HydraConfig.secret()
        if(secret.isEmpty()){
            throw JsonRpcException(UNAUTHORIZED, 'hydra_secret is not configured; refusing request')
        }
        let request = CurrentHttpContext.instance.request
        match(request.headers.getFirst(HydraConfig.KEY_HEADER)){
            case Some(value) =>
                if(value != secret){
                    throw JsonRpcException(UNAUTHORIZED, 'invalid ${HydraConfig.KEY_HEADER}')
                }
            case None => throw JsonRpcException(UNAUTHORIZED, 'missing ${HydraConfig.KEY_HEADER}')
        }
    }
}
