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

sealed abstract class WSFuncMeta {
    WSFuncMeta(public let name: String){}
    let args = RequestArgMeta()
    private var handle: (HttpContext) -> Unit = {_ => }

    public func setHandle(handle: (HttpContext) -> Unit): Unit {
        this.handle = handle
    }
    public func exec(ctx: HttpContext): Unit {
        handle(ctx)
    }
}
public class WSOpenMeta <: WSFuncMeta {
    init(name: String){
        super(name)
    }
}
public class WSCloseMeta <: WSFuncMeta {
    init(name: String){
        super(name)
    }
}
public class WSTextMeta <: WSFuncMeta {
    init(name: String){
        super(name)
    }
}
public class WSBinaryMeta <: WSFuncMeta {
    init(name: String){
        super(name)
    }
}
public class WSPingMeta <: WSFuncMeta {
    init(name: String){
        super(name)
    }
}

public class WSMeta {
    var pattern = None<HttpRequestPathPatterns>
    private var openMeta_ = None<WSOpenMeta>
    private var closeMeta_ = None<WSCloseMeta>
    private var textMeta_ = None<WSTextMeta>
    private var binaryMeta_ = None<WSBinaryMeta>
    private var pingMeta_ = None<WSPingMeta>

    public prop openMeta: ?WSOpenMeta {
        get(){
            openMeta_
        }
    }
    public prop closeMeta: ?WSCloseMeta {
        get(){
            closeMeta_
        }
    }
    public prop textMeta: ?WSTextMeta {
        get(){
            textMeta_
        }
    }
    public prop binaryMeta: ?WSBinaryMeta {
        get(){
            binaryMeta_
        }
    }
    public prop pingMeta: ?WSPingMeta {
        get(){
            pingMeta_
        }
    }
    
    private func doExtractArgOption<T, M>(meta: ?M, ctx: HttpContext, name: String): T where T <: DataFields<T>, M <: WSFuncMeta {
        meta?.args.extract<T>(ctx, name, pattern)
    }
    private func doExtractArg<T, M>(meta: ?M, ctx: HttpContext, name: String): T where T <: DataFields<T>, M <: WSFuncMeta {
        doExtractArgOption<T, M>(meta, ctx, name).getOrThrow()
    }
    private func doExtractArg<T, M>(meta: ?M, ctx: HttpContext, name: String, default: T): T where T <: DataFields<T>, M <: WSFuncMeta {
        doExtractArgOption<T, M>(meta, ctx, name) ?? default
    }

    public func extractOpenArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(openMeta_, ctx, name)
    }
    public func extractOpenArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(openMeta_, ctx, name, default)
    }
    public func extractCloseArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(closeMeta_, ctx, name)
    }
    public func extractCloseArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(closeMeta_, ctx, name, default)
    }
    public func extractTextArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(textMeta_, ctx, name)
    }
    public func extractTextArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(textMeta_, ctx, name, default)
    }
    public func extractBinaryArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(binaryMeta_, ctx, name)
    }
    public func extractBinaryArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(binaryMeta_, ctx, name, default)
    }
    public func extractPingArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(pingMeta_, ctx, name)
    }
    public func extractPingArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(pingMeta_, ctx, name, default)
    }

    public static func generate<T>() : WSMeta where T <: Object {
        let endpointClass = TypeInfo.of<T>()
        let meta = WSMeta()
        for(function in endpointClass.instanceFunctions) {
            let funcName = function.name
            let funcMeta = 
            if(let Some(annotation) <- function.findAnnotation<OnWSOpen>()){
                let m = WSOpenMeta(funcName)
                meta.openMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSClose>()){
                let m = WSCloseMeta(funcName)
                meta.closeMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSBinary>()){
                let m = WSBinaryMeta(funcName)
                meta.binaryMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSText>()){
                let m = WSTextMeta(funcName)
                meta.textMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSPing>()){
                let m = WSPingMeta(funcName)
                meta.pingMeta_ = m
                m
            }else{
                continue
            }
            for (param in function.parameters) {
                let pname = param.name
                var toThrow = true
                for (annotation in param.annotations where annotation is ControllerFuncParam) {
                    funcMeta.args[pname] = (annotation as ControllerFuncParam).getOrThrow()
                    toThrow = false
                    break
                }
                if(toThrow){
                    throw MVCException(
                        'parameter of controller function must be with one and only one Annotation as @RequestBody or @RequestParam or @RequestHeader or @PathVariable or @MultipartFormData')
                }
            }
        }
        meta
    }
}