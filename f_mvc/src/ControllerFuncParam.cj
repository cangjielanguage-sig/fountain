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

@Annotation[target: [Parameter]]
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

@Annotation[target: [Parameter]]
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

@Annotation[target: [Parameter]]
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

@Annotation[target: [Parameter]]
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

@Annotation[target: [Parameter]]
public class MultipartFormData <: ControllerFuncParam {
    public const init() {}

    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        throw MVCException()
    }
    public func multipart<T>(ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: ObjectData<T> & DataFields<T> {
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
