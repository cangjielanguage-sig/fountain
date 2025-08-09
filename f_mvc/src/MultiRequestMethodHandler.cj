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

public class MultiRequestMethodHandler <: HttpRequestHandler {
    private static let log = LoggerFactory.getLogger<MultiRequestMethodHandler>()
    static let NOT_ACCEPTABLE = HttpStatusOnlyHandler(HttpStatus.NOT_ACCEPTABLE)
    private static let METHOD_NOT_ALLOWED = HttpStatusOnlyHandler(HttpStatus.METHOD_NOT_ALLOWED)
    private static let UNSUPPORTED_MEDIA_TYPE = HttpStatusOnlyHandler(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
    private static let NOT_IMPLEMENTED = HttpStatusOnlyHandler(HttpStatus.NOT_IMPLEMENTED)
    private static let INTERNAL_SERVER_ERROR = HttpStatusOnlyHandler(HttpStatus.INTERNAL_SERVER_ERROR)
    private static let authFailureHandler = HttpStatusOnlyHandler(MVCConfig.authFailureStatus,
        message: MVCConfig.authFailureMessage)
    private static let privilegeFailureHandler = HttpStatusOnlyHandler(MVCConfig.privilegeFailureStatus,
        message: MVCConfig.privilegeFailureMessage)

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

    MultiRequestMethodHandler(private let patterns: HttpRequestPathPatterns) {}

    private let metas = HashMap<RequestMethod, HashMap<String, RequestMeta>>() //注册时已使用Mutex同步，不必使用ConcurrentHashMap
    private static let mutex = Mutex()
    func register(meta: RequestMeta): Unit {
        synchronized(mutex) {
            meta.pattern = patterns
            let map = match (metas.get(meta.method)) {
                case Some(map) => map
                case _ =>
                    let m = HashMap<String, RequestMeta>()
                    metas[meta.method] = m
                    m
            }
            meta.iterateConsumes {
                c => if (let Some(m) <- map.addIfAbsent(c, meta)) {
                    throw MVCException(
                        'duplicate RequestMeta, method: ${meta.method}, path: ${meta.path}, consumes: ${c}')
                }
            }
        }
    }

    public func handle(ctx: HttpContext): Unit {
        let request = ctx.request
        let headers = request.headers
        let consumes = headers.getFirst('Content-Type') ?? ''
        let method = RequestMethod.parse(request.method)
        func check(meta: RequestMeta): HttpRequestHandler {
            if (!meta.checkProduces(ctx)) {
                NOT_ACCEPTABLE
            } else if (!meta.check(ctx)) {
                NOT_IMPLEMENTED
            } else if (!(meta.ignoreAuth || authChecker.check(ctx, patterns))) {
                authFailureHandler
            } else if (!(meta.ignorePrivilege || privilegeChecker.check(ctx, patterns))) {
                privilegeFailureHandler
            } else {
                meta
            }
        }
        func check(metas: HashMap<String, RequestMeta>): HttpRequestHandler {
            if (let Some(m) <- metas.get(consumes) && let h <- check(m)) {
                h
            } else {
                UNSUPPORTED_MEDIA_TYPE
            }
        }
        func handle(ms: HashMap<String, RequestMeta>): Unit {
            try {
                check(ms).handle(ctx)
            } catch (e: Exception) {
                log.error<ToString>('fountain mvc {}: {}', e, [request.method, request.url])
            }
        }
        if (log.debugEnabled) {
            let request = ctx.request
            log.debug<ToString>('fountain mvc {}: {}', [request.method, request.url])
        }
        match ((metas.get(method), method)) {
            case (Some(ms), OPTIONS) => check(ms).handle(ctx)
            case (_, OPTIONS) =>
                let allow = StringGenerator()
                allow.append(method)
                let last = metas.size
                for ((method, _) in metas) {
                    allow.append(", ")
                    allow.append(method)
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
}

class HttpStatusOnlyHandler <: HttpRequestHandler {
    HttpStatusOnlyHandler(private let status: HttpStatus, private let message!: String = '') {}

    public func handle(httpContext: HttpContext): Unit {
        httpContext
            .responseBuilder
            .status(status.value)
            .body(if (message.isEmpty()) {
                status.reasonPhrase
            } else {
                message
            })
    }
}
