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


func getFile(ctx: HttpContext, name: String, contentType: String) {
    match(MediaTypes.parse(contentType)) {
        case x: MultipartMediaType =>
            x.parse(ctx).get(name).getOrThrow{MVCException("param ${name} is not found or must be a file")}
        case _ => //todo 需要反射支持枚举，才能做更细致的判定
            throw MVCException("${name} must be a file")
    }
}
public func getPathVariable<T>(ctx: HttpContext, name: String, pattern: PathPattern): ?T where T <: DataParsable<T> {
    pattern.extractDataPasableVairableInPath<T>(ctx.request.url.path, name)
}
public func getRequestBody<T>(ctx: HttpContext): ?T where T <: Object & DataObject<T> {
    let contentType = ctx.request.headers.getFirst("Content-Type") ?? ""
    MediaTypes.parse(contentType).toDataFields<T>(ctx.request.body)
}
public func getRequestFile<T>(ctx: HttpContext, name: String): ?MultipartFile<T> where T <: InputStream {
    let contentType = ctx.request.headers.getFirst("Content-Type") ?? ""
    match(getFile(ctx, name, contentType)) {
        case x: MultipartFile<T> => x
        case _ => throw MultipartFormDataException("${name} does not match type ${TypeInfos.get<MultipartFile<T>>()}")
    }
}
public func getRequestHeader<T>(ctx: HttpContext, name: String): ?T where T <: DataParsable<T> {
    match (ctx.request.headers.getFirst(name)) {
        case Some(x) => T.tryParse(x)
        case _ => None<T>
    }
}
public func getConfig<T>(name: String): ?T where T <: DataParsable<T>{
    Config.getData<T>(name){T.tryParse(name)}
}
public func getRequestParam<T>(ctx: HttpContext, name: String): ?T where T <: DataFields<T> {
    let contentType = ctx.request.headers.getFirst("Content-Type") ?? ""
    let typeInfo = TypeInfos.get<T>()
    if (typeInfo.isSubtypeOf(TypeInfos.get<Object>())) {
        let fields /*: ObjectFields<T>*/ = TypeMemberInfos.staticFunction(TypeInfos.get<T>(), "dataFields")
        typeInfo.getStaticFunction("dataFields").apply([])
        let fieldsTypeInfo = TypeInfo.of(fields)
        let creator = fieldsTypeInfo.getInstanceFunction("create")
        let mutables: Iterator<MutableField> = (fieldsTypeInfo.getInstanceFunction("multableFields").apply(fields,
            []) as Iterator<MutableField>).getOrThrow()
        let instance = (creator.apply(fields) as Object).getOrThrow()
        let instanceTypeInfo = TypeInfo.of(instance)
        for (mf in mutables) {
            let name = mf.name
            try {
                let property = instanceTypeInfo.getInstanceProperty(name)
                let propTypeInfo = property.typeInfo
                if (propTypeInfo.qualifiedName.startsWith("fountain/mvc.MultipartFile")) {
                    property.setValue(instance, getFile(ctx, name, contentType))
                } else if (propTypeInfo.qualifiedName.startsWith("fountain/mvc.MultipartMixed")) {
                    property.setValue(instance, getFile(ctx, name, contentType))
                } else {
                    mf.set(instance, getRequestParam<String>(ctx, name).toData())
                }
            } catch (_) {
                let variable = instanceTypeInfo.getInstanceProperty(name)
                let varTypeInfo = variable.typeInfo
                if (varTypeInfo.qualifiedName.startsWith("fountain/mvc.MultipartFile")) {
                    variable.setValue(instance, getFile(ctx, name, contentType))
                } else if (varTypeInfo.qualifiedName.startsWith("fountain/mvc.MultipartMixed")) {
                    variable.setValue(instance, getFile(ctx, name, contentType))
                } else {
                    mf.set(instance, getRequestParam<String>(ctx, name).toData())
                }
            }
        }
        return instance as T
    }
    let val = unsafe { ctx.request.url.queryForm.getAll(name).getRawArray() }
    let body: Array<String> = if (contentType == "application/x-www-urlencoded") {
        unsafe { ctx.request.form.getAll(name).getRawArray() }
    } else if (contentType.startsWith("multipart/form-data")) {
        match (MediaTypes.parse(contentType)) {
            case x: MultipartMediaType => unsafe { x.parse(ctx).form.getAll(name).getRawArray() }
            case _ => []
        }
    } else {
        []
    }
    if (val.isEmpty() && body.isEmpty()) {
        None<T>
    } else {
        let params = StringBuilder()
        func appendParams(val: Array<String>) {
            var i = 0
            while (i < val.size) {
                if (params.size > 0) {
                    params.append(",")
                }
                params.append(body[i])
                i++
            }
        }
        appendParams(val)
        appendParams(body)
        let d = T.tryFromData(params.toString().toData())
        match(d){
            case x: ?T => x
            case _ => None<T>
        }
    }
}

public func getHttpObject<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
    if(let x: T <- ctx){
        x
    }else if(let x: T <- ctx.responseBuilder){
        x
    }else if(let x: T <- ctx.request){
        x
    }else if(let x: T <- ctx.request.headers){
        x
    }else if(let x: T <- ctx.request.url){
        x
    }else if(let x: T <- ctx.request.form){
        x
    }else if(let Some(x) <- getRequestParam<T>(ctx, name)){
        x
    }else{
        throw HttpRequestException('${TypeInfos.get<T>()} does not match')
    }
}