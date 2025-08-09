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

public class RequestMeta <: HttpRequestHandler {
    private static let log = LoggerFactory.getLogger<RequestMeta>()
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

    private var handle_: (HttpContext) -> Unit = {
        ctx: HttpContext => throw MVCException('Request was not handled')
    }

    public func handle(ctx: HttpContext): Unit {
        handle_(ctx)
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
    public func setHandle<T, R>(fn: (T, HttpContext, HttpRequestPathPatterns) -> R): Unit where T <: Object,
        R <: DataFields<R> {
        let pattern = this.pattern.getOrThrow()
        this.handle_ = {
            ctx =>
            let start = MonoTime.now()
            try {
                let result = fn(BeanFactory.instance.getFirst<T>().getOrThrow(), ctx, pattern)
                if (let (GET, GET) <- (this.method, RequestMethod.parse(ctx.request.method))) {
                    return
                }
                generateResponse<R>(ctx, result)
            } finally {
                let request = ctx.request
                log.info<ToString>('fountain.mvc {}:{};{}', [request.method, request.url, MonoTime.now() - start])
            }
        }
    }
    func setHandle<T>(wsmeta: WSMeta<T>) where T <: Object {
        this.handle_ = {ctx => 
            wsmeta.handle(BeanFactory.instance.getFirst<T>().getOrThrow(), ctx, pattern.getOrThrow())
        }
        produces.add('*')
        consumes.add('*')
    }
    private func generateResponse<R>(ctx: HttpContext, result: R): Unit where R <: DataFields<R> {
        if (!(result is Unit)) {
            let accept = if (let Some(x) <- ctx.request.headers.getFirst('Accept')) {
                x
            } else if (let Some(x) <- consumes.iterator().next()) {
                x
            } else {
                ''
            }
            let mediaType = MediaTypes.parse(accept)
            let bytes = mediaType.fromDataFields(result)
            ctx.responseBuilder.body(bytes)
        }
    }
    public func isMultipart(name: String) {
        args[name] is MultipartFormData
    }
    public func extract<T>(ctx: HttpContext, name: String, default: ?T): T where T <: DataFields<T> {
        match(default){
            case Some(d) => args.extract<T>(ctx, name, d, pattern)
            case _ => args.extract<T>(ctx, name, pattern)
        }
    }
    public func multipart<T>(ctx: HttpContext, name: String): T where T <: ObjectData<T> & DataFields<T> {
        (args[name] as MultipartFormData)
            .getOrThrow()
            .multipart<T>(name, ctx, pattern.getOrThrow())
            .getOrThrow {MVCException('controller func ${name} and request body do not match')}
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
            if(toThrow){
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
}
