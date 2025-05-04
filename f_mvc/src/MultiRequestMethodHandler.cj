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
    private static let METHOD_NOT_ALLOWED = HttpStatusOnlyHandler(HttpStatus.METHOD_NOT_ALLOWED)
    private static let NOT_ACCEPTABLE = HttpStatusOnlyHandler(HttpStatus.NOT_ACCEPTABLE)
    private static let UNSUPPORTED_MEDIA_TYPE = HttpStatusOnlyHandler(HttpStatus.UNSUPPORTED_MEDIA_TYPE)

    private static let accessControlAllowHeaders: String = MVCConfig.accessControlAllowHeaders
    private static let accessControlAllowOrigin: String = MVCConfig.accessControlAllowOrigin
    private static let accessControlMaxAge: Int64 = MVCConfig.accessControlMaxAge

    private static let authFailureStatus = MVCConfig.authFailureStatus
    private static let authFailureMessage = MVCConfig.authFailureMessage

    private static let privilegeFailureStatus = MVCConfig.privilegeFailureStatus
    private static let privilegeFailureMessage = MVCConfig.privilegeFailureMessage

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
    private let metas = ConcurrentHashMap<RequestMethod, RequestMeta>()

    MultiRequestMethodHandler(private let patterns: HttpRequestPathPatterns){}

    public func handle(ctx: HttpContext): Unit {
        let request = ctx.request
        let headers = request.headers
        let method = RequestMethod.parse(request.method)
        func check(meta: RequestMeta) {
            if (!(meta.ignoreAuth || authChecker.check(ctx, patterns))) {
                ctx.responseBuilder.status(authFailureStatus.value).body(authFailureMessage)
                return false
            } else if (!(meta.ignorePrivilege || privilegeChecker.check(ctx, patterns))) {
                ctx.responseBuilder.status(privilegeFailureStatus.value).body(privilegeFailureMessage)
                return false
            } else {
                return true
            }
        }
        match (metas.get(method)) {
            case Some(h) => if (!h.supportedMediaType(headers.getFirst("Content-Type") ?? "")) {
                UNSUPPORTED_MEDIA_TYPE.handle(ctx)
            } else if (!h.acceptable(headers.getFirst("Accept") ?? "")) {
                NOT_ACCEPTABLE.handle(ctx)
            } else if (!check(h)) {
                return
            } else {
                h.handle(ctx)
            }
            case _ where method == RequestMethod.OPTIONS =>
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
            case _ where method == RequestMethod.HEAD =>
                match (metas.get(RequestMethod.GET)) {
                    case Some(h) => 
                        if (!check(h)) {
                            return
                        }
                        if (h.supportedMediaType(headers.getFirst("Content-Type") ?? "")) {
                            h.setHeadOnly()
                            h.handle(ctx)
                        } else {
                            UNSUPPORTED_MEDIA_TYPE.handle(ctx)
                        }
                    case _ => METHOD_NOT_ALLOWED.handle(ctx)
                }
            case _ => METHOD_NOT_ALLOWED.handle(ctx)
        }
    }
    func register(meta: RequestMeta): Unit {
        if (let Some(_) <- metas.putIfAbsent(meta.method, meta)) {
            throw MVCException("duplicate handler for ${meta.method} ${meta.path}")
        }
    }
}

class HttpStatusOnlyHandler <: HttpRequestHandler {
    HttpStatusOnlyHandler(private let status: HttpStatus) {}
    public func handle(httpContext: HttpContext): Unit {
        httpContext.responseBuilder.status(status.value).body(status.reasonPhrase)
    }
}
