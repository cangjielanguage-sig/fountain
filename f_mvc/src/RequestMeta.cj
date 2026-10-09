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

import fountain::f_data

/**
 * 包内接缝（§2.5 / `MVC-C2`）：`respond<R>`（`R <: ToData`）按「结果是否为空 + Accept」选出的响应形态。
 * 修后：非空结果 + 缺 Accept 走 `Render`（修前是 `NotAcceptable` ⇒ 406）；空结果三分支不变。
 */
enum RespondKind <: ToString {
    | Render
    | EmptyWithContentType
    | EmptyWithoutContentType
    | NotAcceptable

    public func toString(): String {
        match (this) {
            case Render => 'Render'
            case EmptyWithContentType => 'EmptyWithContentType'
            case EmptyWithoutContentType => 'EmptyWithoutContentType'
            case NotAcceptable => 'NotAcceptable'
        }
    }
}

public class RequestMeta <: HttpRequestHandler & ToString & Comparable<RequestMeta> {
    // 包内可见（§3.1 / MVC-L5）：`StaticResourceOrNotFoundHandler` 复用同一日志类别（不改变日志 name 字段）
    static let log = LoggerFactory.getLogger<RequestMeta>()
    // 包内可见（§3.1 / MVC-L5）：未命中路径的 404 输出由 `StaticResourceOrNotFoundHandler` 复用
    static let NOT_FOUND = NotFoundHandler()
    private static let STATIC_RESOURCE_ROOT = MVCConfig.mvcStaticResourceRoot
    private static let staticResourceBytes = ConcurrentHashMap<String, (DateTime, Array<Byte>)>()
    static let currentResponseStatus = ThreadLocal<UInt16>()

    static func setResponseStatus(status: HttpStatus) {
        currentResponseStatus.set(status.value)
    }
    static func getResponseStatus(): UInt16 {
        match (currentResponseStatus.get()) {
            case Some(c) => c
            case _ => HttpStatus.OK.value
        }
    }
    /**
     * 请求出口清理（§2.6 / `MVC-8`）：status 的 ThreadLocal 只 set 不清会串到同线程的下一个请求，
     * 由 `setHandle` 与 404/静态资源路径的 finally 调用。
     */
    static func clearResponseStatus() {
        currentResponseStatus.set(None)
    }
    private var ignoreAuth_ = false
    private var ignorePrivilege_ = false

    private let produces = HashSet<String>()
    private let consumes = HashSet<String>()

    private let args = RequestArgMeta()

    var pattern = None<HttpRequestPathPatterns>

    RequestMeta(
        public let path: String,
        public let method: RequestMethod,
        private let params!: RequestCondition = DummyRequestCondition.instance,
        private let headers!: RequestCondition = DummyRequestCondition.instance
    ) {
        // §3.1 / MVC-L5：默认处理器（静态资源 → 404）的逻辑已抽到 StaticResourceOrNotFoundHandler，
        // 这里委托给它以保持单一事实来源。生产路径上的未命中请求由 distribute 直接返回该 handler，
        // 不再构造 RequestMeta（`generate` 与 WS 注册随后都会用 setHandle 覆盖 handle_）。
        this.handle_ = {ctx => StaticResourceOrNotFoundHandler(path).`handle`(ctx)}
    }

