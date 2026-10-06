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
package fountain::f_mvc

public class MultiRequestMethodHandler <: HttpRequestHandler {
    private static let log = LoggerFactory.getLogger<MultiRequestMethodHandler>()
    static let NOT_ACCEPTABLE = HttpStatusOnlyHandler(HttpStatus.NOT_ACCEPTABLE)
    private static let METHOD_NOT_ALLOWED = HttpStatusOnlyHandler(HttpStatus.METHOD_NOT_ALLOWED)
    private static let UNSUPPORTED_MEDIA_TYPE = HttpStatusOnlyHandler(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
    private static let NOT_IMPLEMENTED = HttpStatusOnlyHandler(HttpStatus.NOT_IMPLEMENTED)
    static let INTERNAL_SERVER_ERROR = HttpStatusOnlyHandler(
        HttpStatus.INTERNAL_SERVER_ERROR, 
        message: MVCConfig.getInternalServerErrorMessage(),
        kind: MVCConfig.getInternalServerErrorMessageKind())

    private static let accessControlAllowHeaders: String = MVCConfig.accessControlAllowHeaders
    private static let accessControlAllowOrigin: String = MVCConfig.accessControlAllowOrigin
    private static let accessControlMaxAge: Int64 = MVCConfig.accessControlMaxAge

    MultiRequestMethodHandler(private let patterns: HttpRequestPathPatterns) {
        this.allowsCache = AllowsCache(this.metas)
    }

    private let metas = HashMap<RequestMethod, HashMap<String, RequestMeta>>() //注册时已使用Mutex同步，不必使用ConcurrentHashMap
    private static let mutex = Mutex()
    // §3.1 / MVC-L1：Allow 串构建一次后缓存（注册结束后 metas 不再变化）
    private let allowsCache: AllowsCache
    func register(meta: RequestMeta): Unit {
        synchronized(mutex) {
            meta.pattern = patterns
            log.debug{'MVC.register meta:${meta}; methodRegistered:${metas.contains(meta.method)}'}
            let map = metas.computeIfAbsent(meta.method){HashMap<String, RequestMeta>()}
            meta.iterateConsumes {
                c => 
                log.debug{'MVC.register meta:${meta}; methodRegistered:${metas.contains(meta.method)}; consumesRegistered:${c},${map.contains(c)}'}
                if (let Some(m) <- map.addIfAbsent(c, meta)) {
                    let msg = 'duplicate RequestMeta, method: ${meta.method}, path: ${meta.path}, consumes: ${c}, registered: ${m}'
                    log.warn(msg)
                    throw MVCException(msg)
                } else {
                    log.debug{'RequestMeta registered: ${c} ${meta}'}
                }
            }
        }
    }

    public func `handle`(ctx: HttpContext): Unit {
        let request = ctx.request
        let headers = request.headers
        let consumes = headers.getFirst('Content-Type') ?? ''
        let method = RequestMethod.parse(request.method)
        func check(meta: RequestMeta): HttpRequestHandler {
            if (!meta.checkProduces(ctx)) {
                NOT_ACCEPTABLE
            } else if (!meta.check(ctx)) {
                NOT_IMPLEMENTED
            } else {
                meta
            }
        }
        func check(metas: HashMap<String, RequestMeta>): HttpRequestHandler {
            let idx = consumes.indexOf(';') ?? -1
            let c = if(idx > 0){
                consumes[0 .. idx]
            }else{
                consumes
            }
            if (let Some(m) <- metas.get(c) && let h <- check(m)) {
                h
            } else if (let Some(m) <- metas.get('*')) {
                // §3.2 / MVC-13：通配 consumes 兜底。控制器侧的 consumes 不允许 `'*'`
                // （`addMediaTypes(..., allowAny: false)` 会对 `'*'` 抛异常），所以这里的 `'*'`
                // 只可能来自 WS 端点（`RequestMeta.setHandle(wsmeta:)` 把 consumes/produces 设为 `'*'`）。
                // WS 握手请求没有 Content-Type（`c == ''`）⇒ 原先在这里被判 415；端到端实测确认了这一点
                // （`WebSocketRouting_test`：修前握手得到 `HTTP/1.1 415 Unsupported Media Type`）。
                check(m)
            } else {
                UNSUPPORTED_MEDIA_TYPE
            }
        }
        func `handle`(ms: HashMap<String, RequestMeta>): Unit {
            check(ms).`handle`(ctx)
        }
        log.debug{'fountain mvc ${request.method}: ${request.url}'}
        // §3.2 / MVC-13：WS 握手（GET + `Upgrade: websocket`）走 `WS` 键。握手请求没有 Content-Type，
        // 所以直接用单参 `check(meta)`（WS 注册时 consumes/produces 都是 `'*'`），跳过那层 consumes 查表。
        if (method == RequestMethod.GET && isWebSocketUpgrade(headers)) {
            if (let Some(wsMeta) <- metas.get(RequestMethod.WS)) {
                check(wsMeta).`handle`(ctx)
                return
            }
        }
        match ((metas.get(method), method)) {
            case (Some(ms), OPTIONS) => check(ms).`handle`(ctx)
            case (_, OPTIONS) =>
                let allows = allowsCache.get()
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
                case Some(ms) => `handle`(ms)
                case _ => METHOD_NOT_ALLOWED.`handle`(ctx)
            }
            case (Some(ms), _) => `handle`(ms)
            case _ => METHOD_NOT_ALLOWED.`handle`(ctx)
        }
    }
}

