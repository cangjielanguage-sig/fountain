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

public class MultiRequestMethodHandler <: HttpRequestHandler {
    static let NOT_ACCEPTABLE = HttpStatusOnlyHandler(HttpStatus.NOT_ACCEPTABLE)
    private static let METHOD_NOT_ALLOWED = HttpStatusOnlyHandler(HttpStatus.METHOD_NOT_ALLOWED)
    private static let UNSUPPORTED_MEDIA_TYPE = HttpStatusOnlyHandler(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
    private static let NOT_IMPLEMENTED = HttpStatusOnlyHandler(HttpStatus.NOT_IMPLEMENTED)
    private static let authFailureHandler = HttpStatusOnlyHandler(MVCConfig.authFailureStatus, message: MVCConfig.authFailureMessage)
    private static let privilegeFailureHandler = HttpStatusOnlyHandler(MVCConfig.privilegeFailureStatus, message: MVCConfig.privilegeFailureMessage)

    private static let accessControlAllowHeaders: String = MVCConfig.accessControlAllowHeaders
    private static let accessControlAllowOrigin: String = MVCConfig.accessControlAllowOrigin
    private static let accessControlMaxAge: Int64 = MVCConfig.accessControlMaxAge


    private prop privilegeChecker: PrivilegeChecker {
        get() {
            BeanFactory.instance.getFirst<PrivilegeChecker>() ?? EmptyPrivilegeChecker.instance
        }
    }
    private prop authChecker: AuthChecker {
        get() {
            BeanFactory.instance.getFirst<AuthChecker>() ?? EmptyAuthChecker.instance
        }
    }
    private let metas = ConcurrentHashMap<RequestMethod, ArrayList<RequestMeta>>()

    MultiRequestMethodHandler(private let patterns: HttpRequestPathPatterns) {}

    public func handle(ctx: HttpContext): Unit {
        let request = ctx.request
        let headers = request.headers
        let method = RequestMethod.parse(request.method)
        func check(meta: RequestMeta): ?HttpRequestHandler {
            if (!(meta.ignoreAuth || authChecker.check(ctx, patterns))) {
                authFailureHandler
            } else if (!(meta.ignorePrivilege || privilegeChecker.check(ctx, patterns))) {
                privilegeFailureHandler
            } else if (!meta.checkConsumes(ctx)) {
                UNSUPPORTED_MEDIA_TYPE
            } else if (!meta.checkProduces(ctx)) {
                NOT_ACCEPTABLE
            } else if (!meta.check(ctx)) {
                NOT_IMPLEMENTED
            } else {
                None<HttpRequestHandler>
            }
        }
        func check(meta: ArrayList<RequestMeta>): ?HttpRequestHandler {
            for (m in meta) {
                if (let Some(h) <- check(m)) {
                    return h
                }
            }
            return None<HttpRequestHandler>
        }
        func handle(ms: ArrayList<RequestMeta>): Unit {
            var handle = None<HttpRequestHandler>
            for (m in ms) {
                if (let Some(h) <- check(m)) {
                    handle = h
                } else {
                    return m.handle(ctx)
                }
            }
            handle?.handle(ctx)
        }
        match ((metas.get(method), method)) {
            case (Some(m), OPTIONS)  =>
                if (let Some(h) <- check(m)) {
                    return h.handle(ctx)
                }
                let allow = StringBuilder()
                allow.append(method)
                allow.append(", ")
                let last = metas.size
                var i = 0
                for ((method, _) in metas) {
                    allow.append(method)
                    i++
                    if (i < last) {
                        allow.append(", ")
                    }
                }
                let allows = allow.toString()
                let resp = ctx.responseBuilder
                resp.header("Access-Control-Allow-Method", allows).header("Allow", allows)
                if (!accessControlAllowHeaders.isEmpty()) {
                    resp.header("Access-Control-Allow-Headers", accessControlAllowHeaders)
                }
                if (!accessControlAllowOrigin.isEmpty()) {
                    resp.header("Access-Control-Allow-Origin", accessControlAllowOrigin)
                }
                if (accessControlMaxAge > 0) {
                    resp.header("Access-Control-Max-Age", accessControlMaxAge.toString())
                }
            case (Some(m), HEAD) => match (metas.get(RequestMethod.GET)) {
                case Some(ms) => handle(ms)
                case _ => METHOD_NOT_ALLOWED.handle(ctx)
            }
            case (Some(ms), _) => handle(ms)
            case _ => METHOD_NOT_ALLOWED.handle(ctx)
        }
    }
    func register(meta: RequestMeta): Unit {
        meta.pattern = patterns
        match (metas.get(meta.method)) {
            case Some(list) => list
            case _ =>
                let l = ArrayList<RequestMeta>()
                metas[meta.method] = l
                l
        }.add(meta)
    }
}

class HttpStatusOnlyHandler <: HttpRequestHandler {
    HttpStatusOnlyHandler(private let status: HttpStatus, private let message!: String = '') {}

    public func handle(httpContext: HttpContext): Unit {
        httpContext.responseBuilder.status(status.value).body(if(message.isEmpty()){
            status.reasonPhrase
        }else{
            message
        })
    }
}