    public func compare(other: RequestMeta): Ordering {
        var cmp = path.compare(other.path)
        if (cmp == Ordering.EQ) {
            cmp = method.compare(other.method)
        }
        if (cmp == Ordering.EQ) {
            let tree1 = TreeSet<String>(consumes).iterator()
            let tree2 = TreeSet<String>(other.consumes).iterator()
            while (cmp == Ordering.EQ && let Some(c1) <- tree1.next() && let Some(c2) <- tree2.next()) {
                cmp = c1.compare(c2)
            }
        }
        if (cmp == Ordering.EQ) {
            cmp = consumes.size.compare(other.consumes.size)
        }
        return cmp
    }
    public func toString(): String {
        'path: ${path}; method: ${method}; consumes: ${consumes}; consumesSize: ${consumes.size}'
    }
    // 包内可见（§3.1 / MVC-L5）：`StaticResourceOrNotFoundHandler` 复用静态资源读取
    static func loadStaticResource(path: String): ?Array<Byte> {
        staticResourceBytes.entryView(path){view =>
            var p = if(path.startsWith('/')){
                path[1..]
            }else{
                path
            } |> STATIC_RESOURCE_ROOT.join
            if(exists(p) && let fi <- FileInfo(p)){
                if(fi.isSymbolicLink()){
                    p = SymbolicLink.readFrom(p, recursive: true)
                }
                if(fi.isDirectory()){
                    view.value = None
                    return
                }
                try(file = File(p, Read)){
                    let lastModified = file.info.lastModificationTime
                    view.value = if(let Some((last, _)) <- view.value && last < lastModified){
                        (lastModified, File.readFrom(p))
                    }else if(view.value.isNone()){
                        (lastModified, File.readFrom(p))
                    }else{
                        return
                    }
                }
            }else{
                view.value = None
            }
        }?[1]
    }
    private var handle_: (HttpContext) -> Unit

    public func `handle`(ctx: HttpContext): Unit {
        handle_(ctx)
    }

    private func populateResponseContentType(ctx: HttpContext) {
        let accept = if (let Some(accept) <- ctx.request.headers.getFirst('Accept')) {
            accept
        } else {
            '*/*'
        }
        ctx.responseBuilder.header('Content-Type', accept)
    }
    public prop ignoreAuth: Bool {
        get() {
            ignoreAuth_
        }
    }
    public prop ignorePrivilege: Bool {
        get() {
            ignorePrivilege_
        }
    }
    internal func iterateConsumes(fn: (String) -> Unit): Unit {
        for (c in consumes) {
            fn(c)
        }
    }
    private func checkHeader(ctx: HttpContext, headers: HashSet<String>, name: String): Bool {
        headers.isEmpty() || headers.contains(ctx.request.headers.getFirst(name) ?? '') || headers.contains('*/*') ||
            headers.contains("*") || headers.contains('')
    }
    public func checkProduces(ctx: HttpContext) {
        if (let Some(accept) <- ctx.request.headers.getFirst('Accept')) {
            accept.isEmpty() || accept == '*' || accept == '*/*' || produces.contains(accept) || if (accept
                .indexOf(',')
                .isSome()) {
                let priority = AcceptQueue(accept)
                while (let Some((q, idx, c)) <- priority.remove()) {
                    log.debug {'RequestMeta.checkProduces.MultiAccept:${q};${idx};${c}'}
                    if (c.startsWith('*/*') || produces.contains(c)) {
                        ctx.request.headers.set('Accept', c)
                        return true
                    }
                }
                false
            } else {
                false
            }
        } else {
            true
        }
    }

