/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

abstract sealed class HttpRequestPathPatterns <: HttpRequestDistributor {
    private let patterns = PathPattern()

    public func extract(path: String, name: String): ?String {
        patterns.extractVariableInPath(path, name)
    }
    private func register(meta: RequestMeta): Unit {
        patterns.compileIfAbsent<MultiRequestMethodHandler>(meta.path) {
            MultiRequestMethodHandler(this)
        }.register(meta)
    }
    func register(metas: ArrayList<RequestMeta>) {
        for (meta in metas) {
            register(meta)
        }
        metas
    }
    func register(path: String, meta: WSMeta){
        let requestMeta = RequestMeta(path, WS)
        requestMeta.setHandle(meta)
        register(requestMeta)
        meta
    }
    func getHandler(path: String) {
        patterns.data<HttpRequestHandler>(path)
    }
}

class HttpRequestDistributorImpl <: HttpRequestPathPatterns {
    static let instance = HttpRequestDistributorImpl()
    private static let NOT_FOUND = NotFoundHandler()

    private init() {}
    public func register(path: String, handler: HttpRequestHandler): Unit {
        throw MVCException("func register(String, HttpRequestHandler): Unit is not implemented")
    }
    public func register(path: String, handler: (HttpContext) -> Unit): Unit {
        throw MVCException("func register(String, (HttpContext) -> Unit): Unit is not implemented")
    }

    public func distribute(path: String): HttpRequestHandler {
        let handler = getHandler(path)
        match (handler) {
            case Some(h) => h
            case _ => NOT_FOUND
        }
    }

    func generateAndRegister<T>(fnName: String, argTypes: Array<TypeInfo>): ArrayList<RequestMeta> where T <: Object {
        let metas = RequestMeta.generate<T>(fnName, argTypes)
        register(metas)
    }
    func generateAndRegisterWSEndPoint<T>(path: String): WSMeta<T> where T <: Object {
        let meta = WSMeta<T>.generate()
        register(path, meta)
    }
}
