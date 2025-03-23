/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
macro package f_bean.macros

import std.ast.*
import std.ast
import std.collection.HashMap
import std.convert.*
import std.sync.AtomicInt64
import f_bean.*
import f_bean.exception.BeanException
import f_macros.*

/**
 * 可修饰公共结构体或公共类。
 */
/*
    private var _name: String = ""
    private var _typeInfo = None<TypeInfo>
    private var _creator: () -> Any = {=> throw BeanException("creator func must be specified for BeanMeta of IOC.")}
    private var _postConstruct: (Any) -> Unit = defaultPostConstruct
    private var _destroy: (Any) -> Unit = defaultDestroy
    private var _order = 0
    private var _primary = false
    private var _scope = BeanScope.Singleton
    private var _lazy = true
    private var _condition: ?IBeanCondition = None
    private var _dependencies: Array<BeanDependency> = []
        let nameDef!: ?BeanNameDef = None,
        let typeDef!: ?TypeDef = None

 */
public macro Bean(attr: Tokens, input: Tokens) {
    var beanName = if (attr.size > 0) {
        attr[0].value
    } else {
        ""
    }
    let decl = parseDecl(input)
    let isPublic = isPublic(decl)
    if (isPublic && decl is CompositeDecl) {
        let composite = (decl as CompositeDecl).getOrThrow()
        var (scope, order, primary, lazy) = extractBeanAnnotations(composite.annotations)
        let genericParams = try{
            composite.genericParam.toTokens()
        }catch(e: Exception){
            `empty_tokens`
        }
        let typeName = composite.identifier
        let typeInfo = quote(TypeInfos.get<$(typeName)>())
        var di = 0
        var dependencies = `lsquare`
        for (message in getChildMessages("Autowired")) {
            // 确认依赖的bean
            let key = message.getString("dependencyKey")
            let pattern = message.getString("dependencyPattern")
            let qualifiedName = message.getString("dependencyType")
            let patternTokens = match (key) {
                case "name" => quote(WithName($(pattern)))
                case "prefix" => quote(WithPrefix($(pattern)))
                case "suffix" => quote(WithSuffix($(pattern)))
                case "wildcard" => quote(WithWildcard($(pattern)))
                case "regex" => quote(WithRegex($(pattern)))
                case _ => throw BeanException("illegal bean dependency pattern ${key}(${pattern})")
            }
            dependencies += if (di > 0) {
                `comma`
            } else {
                `empty_tokens`
            } + quote(
                BeanDependency(nameDef: $(patternTokens), typeDef: WithType($(qualifiedName)))
            )
            di++
        }
        dependencies += `rsquare`
        var postConstruct = quote(BeanMeta.defaultPostConstruct)
        var destroy = quote(BeanMeta.defaultDestroy)
        for (d in composite.body.decls where d is FuncDecl) {
            let fn = (d as FuncDecl).getOrThrow()
            for (a in fn.annotations) {
                func genFn() {
                    quote(
                        {o => match(o){
                        case x: $(typeName) => x.$(fn.identifier)()
                        case _ => ()
                    }})
                }
                match (a) {
                    case x: PostConstruct => postConstruct = genFn()
                    case x: Destroy => destroy = genFn()
                    case _ => ()
                }
            }
        }
        let constructors = getChildMessages("Constructor")
        input + `nl` +
        if (constructors.isEmpty()) {
            quote(
                let _ = {=>
                    let meta = BeanMeta.create<$(typeName)>(
                        beanName: $(beanName),
                        creator: {=>$(typeName)()},
                        postConstruct: $(postConstruct),
                        destroy: $(destroy),
                        dependeicies: $(dependencies)
                    )
                    App.beanFactory.register(meta)
                }()
            )
        } else if(constructors.size == 1) {
            // 从@Constructor 获取构造函数或静态工厂函数
            generateConstructors(typeName)
        } else {
            throw BeanException("There must be one or none @Constructor as inner macro for @Bean.")
        }
    } else {
        throw BeanException("macro @Bean can modify public class or public struct.")
    }
}
func extractBeanAnnotations(annotations: ArrayList<ast.Annotation>): (BeanScope, Int64, Bool, Bool) {
    var scope = BeanScope.Singleton
    var primary = false
    var order = 0
    var lazy = true
    for (annotation in annotations) {
        let value = annotation.arguments[0].toTokens().toString().trimAscii()
        match (annotation.identifier.value) {
            case "Order" => order = Int64.parse(value)
            case "Scope" => scope = match (value) {
                case "Singleton" => Singleton
                case "Prototype" => Prototype
                case _ => continue
            }
            case "Primary" => primary = Bool.parse(value)
            case "Lazy" => lazy = Bool.parse(value)
            case _ => ()
        }
    }
    (scope, order, primary, lazy)
}