    public func check(ctx: HttpContext): Bool {
        let request = ctx.request
        this.headers.check(request.headers) && this.params.check(request.form, request.url)
    }
    public func setHandle<T>(fn: (T, HttpContext, HttpRequestPathPatterns) -> Any): Unit where T <: Object {
        let controllerBeanManager = match(BeanFactory.instance.iterator<T>().next()){
            case Some(x) => x
            case _ => throw UnreachableException()
        }
        let controllerCreator = {=> 
            match(controllerBeanManager.bean){
                case x: T => x
                case _ => throw UnreachableException()
            }
        }
        let controllerGetter = if(controllerBeanManager.meta.scope.isSingleton){
            // 单例仍是「取一次」，但推迟到首次请求再取：setHandle 是 @Controller 宏在模块初始化期
            // 执行的注册代码，此刻其它库的 bean 可能尚未注册（fdemo 实测 lookup<UserService>() 抛
            // BeanException ⇒ libuser.controller 加载失败、应用起不来），注册期不能取 bean。
            let cached = Box<?T>(None<T>)
            {=>
                match (cached.value) {
                    case Some(x) => x
                    case _ =>
                        let controller = controllerCreator()
                        cached.value = controller
                        controller
                }
            }
        }else{
            controllerCreator
        }
        let pattern = this.pattern.getOrThrow()
        this.handle_ = {
            ctx =>
                try {
                    CurrentHttpContext.set(ctx)
                    let result = fn(controllerGetter(), ctx, pattern)
                    match (result) {
                        case x: JsonValue => respond(x, ctx)
                        case x: InputStream => respond(x, ctx)
                        case x: Array<Byte> => respond(x, ctx)
                        case _: Unit => ()
                        case x: ToData => respond(x, ctx)
                        case x: Redirect => respond(x, ctx)
                        case x: FileDownloadMeta => respond(x, ctx)
                        case _ =>
                            let request = ctx.request
                            log.warn {'fountain::f_mvc.`handle` ${request.method}:${request.url};${TypeInfo.of(result)}'}
                            MultiRequestMethodHandler.NOT_ACCEPTABLE.`handle`(ctx)
                    }
                } handle (cmd: MVCBreakingCommand) {
                    respond(cmd, ctx)
                } handle (cmd: BreakingCommand) {
                    respond(MVCBreakingCommand(cmd.data), ctx)
                } finally {
                    // §2.6 / MVC-8 + §3.2 / MVC-14：请求出口统一清请求级 ThreadLocal（三条路径共用同一接缝）
                    finishRequest()
                }
        }
    }
    public func checkAuth(ctx: HttpContext, args: ArrayList<Any>): Bool {
        let checked = if (ignoreAuth && ignorePrivilege) {
            return true
        } else {
            AuthHandlerProxy.instance.check(AuthParam(ctx, path, args, ignoreAuth, ignorePrivilege))
        }
        let (check, status, resp) = match (checked) {
            case OK => return true
            case SessionNotFound(status, resp) => ('SessionNotFound', status, resp)
            case SessionNotFound(resp) => ('SessionNotFound', HttpStatus.OK, resp)
            case InvalidSession(status, resp) => ('InvalidSession', status, resp)
            case InvalidSession(resp) => ('InvalidSession', HttpStatus.OK, resp)
            case SessionError(status, resp) => ('SessionError', status, resp)
            case SessionError(resp) => ('SessionError', HttpStatus.OK, resp)
            case PrivilegeError(status, resp) => ('PrivilegeError', status, resp)
            case PrivilegeError(resp) => ('PrivilegeError', HttpStatus.OK, resp)
            case NoPrivilege(status, resp) => ('NoPrivilege', status, resp)
            case NoPrivilege(resp) => ('NoPrivilege', HttpStatus.OK, resp)
        }
        setResponseStatus(status)
        let accept = ctx.request.headers.getFirst('Accept') ?? '*/*'
        let firstAccept = if (accept.contains(',')){
            AcceptQueue(accept).first() ?? 'application/json'
        }else{
            accept
        }
        let builder = ctx.responseBuilder.status(status.value).header('Content-Type', firstAccept)
        func respondStatusReasonPhrase() {
            builder.body(if (status == HttpStatus.OK) {
                HttpStatus.UNAUTHORIZED.reasonPhrase
            } else {
                status.reasonPhrase
            })
        }
        log.warn {
            'fountain::f_mvc.check ${this}; accept: ${accept}; status: ${status.value}; CheckHandler returns ${TypeInfo.of(resp)}; checked: ${check}'
        }
        match (resp) {
            case x: String => builder.body(x)
            case x: Array<Byte> => builder.body(x)
            case x: InputStream => builder.body(x)
            case x: ToString => builder.body(x.toString())
            case x: ToData where firstAccept != '*/*' => match (MediaTypes.tryParse(firstAccept)) {
                case Some(mt) => builder.body(mt.fromData(x.toData()))
                case _ => respondStatusReasonPhrase()
            }
            case _ => respondStatusReasonPhrase()
        }
        false
    }
    func setHandle<T>(wsmeta: WSMeta<T>) where T <: Object {
        this.handle_ = {
            ctx =>
                try {
                    CurrentHttpContext.set(ctx)
                    wsmeta.`handle`(BeanFactory.instance.getFirst<T>().getOrThrow(), ctx, pattern.getOrThrow())
                } finally {
                    // §3.2 / MVC-14：WS 出口与 HTTP / 404 出口对齐 —— 会话期（或握手被拒后立即返回）结束时清请求级状态
                    finishRequest()
                }
        }
        produces.add('*')
        consumes.add('*')
    }
    private func respond(method: String, fn: () -> Unit): Unit {
        try {
            fn()
        } finally {
            OverallStopwatch.elapsed(method)
        }
    }

