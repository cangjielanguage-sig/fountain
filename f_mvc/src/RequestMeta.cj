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

public class RequestMeta <: HttpRequestHandler & ToString {
    private static let log = LoggerFactory.getLogger<RequestMeta>()
    static let currentResponseStatus = ThreadLocal<UInt16>()
    static func setResponseStatus(status: HttpStatus){
        currentResponseStatus.set(status.value)
    }
    private static func getResponseStatus(): UInt16 {
        match(currentResponseStatus.get()){
            case Some(c) => c
            case _ => HttpStatus.OK.value
        }
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
    ) {}

    public func toString(): String {
        'path: ${path}; method: ${method}; consumes: ${consumes}'
    }

    private var handle_: (HttpContext) -> Unit = {
        ctx: HttpContext => throw MVCException('Request was not handled')
    }

    public func handle(ctx: HttpContext): Unit {
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
        headers.contains(ctx.request.headers.getFirst(name) ?? '') || headers.contains("*")
    }
    public func checkProduces(ctx: HttpContext) {
        checkHeader(ctx, produces, "Accept")
    }

    public func check(ctx: HttpContext): Bool {
        let request = ctx.request
        this.headers.check(request.headers) && this.params.check(request.form, request.url)
    }
    public func setHandle<T>(fn: (T, HttpContext, HttpRequestPathPatterns) -> Any): Unit where T <: Object {
        let pattern = this.pattern.getOrThrow()
        this.handle_ = {
            ctx =>
                let result = fn(BeanFactory.instance.getFirst<T>().getOrThrow(), ctx, pattern)
                match (result) {
                    case x: JsonValue => respond(x, ctx)
                    case x: InputStream => respond(x, ctx)
                    case x: Array<Byte> => respond(x, ctx)
                    case _: Unit => ()
                    case x: ToData => respond(x, ctx)
                    case _ =>
                        let request = ctx.request
                        log.warn<ToString>('fountain.mvc.handle {}:{};{}',
                            [request.method, request.url, TypeInfo.of(result)])
                        MultiRequestMethodHandler.NOT_ACCEPTABLE.handle(ctx)
                }
        }
    }
    public func checkAuth(ctx: HttpContext, args: ArrayList<Any>): Bool {
        if (ignoreAuth && ignorePrivilege) {
            return true
        }
        let checked = if (let Some(auth) <- BeanFactory.instance.getFirst<AuthHandler>()) {
            auth.check(AuthParam(ctx, path, args, ignoreAuth, ignorePrivilege))
        } else {
            AuthStatus.OK
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
        let builder = ctx.responseBuilder.status(status.value).header('Content-Type', accept)
        func respondStatusReasonPhrase() {
            builder.body(if (status == HttpStatus.OK) {
                HttpStatus.UNAUTHORIZED.reasonPhrase
            } else {
                status.reasonPhrase
            })
        }
        log.warn(
            'fountain.mvc.check ${this}; accept: ${accept}; status: ${status.value}; CheckHandler returns ${TypeInfo.of(resp)}; checked: ${check}')
        match (resp) {
            case x: String => builder.body(x)
            case x: Array<Byte> => builder.body(x)
            case x: InputStream => builder.body(x)
            case x: ToString => builder.body(x.toString())
            case x: ToData where accept != '*/*' => match (MediaTypes.tryParse(accept)) {
                case Some(mt) => builder.body(mt.fromData(x.toData()))
                case _ => respondStatusReasonPhrase()
            }
            case _ => respondStatusReasonPhrase()
        }
        false
    }
    func setHandle<T>(wsmeta: WSMeta<T>) where T <: Object {
        this.handle_ = {
            ctx => wsmeta.handle(BeanFactory.instance.getFirst<T>().getOrThrow(), ctx, pattern.getOrThrow())
        }
        produces.add('*')
        consumes.add('*')
    }
    private func respond<R>(result: R, ctx: HttpContext): Unit where R <: ToData {
        if (!(result is Unit) && let Some(accept) <- ctx.request.headers.getFirst('Accept') && let Some(mediaType) <- MediaTypes
            .tryParse(accept)) {
            let bytes = mediaType.fromData(result.toData())
            ctx.responseBuilder.header('Content-Type', accept).body(bytes)
        } else {
            MultiRequestMethodHandler.NOT_ACCEPTABLE.handle(ctx)
        }
    }
    private func respond(response: JsonValue, ctx: HttpContext): Unit {
        if (let Some(accept) <- ctx.request.headers.getFirst('Accept') && let Some(mediaType) <- MediaTypes.tryParse(
            accept) && let jmt: JsonMediaType <- mediaType) {
            let bytes = jmt.fromData(response)
            ctx.responseBuilder.header('Content-Type', accept).body(bytes)
        } else {
            MultiRequestMethodHandler.NOT_ACCEPTABLE.handle(ctx)
        }
    }
    private func respond(response: InputStream, ctx: HttpContext): Unit {
        populateResponseContentType(ctx)
        ctx.responseBuilder.body(response)
    }
    private func respond(response: Array<Byte>, ctx: HttpContext): Unit {
        populateResponseContentType(ctx)
        ctx.responseBuilder.body(response)
    }
    private func respond(response: String, ctx: HttpContext): Unit {
        populateResponseContentType(ctx)
        ctx.responseBuilder.body(response.unsafeBytes())
    }
    public func isMultipart(name: String) {
        args[name] is MultipartFormData
    }

    public func extract<T>(ctx: HttpContext, name: String, default: ?T): T where T <: DataFields<T> {
        match (default) {
            case _: ?HttpContext => (ctx as T).getOrThrow()
            case _: ?HttpRequest => (ctx.request as T).getOrThrow()
            case _: ?HttpHeaders => (ctx.request.headers as T).getOrThrow()
            case _: ?HttpResponseBuilder => (ctx.responseBuilder as T).getOrThrow()
            case _: ?Array<Byte> => (this.extractBytes(ctx) as T).getOrThrow()
            case _: ?Form => (ctx.request.form as T).getOrThrow()
            case _: ?RequestBodyParser => (RequestBodyParser(ctx, this) as T).getOrThrow()
            case _ => match(default){
                case Some(d) => args.extract<T>(ctx, name, d, pattern)
                case _ => args.extract<T>(ctx, name, pattern)
            }
        }
    }
    public func extractObject<T>(ctx: HttpContext, name: String): T where T <: Object & ObjectData<T> {
        args.extractObject<T>(ctx, name, pattern)
    }
    public func extractBytes(ctx: HttpContext): Array<Byte>{
        let buf = ByteBuffer()
        copy(ctx.request.body, to: buf)
        buf.bytes()
    }
    private func addMediaTypes(set: HashSet<String>, types: Array<String>, allowAny: Bool): Unit {
        for (t in types) {
            match (t.trimAscii()) {
                case '*' | '*/*' where !allowAny => throw IllegalArgumentException(
                    "Invalid mime type: ${t} in ${types.toString().replace(', ', '|').replace('[', '').replace(']', '')}")
                case '*' | '*/*' => set.add('*')
                case '' => throw IllegalArgumentException(
                    "mime type must not be empty string in ${types.toString().replace(', ', '|').replace('[', '').replace(']', '')}")
                case x => set.add(x)
            }
        }
    }
    private func addMediaTypes(set: HashSet<String>, types: String, allowAny: Bool): Unit {
        addMediaTypes(set, types.split("|"), allowAny)
    }
    private func addProduces(types: String) {
        addMediaTypes(produces, types, false)
    }
    private func addConsumes(types: String) {
        addMediaTypes(consumes, types, false)
    }
    public static func generate<T>(fnName: String, argTypes: Array<TypeInfo>): ArrayList<RequestMeta> where T <: Object {
        let typeInfo = TypeInfos.get<T>()
        let metas = ArrayList<RequestMeta>()
        let function = typeInfo.getInstanceFunction(fnName, argTypes)
        let args = HashMap<String, ControllerFuncParam>()
        for (param in function.parameters) {
            let pname = param.name
            var toThrow = true
            for (annotation in param.annotations where annotation is ControllerFuncParam) {
                args[pname] = (annotation as ControllerFuncParam).getOrThrow()
                toThrow = false
                break
            }
            if (toThrow) {
                throw MVCException(
                    'parameter of controller function must be with one and only one Annotation as @RequestBody or @RequestParam or @RequestHeader or @PathVariable or @MultipartFormData')
            }
        }
        for (annotation in function.annotations) {
            match (annotation) {
                case a: RequestMapping =>
                    let method = a.method
                    let ignoreAuth = a.ignoreAuth
                    let ignorePrivilege = a.ignorePrivilege
                    let params = RequestCondition.compile(a.params)
                    let headers = RequestCondition.compile(a.headers)
                    for (path in a.path.split('|')) {
                        let meta = RequestMeta(path, method, params: params, headers: headers)
                        meta.addProduces(a.produces)
                        meta.addConsumes(a.consumes)
                        meta.ignoreAuth_ = ignoreAuth
                        meta.ignorePrivilege_ = ignorePrivilege
                        meta.args.add(all: args)
                        metas.add(meta)
                    }
                case _ => ()
            }
        }
        metas
    }
    public static func accessLog(start: MonoTime, ctx: HttpContext, args: ArrayList<Any>, returned: ?Any, e: ?Exception) {
        func anyToString(any: Any) {
            let arg = match (any) {
                case x: String => return x
                case x: ToString => return x.toString()
                case x: Array<Byte> => return x.toString()
                case x: ToData => match(any){
                    case _: HttpContext => x
                    case _: HttpRequest => x
                    case _: HttpHeaders => x
                    case _: HttpResponseBuilder => x
                    case _: Form => x
                    case _: RequestBodyParser => x
                    case _ => return x.toData().toString()
                }
                case x => x
            }
            TypeInfo.of(arg).toString()
        }
        let request = ctx.request
        let argGen = StringGenerator().append('[')
        for (arg in args) {
            if (argGen.size > 1) {
                argGen.append(',')
            }
            let s = anyToString(arg)
            argGen.append(s)
        }
        argGen.append(']')
        let result = match (returned) {
            case Some(x) => anyToString(x)
            case _ => 'None'
        }
        let logArgs: Array<ToString> = [request.method, request.url, request.form.toEncodeString(), request.headers.getFirst('Content-Type'), argGen, result, getResponseStatus(), MonoTime.now() - start]
        if(let Some(ex) <- e){
            logArgs[logArgs.size - 2] = HttpStatus.INTERNAL_SERVER_ERROR.value
            log.error('MVC.accessLog:{}:{}?{}; consumes:{}; params:{}; returned:{}; status:{}; elapsed:{}', ex, logArgs)
            MultiRequestMethodHandler.INTERNAL_SERVER_ERROR.handle(ctx)
        } else {
            log.info('MVC.accessLog:{}:{}?{}; consumes:{}; params:{}; returned:{}; status:{}; elapsed:{}', logArgs)
        }
    }
}
