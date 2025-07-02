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

abstract class ControllerFuncParam {
    protected const init() {}
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T>
    static func concat(list: Collection<String>) {
        let b = StringGenerator()
        for (v in list) {
            if (b.size > 0) {
                b.append(',')
            }
            b.append(v)
        }
        b.toString()
    }
}

@Annotation[target: [MemberFunction]]
public class RequestParam <: ControllerFuncParam {
    public const init() {}
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let request = ctx.request
        let form = request.form
        var list: List<String> = EmptyList<String>.INSTANCE()
        if (let l <- form.getAll(name) && l.size > 0) {
            list = l
        } else {
            let url = request.url
            if (url.rawQuery.isSome()) {
                let f = url.queryForm
                if (!refEq(f, form) && let l <- f.getAll(name) && l.size > 0) {
                    list = l
                }
            }
        }
        let value = concat(list)
        if (value.isEmpty()) {
            None<T>
        } else {
            parseValue<T>(value)
        }
    }
}

@Annotation[target: [MemberFunction]]
public class PathVariable <: ControllerFuncParam {
    public const init() {}
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let path = ctx.request.url.path
        let value = pattern.extract(path, name)
        if (let None <- value) {
            return None<T>
        }
        parseValue<T>(value)
    }
}

@Annotation[target: [MemberFunction]]
public class RequestHeader <: ControllerFuncParam {
    public const init() {}
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let value = ctx.request.headers.get(name)
        if (value.isEmpty()) {
            None<T>
        } else {
            let v = concat(value)
            parseValue<T>(v)
        }
    }
}

@Annotation[target: [MemberFunction]]
public class RequestBody <: ControllerFuncParam {
    public const init() {}
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let body = ctx.request.body
        let size = ctx.request.bodySize
        let contentType = ctx.request.headers.getFirst("Content-Type").getOrThrow()
        let mediaType = MediaTypes.parse(contentType)
        mediaType.toDataFields<T>(body)
    }
}

@Annotation[target: [MemberFunction]]
public class MultipartFormData <: ControllerFuncParam {
    public const init() {}

    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        throw MVCException()
    }
    public func multipart<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: ObjectData<T> & DataFields<T> {
        let multiparts = MultipartFormDataParser(ctx).parse()
        let fields = T.dataFields()
        let object = fields.create()
        let mutables = fields.mutableFields()
        for (mf in mutables) {
            let name = mf.name
            let data = match (multiparts.get(name)) {
                case Some(x: MultipartFile) => x.toData()
                case Some(x: ArrayList<MultipartMedia>) =>
                    if (x.size == 1) {
                        x[0].toData()
                    } else {
                        x.toData()
                    }
                case _ => throw MVCException(
                    'media type of field ${name} in ${TypeInfos.get<T>()} cannot be parsed from multipart request')
            }
            mf.set(object, data)
        }
        object
    }
}