    private func respond<R>(status: HttpStatus, result: R, ctx: HttpContext): Unit where R <: ToData {
        respond(ctx.request.method) {
            let emptyResult = result is Unit || result is DataUnit || result is DataNone
            let accept = ctx.request.headers.getFirst('Accept')
            try {
                match (respondKind(emptyResult, accept)) {
                    case Render =>
                        let renderAccept = accept ?? '*/*'
                        func genBody(accept: String): Bool {
                            if (let Some(mediaType) <- MediaTypes.tryParse(accept)) {
                                let bytes = mediaType.fromData(result.toData())
                                ctx.responseBuilder.status(status.value).header('Content-Type', accept).body(bytes)
                                return true
                            } else if (accept == '*/*') {
                                let acc = this.produces.iterator().next() ?? 'application/json'
                                let mt = MediaTypes.parse(acc)
                                let bytes = mt.fromData(result.toData())
                                ctx.responseBuilder.status(status.value).header('Content-Type', acc).body(bytes)
                                return true
                            }
                            false
                        }
                        let accepted = if(renderAccept.indexOf(',').isSome()){
                            AcceptQueue(renderAccept).first() ?? '*/*'
                        } else {
                            renderAccept
                        } |> genBody
                        if(!accepted){
                            MultiRequestMethodHandler.NOT_ACCEPTABLE.`handle`(ctx)
                        }
                    case EmptyWithContentType =>
                        ctx.responseBuilder.status(status.value).header('Content-Type', accept.getOrThrow()).body('')
                    case EmptyWithoutContentType =>
                        ctx.responseBuilder.status(status.value).body('')
                    case NotAcceptable =>
                        MultiRequestMethodHandler.NOT_ACCEPTABLE.`handle`(ctx)
                }
            } finally {
                if (let Some(e) <- closeResultIfResource(result)) {
                    log.warn(e){'Error occurred on closing ${TypeInfo.of(result)}; path: ${path}; accept: ${accept}'}
                }
            }
        }
    }
    private func respond(cmd: MVCBreakingCommand, ctx: HttpContext): Unit {
        respond<Data>(cmd.status, cmd.data, ctx)
    }
    private func respond<R>(result: R, ctx: HttpContext): Unit where R <: ToData {
        respond<R>(HttpStatus.OK, result, ctx)
    }
    private func respond(response: JsonValue, ctx: HttpContext): Unit {
        respond(ctx.request.method) {
            if (let Some(accept) <- ctx.request.headers.getFirst('Accept')) {
                let firstAccept = if(accept.contains(',')){
                    AcceptQueue(accept).first() ?? 'application/json'
                }else{
                    accept
                }
                if (let Some(mediaType) <- MediaTypes.tryParse(firstAccept) && let jmt: JsonMediaType <- mediaType) {
                    let bytes = jmt.fromData(response)
                    ctx.responseBuilder.header('Content-Type', firstAccept).body(bytes)
                } else if (firstAccept == '*/*') {
                    ctx.responseBuilder.header('Content-Type', 'application/json').body(response.toString())
                } else {
                    MultiRequestMethodHandler.NOT_ACCEPTABLE.`handle`(ctx)
                }
            } else {
                ctx.responseBuilder.header('Content-Type', 'application/json').body(response.toString())
            }
        }
    }
    private func respond(redirect: Redirect, ctx: HttpContext): Unit {
        respond(ctx.request.method) {
            ctx.responseBuilder.status(redirect.status.value).header('Location', redirect.location)
        }
    }
    private func respond(response: InputStream, ctx: HttpContext): Unit {
        respond(ctx.request.method) {
            populateResponseContentType(ctx)
            ctx.responseBuilder.body(response)
        }
    }
    private func respond(response: Array<Byte>, ctx: HttpContext): Unit {
        respond(ctx.request.method) {
            populateResponseContentType(ctx)
            ctx.responseBuilder.body(response)
        }
    }
    private func respond(response: String, ctx: HttpContext): Unit {
        respond(ctx.request.method) {
            populateResponseContentType(ctx)
            ctx.responseBuilder.body(response.unsafeBytes())
        }
    }
    private func respond(meta: FileDownloadMeta, ctx: HttpContext): Unit {
        // §2.3 / MVC-C5：下载任务是异步的（spawn 后本函数立即返回），
        // 计时搬进下载任务本身（FileDownload.exec），此处不再统计「派发」耗时。
        meta.execute()
    }