class HttpStatusOnlyHandler <: HttpRequestHandler {
    HttpStatusOnlyHandler(private let status: HttpStatus, private let message!: String = '', private let kind!: FailureMessageKind = Text) {}
    
    public func `handle`(ctx: HttpContext): Unit {
        `handle`(ctx, None<Exception>)
    }
    public func `handle`(ctx: HttpContext, ex: ?Exception): Unit {
        func setStatus(){
            let b = ctx.responseBuilder.status(status.value)
            RequestMeta.setResponseStatus(status)
            if(let Some(accept) <- ctx.request.headers.getFirst("Accept")) {
                b.header("Content-Type", accept)
            }
            b
        }
        match(kind){
            case Bean => if(message.size > 0 && let Some(x) <- BeanFactory.instance.getFirst<ErrorHttpRequestHandler>(cond: Exactly(message))){
                let (status, resp) = x.`handle`(ctx, ex)
                if(resp is Unit){
                    return
                }
                RequestMeta.setResponseStatus(status)
                let b = ctx.responseBuilder.status(status.value)
                var accept = ''
                if(let Some(acc) <- ctx.request.headers.getFirst('Accept')) {
                    b.header("Content-Type", acc)
                    accept = acc
                }
                match(resp){
                    case x: String => b.body(x)
                    case x: ToString => b.body(x.toString())
                    case x: InputStream => b.body(x)
                    case x: Array<Byte> => b.body(x)
                    case x: ToData where accept.size > 0 => 
                        if(accept.isEmpty() || accept.contains('*/*')){
                            b.body(MediaTypes.parse('application/json').fromData(x.toData()))
                        }else if(accept.indexOf(',').isSome()){
                            let queue = AcceptQueue(accept)
                            while(let Some((_, _, accept)) <- queue.remove()){
                                if(let Some(mt) <- MediaTypes.tryParse(accept)){
                                    b.body(mt.fromData(x.toData()))
                                    return
                                }
                            }
                            b.body(x.toData().toString())
                        }else if (let Some(mt) <- MediaTypes.tryParse(accept)){
                            b.body(mt.fromData(x.toData()))
                        }else{
                            b.body(MediaTypes.parse('application/json').fromData(x.toData()))
                        }
                    case _ => b.body(status.reasonPhrase)
                }
            } else {
                setStatus().body(status.reasonPhrase)
            }
            case Text => setStatus().body(if (message.isEmpty()) {
                status.reasonPhrase
            } else {
                message
            })
            case Base64Binary => if(message.size > 0 && let Some(x) <- fromBase64String(message)){
                setStatus().body(x)
            }else{
                setStatus().body(status.reasonPhrase)
            }
        }
    }
}

/**
 * 包内接缝（§3.1 / `MVC-L1`）：`Allow` 串（`"OPTIONS, GET, POST, …"`）的线程安全缓存。
 * 所有路由注册都发生在服务启动前（`@Controller` / `@WSEndPoint` 宏的注册代码在模块静态初始化期执行，
 * `MVCStarter.generateAndRegister*` 在 `MVCStarter.initialize()` 之后调用会抛异常），
 * 因此首次 OPTIONS 请求时 `metas` 已是最终集合、此后不再变化。
 * 单测用可变 `metas` 钉住「构建一次后不再随 metas 重建」这条不变量。
 * 修前形态：`get()` 每次调用都重建（与改造前行为一致，用于测出 RED）；
 * 修后：全程持锁读缓存（不搞双检读，避免对普通 `var` 的跨线程可见性争议 —— OPTIONS 本身极少）。
 */
class AllowsCache {
    private let mutex = Mutex()
    private var cached = None<String>
    AllowsCache(private let metas: HashMap<RequestMethod, HashMap<String, RequestMeta>>) {}
    func get(): String {
        synchronized(mutex) {
            match (cached) {
                case Some(a) => a
                case _ =>
                    let a = allowsOf(metas)
                    cached = a
                    a
            }
        }
    }
}

/**
 * 包内接缝（§3.1 / `MVC-L1`）：拼出 `Allow` 串。
 * 首项固定为 OPTIONS（`MultiRequestMethodHandler.handle` 只在路径未注册 OPTIONS 映射时进入该分支），
 * 其余为已注册方法；方法顺序取自 `HashMap` 遍历 —— 本就不保证顺序（见 §2.20 / `MVC-7` 标记）。
 */
func allowsOf(metas: HashMap<RequestMethod, HashMap<String, RequestMeta>>): String {
    let allow = StringGenerator()
    allow.append(RequestMethod.OPTIONS)
    for ((method, _) in metas) {
        allow.append(", ")
        allow.append(method)
    }
    allow.toString()
}

/**
 * 包内接缝（§3.2 / `MVC-13`）：判断请求是否为 WebSocket 握手。
 * 依据 RFC 6455 的 `Upgrade: websocket`（忽略大小写）；真正的握手校验仍由 stdx 的
 * `WebSocket.upgradeFromServer`（经 `WSMeta.upgrade`）完成，本函数只负责**路由**。
 *
 * 修前形态：一律返回 `false`（不把请求当 WS 握手，行为与改造前一致 —— WS 端点因此永远匹配不到，
 * 请求落到 `handle` 的 405 分支）。修后：`Upgrade` 头含 `websocket` ⇒ `true`。
 * 单测：`MultiRequestMethodHandler_test.testIsWebSocketUpgrade`。
 */
func isWebSocketUpgrade(headers: HttpHeaders): Bool {
    match (headers.getFirst('Upgrade')) {
        case Some(v) => v.toAsciiLower().contains('websocket')
        case _ => false
    }
}
