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
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T>
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
    protected func extractValue(name: String, ctx: HttpContext, default: ?String): ?String {
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
        if(list.isEmpty() && let Some(d) <- default){
            list = ArrayList<String>(d.split(','))
        }
        if (list.isEmpty()) {
            None<String>
        } else {
            concat(list)
        }
    }
}

@Annotation[target: [Parameter]]
public class RequestParam <: ControllerFuncParam {
    public const RequestParam(private let name: String, private let default!: ?String = None) {}
    public const init(default!: ?String = None) {
        this('', default: default)
    }
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext, _: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let n = if (this.name.isEmpty()) {
            name
        } else {
            this.name
        }
        if (let Some(s) <- extractValue(n, ctx, default)) {
            parseValue<T>(s, converter)
        } else {
            None<T>
        }
    }
}
@Annotation[target: [Parameter]]
public class RequestParamObject <: ControllerFuncParam {
    public const init(){}
    protected func extract<T>(name: String, _: ?AbstractDateTimeConverter, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        if(let ti <- TypeInfo.of<T>() && 
            let df: ObjectFields <- ti.getStaticFunction('dataFields', []).apply(ti, []) && 
            let o: T <- df.create() && let data: SimpleDataObject <- o.toData()){
            for(field in data.mutableFields()) {
                if(let Some(s) <- extractValue(field.name, ctx, None<String>)){
                    data.set(field.name, s.toData())
                }
            }
            return o
        }
        None<T>
    }
}

@Annotation[target: [Parameter]]
public class PathVariable <: ControllerFuncParam {
    public const PathVariable(private let name: String, private let default!: ?String = None) {}
    public const init(default!: ?String = None) {
        this('', default: default)
    }
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let path = ctx.request.url.path
        var value = pattern.extract(path, if (this.name.isEmpty()) {
            name
        } else {
            this.name
        })
        if(value.isNone() && default.isSome()){
            value = default
        }
        if (value.isNone()) {
            return None<T>
        }
        parseValue<T>(value, converter)
    }
}

@Annotation[target: [Parameter]]
public class RequestHeader <: ControllerFuncParam {
    public const RequestHeader(private let name: String, private let default!: ?String = None) {}
    public const init(default!: ?String = None) {
        this('', default: default)
    }
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        var value = ctx.request.headers.get(if (this.name.isEmpty()) {
            name
        } else {
            this.name
        })
        if(value.isEmpty() && let Some(d) <- default){
            value = d.split(',')
        }
        if (value.isEmpty()) {
            None<T>
        } else {
            let v = concat(value)
            parseValue<T>(v, converter)
        }
    }
}

@Annotation[target: [Parameter]]
public class RequestBody <: ControllerFuncParam {
    public const init() {}
    protected func extract<T>(name: String, _: ?AbstractDateTimeConverter, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let body = ctx.request.body
        let size = ctx.request.bodySize
        let contentType = ctx.request.headers.getFirst("Content-Type").getOrThrow()
        let mediaType = MediaTypes.parse(contentType)
        mediaType.toDataFields<T>(body)
    }
}