    public func isMultipart(name: String) {
        args[name] is MultipartFormData
    }

    public func extract<T, P>(ctx: HttpContext, name: String, default: ?P): T where P <: DataFields<P> {
        match (default) {
            case _: ?HttpContext => (ctx as T).getOrThrow()
            case _: ?HttpRequest => (ctx.request as T).getOrThrow()
            case _: ?HttpHeaders => (ctx.request.headers as T).getOrThrow()
            case _: ?HttpResponseBuilder => (ctx.responseBuilder as T).getOrThrow()
            case _: ?Array<Byte> => (this.extractBytes(ctx) as T).getOrThrow()
            case _: ?Form => (ctx.request.form as T).getOrThrow()
            case _ => match (default) {
                case Some(d: P) =>
                    let val = args.extract<P>(ctx, name, d, pattern)
                    if (let x: T <- val) {
                        x
                    } else if (let x: T <- Some(val)) {
                        x
                    } else {
                        throw UnreachableException()
                    }
                case _ =>
                    let val = args.extract<P>(ctx, name, pattern)
                    match (val) {
                        case x: T => x
                        case Some(x: T) => x
                        case _ => throw HttpRequestException(
                            'NO param for controller func, which request param name is ${name}')
                    }
            }
        }
    }

    public func extractBytes(ctx: HttpContext): Array<Byte> {
        let buf = ByteBuffer()
        copy(ctx.request.body, to: buf)
        buf.bytes()
    }
    private func addMediaTypes(set: HashSet<String>, types: Array<String>, allowAny: Bool, allowEmpty: Bool): Unit {
        if (types.isEmpty()) {
            if (!allowEmpty) {
                throw IllegalArgumentException('mime type must not be empty string')
            }
            set.add('')
            return
        }
        for (t in types) {
            match (t.trimAscii()) {
                case '*' | '*/*' where !allowAny => throw IllegalArgumentException(
                    "Invalid mime type: ${t} in ${types.toString().replace(', ', '|').replace('[', '').replace(']', '')}")
                case '*' | '*/*' =>
                    set.add('*')
                    set.add('*/*')
                case '' where !allowEmpty => throw IllegalArgumentException(
                    "mime type must not be empty string in ${types.toString().replace(', ', '|').replace('[', '').replace(']', '')}")
                case x => set.add(x)
            }
        }
    }
    private func addMediaTypes(set: HashSet<String>, types: String, allowAny: Bool, allowEmpty: Bool): Unit {
        addMediaTypes(set, types.split("|"), allowAny, allowEmpty)
    }
    private func addProduces(types: String) {
        addMediaTypes(produces, types, true, false)
    }
    private func addConsumes(types: String) {
        addMediaTypes(consumes, types, false, true)
    }
    public static func generate<T>(fnName: String, argTypes: Array<TypeInfo>): ArrayList<RequestMeta> where T <: Object {
        let typeInfo = TypeInfo.of<T>()
        let metas = ArrayList<RequestMeta>()
        let function = typeInfo.getInstanceFunction(fnName, argTypes)
        let functionParamMap = HashMap<String, ParameterInfo>()
        for (param in function.parameters) {
            functionParamMap[param.name] = param
        }
        let args = HashMap<String, (ControllerFuncParam, Validator, ?AbstractDateTimeConverter)>()
        let zero = unsafeZeroValue<ControllerFuncParam>()
        for (param in function.parameters) {
            let pname = param.name
            var toThrow = true
            log.debug{'controller function param ${pname} annotations: ${param.annotations.size}'}
            for (annotation in param.annotations) {
                log.debug{'controller function param ${pname} annotation: ${TypeInfo.of(annotation)}'}
                match (annotation) {
                    case x: ControllerFuncParam => match (args.get(pname)) {
                        case Some((p, v, c)) where refEq(p, zero) =>
                            args[pname] = (x, v, c)
                            toThrow = false
                        case None =>
                            args[pname] = (x, DummyValidator.instance, None<AbstractDateTimeConverter>)
                            toThrow = false
                        case _ => throw MVCException('Mapping annotation for controller func param ${pname} is duplicated')
                    }
                    case x: Validator => match (args.get(pname)) {
                        case Some((p, v, c)) where v is DummyValidator =>
                            args[pname] = (p, x, c)
                        case None => args[pname] = (zero, x, None<AbstractDateTimeConverter>)
                        case _ => throw MVCException('Validator annotaton for controller func param ${pname} is duplicated')
                    }
                    case x: AbstractDateTimeConverter => match (args.get(pname)) {
                        case Some((p, v, c)) where c.isNone() =>
                            args[pname] = (p, v, x)
                        case None => args[pname] = (zero, DummyValidator.instance, x)
                        case _ => throw MVCException('DateTimeConverter annotaton for controller func param ${pname} is duplicated')
                    }
                    case _ => continue // 可能存在与f_mvc 无关的注解，所以这里必须使用continue
                }
            }
            if (toThrow) {
                log.warn{'controller function param ${pname}'}
                throw MVCException(
                    'parameter of controller function must be with one and only one Annotation as @RequestBody or @RequestParam or @RequestHeader or @PathVariable or @MultipartFormData')
            }
        }
        let ignoreSecurity = function.findAnnotation<IgnoreSecurity>().isSome()
        let ignoreAuthGlobal = ignoreSecurity || function.findAnnotation<IgnoreAuth>().isSome()
        let ignorePrivilegeGlobal = ignoreSecurity || function.findAnnotation<IgnorePrivilege>().isSome()
        for (annotation in function.annotations) {
            if (let a: RequestMapping <- annotation) {
                let method = a.method
                let ignoreAuth = a.ignoreAuth || ignoreAuthGlobal
                let ignorePrivilege = a.ignorePrivilege || ignorePrivilegeGlobal
                let params = RequestCondition.compile(a.params)
                let headers = RequestCondition.compile(a.headers)
                for (path in a.path.split('|')) {
                    let meta = RequestMeta(path, method, params: params, headers: headers)
                    meta.addProduces(a.produces)
                    meta.addConsumes(a.consumes)
                    meta.ignoreAuth_ = ignoreAuth
                    meta.ignorePrivilege_ = ignorePrivilege
                    meta.args.add(all: args)
                    RequestMetas.instance.add(meta)
                    metas.add(meta)
                }
            }
        }
        metas
    }
    public func accessLog<T>(start: MonoTime, ctx: HttpContext, args: ArrayList<Any>, returned: ?Any, e: ?Exception) where T <: Object {
        let request = ctx.request
        // §2.6 / MVC-8：status 在请求线程读（f_log 的 message 闭包由异步 appender 在消费线程执行，
        // 在闭包里读会恒取默认值）。日志关闭时这里也只是一次 ThreadLocal 读，成本可忽略。
        let responseStatus = getResponseStatus()
        let fields = lazyAccessLogFields(args, returned)
        func logContent(): String {
            let (params, result) = fields()
            'MVC.accessLog:${request.method}:${request.url}?${request.form.toEncodeString()}; consumes:${request.headers.getFirst('Content-Type')}; params:${params}; returned:${result}; status:${responseStatus}; elapsed:${MonoTime.now() - start}'
        }
        let log = LoggerFactory.getLogger<T>()
        if (let Some(ex) <- e) {
            let exce = try {
                MultiRequestMethodHandler.INTERNAL_SERVER_ERROR.`handle`(ctx, ex)
                ex
            } catch (e: Exception) {
                let status = HttpStatus.INTERNAL_SERVER_ERROR
                let b = ctx.responseBuilder
                b.status(status.value)
                b.body(status.reasonPhrase)
                setResponseStatus(status)
                let mvcex = MVCException(e)
                mvcex.addSuppressed(ex)
                mvcex
            }
            log.error(exce, logContent)
        } else {
            log.info(logContent)
        }
    }
}

