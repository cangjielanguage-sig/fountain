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

abstract class ControllerFuncParam {
    protected const init() {}
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext,
        pattern: HttpRequestPathPatterns, validator: Validator): ?T where T <: DataFields<T>
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
    protected func validate<T>(name: String, value: ?String, validator: Validator) {
        if (!validator.validate(value)) {
            throw ValidationException(if (validator.messageIfNotMatch.size > 0) {
                validator.messageIfNotMatch
            } else {
                'Invalid request data ${name}:${value} and its type is ${TypeInfo.of<T>()}'
            })
        }
    }
}

abstract sealed class AbstractRequestParam <: ControllerFuncParam {
    public const init() {}
    protected func extractValue(name: String, ctx: HttpContext, default: ?String): ?String {
        let request = ctx.request
        let form = request.form
        var list: List<String> = EmptyList<String>.instance()
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
        if (list.isEmpty() && let Some(_) <- default) {
            default
        } else if (list.isEmpty()) {
            None<String>
        } else {
            concat(list)
        }
    }
}

@Annotation[target: [Parameter]]
public class RequestParam <: AbstractRequestParam {
    public const RequestParam(private let name: String, private let default!: ?String = None) {}
    public const init(default!: ?String = None) {
        this('', default: default)
    }
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext,
        _: HttpRequestPathPatterns, validator: Validator): ?T where T <: DataFields<T> {
        let n = if (this.name.isEmpty()) {
            name
        } else {
            this.name
        }
        let value = extractValue(n, ctx, default)
        validate<T>(n, value, validator)
        if (let Some(s) <- value) {
            parseValue<T>(s, converter)
        } else {
            None<T>
        }
    }
}

@Annotation[target: [Parameter]]
public class RequestParamObject <: AbstractRequestParam {
    public const init() {}
    protected func extract<T>(name: String, _: ?AbstractDateTimeConverter, ctx: HttpContext,
        pattern: HttpRequestPathPatterns, _: Validator): ?T where T <: DataFields<T> {
        if (let ti <- TypeInfo.of<T>() && let df: ObjectFields <- ti.getStaticFunction('dataFields', []).apply(ti, []) &&
            let o: T <- df.create() && let data: SimpleDataObject <- o.toData()) {
            for (field in data.mutableFields()) {
                if (let Some(s) <- extractValue(field.name, ctx, None<String>)) {
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
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext,
        pattern: HttpRequestPathPatterns, validator: Validator): ?T where T <: DataFields<T> {
        let path = ctx.request.url.path
        let n = if (this.name.isEmpty()) {
            name
        } else {
            this.name
        }
        var value = pattern.extract(path, n)
        if (value.isNone() && default.isSome()) {
            value = default
        }
        validate<T>(n, value, validator)
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
    protected func extract<T>(name: String, converter: ?AbstractDateTimeConverter, ctx: HttpContext,
        pattern: HttpRequestPathPatterns, validator: Validator): ?T where T <: DataFields<T> {
        let n = if (this.name.isEmpty()) {
            name
        } else {
            this.name
        }
        var value = ctx.request.headers.get(n)
        if (value.isEmpty() && let Some(d) <- default) {
            value = d.split(',')
        }
        let v = if (value.isEmpty()) {
            ''
        } else {
            concat(value)
        }
        validate<T>(n, v, validator)
        if (value.isEmpty()) {
            None<T>
        } else {
            parseValue<T>(v, converter)
        }
    }
}

@Annotation[target: [Parameter]]
public class RequestBody <: ControllerFuncParam {
    public const init() {}
    protected func extract<T>(name: String, _: ?AbstractDateTimeConverter, ctx: HttpContext,
        pattern: HttpRequestPathPatterns, _: Validator): ?T where T <: DataFields<T> {
        let body = ctx.request.body
        let mediaType = requestBodyMediaType(ctx.request.headers.getFirst("Content-Type"))
        mediaType.toDataFields<T>(body)
    }
}

/**
 * 包内接缝（§2.2 / `MVC-C3`）：`@RequestBody` 的媒体类型解析。
 * Content-Type 缺失 / 空串 / 未注册时不再 getOrThrow（原先抛 NoneValueException /
 * MediaTypeException ⇒ 500），而是 perform `MVCBreakingCommand(415)`：由请求链上
 * `RequestMeta.setHandle` 里既有的 `handle (cmd: MVCBreakingCommand)` 分支直接回
 * 「Unsupported Media Type」，与路由层对未知 Content-Type 的 415 约定一致
 * （`MultiRequestMethodHandler.cj:22,80`）。未被 handler 接住时由 Command.defaultImpl()
 * 抛 UnhandledCommandException，退化为原先的 500，不会静默放行。
 */
func requestBodyMediaType(contentType: ?String): MediaType {
    match (MediaTypes.tryParse(contentType ?? '')) {
        case Some(ct) => ct
        case _ =>
            perform MVCBreakingCommand(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
            throw UnreachableException('MVC-C3: no Content-Type, request should have ended with 415')
    }
}
