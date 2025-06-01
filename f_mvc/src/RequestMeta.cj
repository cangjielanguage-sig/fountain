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

public class RequestMeta{
    private var ignoreAuth_ = false
    private var ignorePrivilege_ = false

    private let produces = HashSet<String>()
    private let consumes = HashSet<String>()

    private let args = HashMap<String, ControllerFuncParam>()

    var pattern = None<HttpRequestPathPatterns> 

    private RequestMeta(
        public let path: String,
        public let method: RequestMethod,
        private let params!: RequestCondition = DummyRequestCondition.instance,
        private let headers!: RequestCondition = DummyRequestCondition.instance
    ){}
    
    var handle: (HttpContext) -> Unit = {ctx: HttpContext => 
        throw MVCException('Request was not handled')
    }

    public prop ignoreAuth: Bool {
        get(){
            ignoreAuth_
        }
    }
    public prop ignorePrivilege: Bool {
        get(){
            ignorePrivilege_
        }
    }
    private func checkHeader(ctx: HttpContext, headers: HashSet<String>, name: String): Bool {
        headers.contains(ctx.request.headers.getFirst(name) ?? '')
    }
    public func checkConsumes(ctx: HttpContext){
        checkHeader(ctx, consumes, "Content-Type")
    }
    public func checkProduces(ctx: HttpContext) {
        checkHeader(ctx, produces, "Accept")
    }

    public func check(ctx: HttpContext): Bool {
        let request = ctx.request
        let headers = request.headers
        produces.contains(headers.getFirst('Accept') ?? '') && 
        this.headers.check(headers) && 
        this.params.check(request.form, request.url)
    }
    public func setHandle<T, R>(fn: (T, HttpContext, HttpRequestPathPatterns) -> R): Unit where T <: Object, R <: DataFields<R> {
        let pattern = this.pattern.getOrThrow()
        handle = {ctx =>
            let result = fn(BeanFactory.instance.getFirst<T>().getOrThrow(), ctx, pattern)
            generateResponse<R>(ctx, result)
        }
    }
    private func generateResponse<R>(ctx: HttpContext, result: R): Unit where R <: DataFields<R> {
        if(!(result is Unit)){
            let accept = ctx.request.headers.getFirst('Accept') ?? ""
            let mediaType = MediaTypes.parse(accept)
            let bytes = mediaType.fromDataFields(result)
            ctx.responseBuilder.body(bytes)
        }
    }
    public func isMultipart(name: String){
        args[name] is MultipartFormData
    }
    private func doExtract<T>(ctx: HttpContext, name: String): ?T where T <: DataFields<T> {
        args[name].extract<T>(name, ctx, pattern.getOrThrow())
    }
    public func extract<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtract<T>(ctx, name).getOrThrow()
    }
    public func extract<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtract<T>(ctx, name) ?? default
    }
    public func multipart<T>(ctx: HttpContext, name: String): T where T <: ObjectData<T> & DataFields<T> {
        (args[name] as MultipartFormData).getOrThrow()
        .multipart<T>(name, ctx, pattern.getOrThrow())
        .getOrThrow{MVCException('controller func ${name} and request body do not match')}
    }
    private func addMediaTypes(set: HashSet<String>, types: Array<String>): Unit {
        for(t in types where !t.isEmpty()) {
            set.add(t)
        }
    }
    private func addMediaTypes(set: HashSet<String>, types: String): Unit {
        addMediaTypes(set, types.split("|"))
    }
    private func addProduces(types: String){
        addMediaTypes(produces, types)
    }
    private func addConsumes(types: String){
        addMediaTypes(consumes, types)
    }
    public static func generate<T>(fnName: String, argTypes: Array<TypeInfo>): ArrayList<RequestMeta> where T <: Object {
        let typeInfo = TypeInfos.get<T>()
        let metas = ArrayList<RequestMeta>()
        for(function in typeInfo.instanceFunctions) {
            let args = HashMap<String, ControllerFuncParam>()
            for(param in function.parameters){
                let pname = param.name
                for(annotation in param.annotations where annotation is ControllerFuncParam){
                    args[pname] = (annotation as ControllerFuncParam).getOrThrow()
                    break
                }
                throw MVCException('parameter of controller function must be with one and only one Annotation as @RequestBody or @RequestParam or @RequestHeader or @PathVariable or @MultipartFormData')
            }
            for(annotation in function.annotations) {
                match(annotation){
                    case a: RequestMapping => 
                        let method = a.method
                        let ignoreAuth = a.ignoreAuth
                        let ignorePrivilege = a.ignorePrivilege
                        let params = RequestCondition.compile(a.params)
                        let headers = RequestCondition.compile(a.headers)
                        for(path in a.path.split('|')){
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
        }
        metas
    }
}