/**
 * 包内接缝（§1.12 / `MVC-2`）：返回「惰性」参数/返回值文本构造器，文本格式 `([参数,参数...], 返回值)`。
 * 构造这个闭包不做任何序列化；只有调用它（`accessLog.logContent` 真正要拼日志文本时）才遍历参数、
 * 做 toString()/toData()+JSON/base64 等重活。单测用计数 spy 钉住这条不变量。
 */
func lazyAccessLogFields(args: ArrayList<Any>, returned: ?Any): () -> (String, String) {
    {=>
        func anyToString(any: Any) {
            let arg = match (any) {
                case x: HttpContext => x
                case x: HttpRequest => x
                case x: HttpHeaders => x
                case x: HttpResponseBuilder => x
                case x: Form => return x.toEncodeString()
                case x: String => return x
                case x: ToString => return x.toString()
                case x: Array<Byte> => return toBase64String(x)
                case x: MultipartFile => return JsonString(x.toString()).toString()
                case x: ToData => return f_data.convert<JsonValue>(x.toData()).getOrThrow().toString()
                case x: Data => return f_data.convert<JsonValue>(x).getOrThrow().toString()
                case x => x
            }
            TypeInfo.of(arg).toString()
        }
        let argGen = StringGenerator().append('[')
        for (arg in args) {
            if (argGen.size > 1) {
                argGen.append(',')
            }
            argGen.append(anyToString(arg))
        }
        argGen.append(']')
        let result = match (returned) {
            case Some(x) => anyToString(x)
            case _ => 'None'
        }
        (argGen.toString(), result)
    }
}

