/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_llm.tool

public struct FunctionMeta {
    public FunctionMeta(
        public let definition: JsonObject,
        public let callee: (JsonObject) -> FunctionResult
    ){}
    public init(
        definition: FunctionCall,
        callee: (JsonObject) -> FunctionResult
    ){
        this((JsonValue.fromData(definition.toData()) as JsonValue).getOrThrow().asObject(), callee)
    }
}
/**
 * 大模型函数调用的统一入口，所有函数实现都都需要注册到 FunctionMediator 中
 */
public struct FunctionMediator {
    private static let log = LoggerFactory.getLogger<FunctionMediator>()

    private init(){}
    private static let mutex = Mutex()
    private static let functions = ConcurrentHashMap<String, FunctionMeta>()
    private static let loaded = AtomicBool(false)

    public static func getDefinitions<I>(funcNames: I): Iterator<FunctionCall> where I <: Iterable<String> {
        funcNames.iterator().map{f =>
            let def = getMeta(f).definition.toData()
            let fncall = FunctionCall()
            DataObject<FunctionCall>.populate(def, fncall)
            fncall
        }
    }
    /**
     * 显式注册一个函数（内置函数与测试用）。
     *
     * 重名直接抛异常——同名函数在运行期共存会让模型看到两个定义、调用落到哪个看注册顺序，
     * 这种不确定性比启动失败更难查。
     */
    public static func register(calling: CommonFunctionCalling): Unit {
        ToolName.validate(calling.name)
        ensureLoaded()
        synchronized(mutex){
            if(functions.contains(calling.name)){
                throw FunctionCallingException('function already registered: ${calling.name}')
            }
            functions[calling.name] = FunctionMeta(calling.definition){args => calling.call(args)}
        }
    }

    /** 取函数定义原文（排查定义生成问题用，也便于工具表自检） */
    public static func definition(name: String): JsonObject {
        getMeta(name).definition
    }

    /** 已注册的函数名（按注册顺序不保证） */
    public static func names(): ArrayList<String> {
        ensureLoaded()
        let result = ArrayList<String>()
        for((name, _) in functions){
            result.add(name)
        }
        result
    }

    /**
     * 首次调用时扫描 @Bean；重复扫描没有意义，用 loaded 标记单飞。
     *
     * 两条容错规则：
     * 1. 扫描结果先落临时表、全部成功才合并——否则中途失败会留下“半张表”，
     *    下次重扫就会把自己上次塞进去的函数当成重名；
     * 2. 单个 bean 构造失败（缺依赖、配置不全）只跳过并记 `warn`，
     *    不能因为一个工具坏了就让整张工具表不可用。
     */
    private static func ensureLoaded(): Unit {
        if(loaded.load()){
            return
        }
        synchronized(mutex){
            if(loaded.load()){
                return
            }
            let scanned = HashMap<String, FunctionMeta>()
            for(bm in BeanFactory.instance.iterator<CommonFunctionCalling>()){
                var name = ''
                try{
                    let bean = bm.bean
                    if(let calling: CommonFunctionCalling <- bean){
                        name = calling.name
                        if(functions.contains(name) || scanned.contains(name)){
                            throw FunctionCallingException('function already registered: ${name}')
                        }
                        scanned[name] = FunctionMeta(calling.definition, callee(bm))
                        closeIfNeed(bm.meta.scope.isPrototype, bean)
                    }
                }catch(e: FunctionCallingException){
                    throw e
                }catch(e: Exception){
                    let failed = name
                    log.warn(e){'tool bean skipped: ${failed}'}
                }
            }
            for((name, meta) in scanned){
                functions[name] = meta
            }
            loaded.store(true)
        }
    }

    private static func getMeta(function: String): FunctionMeta {
        ensureLoaded()
        if(let Some(meta) <- functions.get(function)){
            meta
        }else{
            throw FunctionNotFoundException(function)
        }
    }
    public static func call(function: String, args: JsonObject): FunctionResult {
        getMeta(function).callee(args)
    }
    private static func callee(bm: BeanManager): (JsonObject) -> FunctionResult {
        let prototype = bm.meta.scope.isPrototype
        {json: JsonObject =>
            let bean = bm.bean
            try{
                (bean as CommonFunctionCalling).getOrThrow().call(json)
            }finally{
                closeIfNeed(prototype, bean)
            }
        }
    }
    private static func closeIfNeed(prototype: Bool, bean: Object){
        if(prototype && let r: Resource <- bean){
            r.close()
        }
    }
}