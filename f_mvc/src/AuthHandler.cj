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

/**
 * 枚举的Any类型实际只能处理String ToString InputStream Array<Byte> f_data.ToData这几种类型，
 * 如果是其它类型将会忽略，转而使用HttpStatus的reasonPhrase作为响应体。
 * OK：当前用户登录状态有效且权限正确。
 * SessionNotFound：未找到当前用户的登录状态，可能是用户未登录，也可能是登录状态已过期。
 * InvalidSession：找到了当前用户的登录状态，但是本次访问传递的登录信息无效。
 * SessionError：检查当前用户登录状态时发生错误，可能是服务器内部错误。
 * PrivilegeError：检查当前用户权限时发生错误，可能是服务器内部错误。
 * NoPrivilege：当前用户没有权限访问该资源。
 */
public enum AuthStatus {
    | OK
    | SessionNotFound(HttpStatus, Any)
    | InvalidSession(HttpStatus, Any)
    | SessionError(HttpStatus, Any)
    | PrivilegeError(HttpStatus, Any)
    | NoPrivilege(HttpStatus, Any)
}
public interface AuthHandler {
    /**
     * 检查当前用户登录状态及权限
     * @param ctx 当前请求上下文
     * @param args 处理当前请求的函数参数
     * @return 当前用户登录状态及权限的检查结果
     */
    func check(param: AuthParam): AuthStatus
}
public struct AuthParam {
    public AuthParam(
        public let ctx: HttpContext,
        public let path: String,
        public let args: ArrayList<Any>,
        public let ignoreAuth: Bool,
        public let ignorePrivilege: Bool
    ){}
}