/**
 * 包内接缝（§2.5 / `MVC-C2` + §3.2 / `MVC-L11`）：`respond<R>`（`R <: ToData`）的分支决策。
 * 非空结果一律走 `Render`（缺 Accept 时按星号通配处理，与 `JsonValue` 响应、
 * `populateResponseContentType` 的默认一致）。
 * 空结果（`DataUnit`/`DataNone`）：缺 Accept ⇒ 空体不带 Content-Type；有 Accept ⇒ 空体 + 按 Accept 声明 Content-Type。
 * **`MVC-L11` 修后**：具体 Accept（如 `application/json`）也走空体分支 —— 修前判 406，会把
 * `MVCBreakingCommand(status)`（默认 data 为 `DataUnit.UNIT`，例如 `ControllerFuncParam` 的 415）
 * 的状态码吞成 406；只有 `Accept: ''` 这类异常值仍返回 `NotAcceptable`。
 */
func respondKind(emptyResult: Bool, accept: ?String): RespondKind {
    if (!emptyResult) {
        return RespondKind.Render
    }
    match (accept) {
        case None => RespondKind.EmptyWithoutContentType
        case Some(a) where !a.isEmpty() => RespondKind.EmptyWithContentType
        case _ => RespondKind.NotAcceptable
    }
}

