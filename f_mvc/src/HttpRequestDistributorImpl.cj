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

sealed abstract class HttpRequestPathPatterns <: HttpRequestDistributor{
    protected let patterns = PathPattern()

    public func extractParsableVairableInPath<T>(path: String, name: String): ?T where T <: DataParsable<T> {
        patterns.extractParsableVairableInPath<T>(path, name)
    }
    func register(meta: RequestMeta): Unit {
        meta.setPathPattern(patterns)
        patterns.compileIfAbsent<MultiRequestMethodHandler>(meta.path){
            MultiRequestMethodHandler(this)
        }.register(meta)
    }
    func getHandler(path: String) {
        patterns.data<MultiRequestMethodHandler>(path)
    }
}
class HttpRequestDistributorImpl <: HttpRequestPathPatterns {
    static let instance = HttpRequestDistributorImpl()
    private static let NOT_FOUND = NotFoundHandler()

    private init(){}
    public func register(path: String, handler: HttpRequestHandler): Unit {
        throw MVCException("func register(String, HttpRequestHandler): Unit is not implemented")
    }
    public func register(path: String, handler: (HttpContext) -> Unit): Unit {
        throw MVCException("func register(String, (HttpContext) -> Unit): Unit is not implemented")
    }

    public func distribute(path: String): HttpRequestHandler {
        let handler = getHandler(path)
        match(handler) {
            case Some(h) => h
            case _ => NOT_FOUND
        }
    }
}
