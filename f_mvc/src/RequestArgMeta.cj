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

class RequestArgMeta {
    private let args = HashMap<String, (ControllerFuncParam, Validator)>()
    private func doExtract<T>(ctx: HttpContext, name: String, pattern: ?HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        let (param, validator) = args[name]
        let data = param.extract<T>(name, ctx, pattern.getOrThrow())
        if(let Some(x) <- data){
            match(x){
                case x: ToDataFields => 
                    func validate(fields: Iterator<ReadableField>): Unit {
                        for(df in fields){
                            match(df.get(x)){
                                case x: SimpleDataObject => validate(x.fields())
                                case x => 
                                    let value = x.toString()
                                    if(!df.validator.validate(value)){
                                        throw HttpRequestException('type of parameter ${name} is ${TypeInfo.of(x)}, its field ${df.name} ${df.typeInfo} is not valid, field value is ${value}')
                                    }
                            }
                        }
                    }
                    validate(x.getDataFields().iterator())
                case x where !validator.validate(x.toData().toString()) => 
                    throw HttpRequestException('parameter ${name} is not valid, which value is ${data.toData()}')
                case _ => () 
            }
        } else if(!validator.validate('')) {
            throw HttpRequestException('parameter ${name} is not valid, which value is ${data.toData()}')
        }
        data
    }
    func extract<T>(ctx: HttpContext, name: String, pattern: ?HttpRequestPathPatterns): T where T <: DataFields<T> {
        doExtract<T>(ctx, name, pattern).getOrThrow()
    }
    func extract<T>(ctx: HttpContext, name: String, default: T, pattern: ?HttpRequestPathPatterns): T where T <: DataFields<T> {
        doExtract<T>(ctx, name, pattern) ?? default
    }
    func extractObject<T>(ctx: HttpContext, name: String, pattern: ?HttpRequestPathPatterns): T where T <: Object & ObjectData<T> {
        let (param, validator) = args[name]
        param.extractObject<T>(name, ctx, pattern.getOrThrow())
    }
    func contains(name: String): Bool {
        args.contains(name)
    }

    operator func [](name: String): ControllerFuncParam {
        args[name][0]
    }
    operator func [](name: String, value!: ControllerFuncParam): Unit {
        args[name] = if(let Some((p, v)) <- args.get(name)){
            (value, v)
        }else{
            (value, DummyValidator.instance)
        }
    }
    func add(all!: HashMap<String, (ControllerFuncParam, Validator)>): Unit {
        args.add(all: all)
    }
}