/**
 * 包内接缝（§2.5 / `MVC-C2`）：结果实现 `Resource` 时关闭它；关闭失败不抛，回传异常由调用方记录。
 * `respond<R>` 在 `finally` 里调用它 ⇒ 无论走 body 渲染、406 还是空结果分支都会关闭。
 */
/**
 * 包内接缝（§2.6 / `MVC-8` + §3.2 / `MVC-14`）：**请求出口清理** —— 三条请求出口路径
 * （HTTP 闭包、404/静态资源轻量 handler、WS 闭包）共用，避免任一条漏清而把请求级状态
 * （`CurrentHttpContext` / `currentResponseStatus` / `OverallStopwatch` 起点）串给同线程的下一个请求。
 * 背景：`MVC-13` 打通 WS 路由后，WS 闭包成了唯一不收尾的出口（详见 §3.2 `MVC-14`）。
 * 单测：`RequestMeta_test.testFinishRequestClearsRequestState`。
 */
func finishRequest(): Unit {
    CurrentHttpContext.clear()
    RequestMeta.clearResponseStatus()
    OverallStopwatch.clearStart()
}

func closeResultIfResource(result: Any): ?Exception {
    if (let r: Resource <- result) {
        try {
            r.close()
        } catch (e: Exception) {
            return e
        }
    }
    None<Exception>
}

/**
 * §3.1 / `MVC-L5`：未命中路由（静态资源 → 404）的轻量处理器。
 *
 * 替代原先「每请求构造一个 `RequestMeta`」——后者会连带分配 2 个 `HashSet`、`RequestArgMeta`（内含 `HashMap`）
 * 与闭包；本类只持一个 `path` 引用。逻辑与 `RequestMeta` 原默认处理器逐字一致（含 §2.6 / `MVC-8` 的
 * 请求级 ThreadLocal 清理），静态资源读取与 404 输出复用 `RequestMeta.loadStaticResource` / `RequestMeta.NOT_FOUND`。
 *
 * 不做按路径缓存：路径集合无界（扫描器可制造任意路径），按请求构造只多一个对象。
 */
class StaticResourceOrNotFoundHandler <: HttpRequestHandler {
    StaticResourceOrNotFoundHandler(private let path: String) {}
    public func `handle`(ctx: HttpContext): Unit {
        try {
            if (let Some(bytes) <- RequestMeta.loadStaticResource(path)) {
                let builder = ctx.responseBuilder.status(HttpStatus.OK.value)
                if (let Some(dotIdx) <- path.lastIndexOf('.')) {
                    let ext = path[dotIdx + 1 ..]
                    builder.header('Content-Type', match (ext) {
                        case 'html' | 'css' | 'xml' | 'txt' => 'text/${ext}'
                        case 'json' => 'application/json'
                        case 'js' => 'application/javascript'
                        case 'htm' => 'text/html'
                        case 'jpg' | 'jpeg' | 'png' | 'gif' | 'bmp' | 'ico' | 'webp' | 'tif' | 'tiff' | 'avif' | 'ico' => 'image/${ext}'
                        case 'svg' => 'image/svg+xml'
                        case 'ttf' | 'otf' | 'woff' | 'woff2' => 'font/${ext}'
                        case _ => 'application/${ext}'
                    })
                }
                builder.body(bytes)
                return
            }
            RequestMeta.log.warn{'RequestMeta.handle.Not Found:${path} ${ctx.request.headers.getFirst('Accept')}'}
            RequestMeta.NOT_FOUND.`handle`(ctx)
        } finally {
            // §2.6 / MVC-8 + §3.2 / MVC-14：404 / 静态资源这条路径同样清请求级 ThreadLocal（与另两条出口共用接缝）
            finishRequest()
        }
    }
}
