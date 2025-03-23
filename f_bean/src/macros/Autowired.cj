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
import f_macros
import f_exception.UnreachableException
import f_bean.*

/**
 * attr长度可以是0，表示没有指定bean 名字的匹配模式
 * attr长度是1时，attr表示要查找的bean的名字
 * attr还可以是name=beanName prefix=beanNamePrefix suffix=beanNameSuffix pattern = bean*ame等
 * @Autowired[beanName]
 * private let value: Bean
 *
 * @Autowired[name=beanName]//还支持prefix=beanNamePrefix suffix=... wildcard=... regex=...
 * private let value: Bean
 *
 * 本宏可以修饰成员变量或成员函数，但是不支持成员变量形参。
 * 修饰成员函数时会用生成的代码覆盖原函数体，生成的代码从BeanFactory获取实例。
 */
public macro Autowired(attr: Tokens, input: Tokens): Tokens {
    var key = ""
    var pattern = ""
    let decl = parseDecl(input)
    let inject = decl.annotations
    if (attr.size == 1) {
        pattern = attr[0].value
        key = "name"
    } else {
        pattern = attr[2].value
        key = attr[0].value
    }
    if (decl is VarDecl) {
        generateAssignment(key, pattern, (decl as VarDecl).getOrThrow())
    } else if (decl is FuncDecl){
        generateLookupFuncBody(key, pattern, (decl as FuncDecl).getOrThrow())
    } else {
        throw BeanException("macro @Autowired can modify member variable or member func, however current is ${input}")
    }
}
func generateAssignment(key: String, pattern: String, decl: VarDecl){
    let colon = decl.colon
    let typeToken =
    if(colon.kind == ILLEGAL){
        f_macros.`any`
    }else{
        decl.declType.toTokens()
    }
    if(insideParentContext("Bean")){
        setItem("dependencyKey", key)
        setItem("dependencyPattern", pattern)
        setItem("dependencyType", typeToken.toString().replace(" ", ""))
    }

    decl.assign = f_macros.`assign`[0]
    decl.expr = CallExpr(generateBeanGetter(key, pattern, typeToken))
    decl.toTokens()
}
func generateLookupFuncBody(key: String, pattern: String, decl: FuncDecl){
    var result = f_macros.`empty_tokens`
    for(token in decl.toTokens()){
        if(token.kind != LCURL){
            result += token
        }else{
            break
        }
    }
    let colon = decl.colon
    let returnType =
    if(colon.kind == ILLEGAL){
        f_macros.`any`
    }else{
        decl.declType.toTokens()
    }
    let body = decl.block
    body.lBrace = f_macros.`lcurl`[0]
    body.nodes.add(CallExpr(f_macros.`nl` + generateBeanGetter(key, pattern, returnType) + f_macros.`nl`))
    body.rBrace = f_macros.`rcurl`[0]
    decl.toTokens()
}
func generateBeanGetter(key: String, pattern: String, typeToken: Tokens) {
    if(pattern == "" && typeToken[0].value == "Option"){
        quote(
            App.beanFactory.getFirst<$(typeToken[2 .. typeToken.size - 1])>()
        )
    }else if (pattern == "" && typeToken[0].value == "?"){
        quote(
            App.beanFactory.getFirst<$(typeToken[1 .. typeToken.size])>()
        )
    } else if (pattern == "" && typeToken[0].value == "ArrayList") {
        quote(
            ArrayList<$(typeToken[2 .. typeToken.size - 1])>(App.beanFactory.get<$(typeToken[2 .. typeToken.size - 1])>().values())
        )
    } else if (pattern == "" && (typeToken[0].value == "HashSet" || typeToken[0].value == "Set")) {
        quote(
            HashSet<$(typeToken[2 .. typeToken.size - 1])>(App.beanFactory.get<$(typeToken[2 .. typeToken.size - 1])>().values())
        )
    } else if (pattern == "" && (typeToken[0].value == "HashMap" || typeToken[0].value == "Map")) {
        quote(
            HashMap<String, $(typeToken[4 .. typeToken.size - 1])>(App.beanFactory.get<$(typeToken[4 .. typeToken.size - 1])>())
        )
    } else if (pattern == "") {
        let exMsg = "bean type of ${typeToken.toString()} is not found"
        quote(
            App.beanFactory.get<$typeToken>().getOrThrow{BeanException($exMsg)}
        )
    } else if(key == "name" && typeToken[0].value == "Option"){
        quote(
            App.beanFactory.get<$(typeToken[2 .. typeToken.size - 1])>($(pattern))
        )
    }else if(key == "name" && typeToken[0].value == "?"){
        quote(
            App.beanFactory.get<$(typeToken[1 .. typeToken.size])>($(pattern))
        )
    }else if (key == "name" && typeToken[0].value == "ArrayList") {
        quote(
            ArrayList<$(typeToken[2 .. typeToken.size - 1])>([App.beanFactory.get<$(typeToken[2 .. typeToken.size - 1])>($(pattern))])
        )
    } else if (key == "name" && (typeToken[0].value == "HashSet" || typeToken[0].value == "Set")) {
        quote(
            HashSet<$(typeToken[2 .. typeToken.size - 1])>(App.beanFactory.get<$(typeToken[2 .. typeToken.size - 1])>($(pattern)))
        )
    } else if (key == "name" && (typeToken[0].value == "HashMap" || typeToken[0].value == "Map")) {
        quote(
            HashMap<String, $(typeToken[4 .. typeToken.size - 1])>(App.beanFactory.get<$(typeToken[4 .. typeToken.size - 1])>($(pattern)))
        )
    } else if(key == "name"){
        let exMsg = "bean type of ${typeToken.toString()} named as ${pattern} is not found"
        quote(
            App.beanFactory.get<$typeToken>($(pattern)).getOrThrow{BeanException($(exMsg))}
        )
    } else if (key == "prefix" && typeToken[0].value == "Option") {
        quote(
            App.beanFactory.getFirstByPrefix<$(typeToken[2 .. typeToken.size - 1])>($(pattern))
        )
    } else if (key == "prefix" && typeToken[0].value == "?") {
        quote(
            App.beanFactory.getFirstByPrefix<$(typeToken[1 .. typeToken.size])>($(pattern))
        )
    }else if (key == "prefix" && typeToken[0].value == "ArrayList") {
        quote(
            {=> let list = ArrayList<$(typeToken[2 .. typeToken.size - 1])>()
                  list.appendAll(App.beanFactory.getByPrefix<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  list
            }()
        )
    } else if (key == "prefix" && (typeToken[0].value == "HashSet" || typeToken[0].value == "Set")) {
        quote(
            {=> let set = HashSet<$(typeToken[2 .. typeToken.size - 1])>()
                  set.putAll(App.beanFactory.getByPrefix<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  set
            }()
        )
    } else if (key == "prefix" && (typeToken[0].value == "HashMap" || typeToken[0].value == "Map")) {
        quote(
            {=> let map = HashMap<String, $(typeToken[4 .. typeToken.size - 1])>()
                  map.putAll(App.beanFactory.getByPrefix<$(typeToken[4 .. typeToken.size - 1])>($(pattern)))
                  map
            }()
        )
    } else if(key == "prefix"){
        let exMsg = "bean type of ${typeToken.toString()} name prefix as ${pattern} is not found"
        quote(
            App.beanFactory.getFirstByPrefix<$typeToken>($(pattern)).getOrThrow{BeanException($exMsg)}
        )
    } else if(key == "suffix" && typeToken[0].value == "Option"){
        quote(
            App.beanFactory.getFirstBySuffix<$(typeToken[2 .. typeToken.size - 1])>($(pattern))
        )
    } else if(key == "suffix" && typeToken[0].value == "?") {
        quote(
            App.beanFactory.getFirstBySuffix<$(typeToken[1 .. typeToken.size])>($(pattern))
        )
    } else if (key == "suffix" && typeToken[0].value == "ArrayList") {
        quote(
            {=> let list = ArrayList<$(typeToken[2 .. typeToken.size - 1])>()
                  list.appendAll(App.beanFactory.getBySuffix<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  list
            }()
        )
    } else if (key == "suffix" && (typeToken[0].value == "HashSet" || typeToken[0].value == "Set")) {
        quote(
            {=> let set = HashSet<$(typeToken[2 .. typeToken.size - 1])>()
                  set.putAll(App.beanFactory.getBySuffix<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  set
            }()
        )
    } else if (key == "suffix" && (typeToken[0].value == "HashMap" || typeToken[0].value == "Map")) {
        quote(
            {=> let map = HashMap<String, $(typeToken[4 .. typeToken.size - 1])>()
                  map.putAll(App.beanFactory.getBySuffix<$(typeToken[4 .. typeToken.size - 1])>($(pattern)))
                  map
            }()
        )
    } else if(key == "suffix"){
        let exMsg = "bean type of ${typeToken.toString()} name suffix as ${pattern} is not found"
        quote(
            App.beanFactory.getFirstBySuffix<$typeToken>($(pattern)).getOrThrow{BeanException($(exMsg))}
        )
    } else if(key == "wildcard" && typeToken[0].value == "Option"){
        quote(
            App.beanFactory.getFirstWithWildcard<$(typeToken[2 .. typeToken.size - 1])>($(pattern))
        )
    } else if (key == "wildcard" && typeToken[0].value == "?") {
        quote(
            App.beanFactory.getFirstWithWildcard<$(typeToken[1 .. typeToken.size])>($(pattern))
        )
    } else if (key == "wildcard" && typeToken[0].value == "ArrayList") {
        quote(
            {=> let list = ArrayList<$(typeToken[2 .. typeToken.size - 1])>()
                  list.appendAll(App.beanFactory.getWithWildcard<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  list
            }()
        )
    } else if (key == "wildcard" && (typeToken[0].value == "HashSet" || typeToken[0].value == "Set")) {
        quote(
            {=> let set = HashSet<$(typeToken[2 .. typeToken.size - 1])>()
                  set.putAll(App.beanFactory.getWithWildcard<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  set
            }()
        )
    } else if (key == "wildcard" && (typeToken[0].value == "HashMap" || typeToken[0].value == "Map")) {
        quote(
            {=> let map = HashMap<String, $(typeToken[4 .. typeToken.size - 1])>()
                  map.putAll(App.beanFactory.getWithWildcard<$(typeToken[2 .. typeToken.size - 1])>($(pattern)))
                  map
            }()
        )
    } else if (key == "wildcard"){
        let exMsg = "bean type of ${typeToken.toString()} name wildcard as ${pattern} is not found"
        quote(
            App.beanFactory.getFirstWithWildcard<$typeToken>($(pattern)).getOrThrow{BeanException($exMsg)}
        )
    }else if(key == "regex" && typeToken[0].value == "Option"){
        quote(
            App.beanFactory.getFirstWithRegex<$(typeToken[2 .. typeToken.size - 1])>($(pattern))
        )
    }else if(key == "regex" &&  typeToken[0].value == "?"){
        quote(
            App.beanFactory.getFirstWithRegex<$(typeToken[1 .. typeToken.size])>($(pattern))
        )
    } else if (key == "regex" && typeToken[0].value == "ArrayList") {
        quote(
            {=> let list = ArrayList<$(typeToken[2 .. typeToken.size - 1])>()
                  list.appendAll(App.beanFactory.getWithRegex<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  list
            }()
        )
    } else if (key == "regex" && (typeToken[0].value == "HashSet" || typeToken[0].value == "Set")) {
        quote(
            {=> let set = HashSet<$(typeToken[2 .. typeToken.size - 1])>()
                  set.putAll(App.beanFactory.getWithRegex<$(typeToken[2 .. typeToken.size - 1])>($(pattern)).values())
                  set
            }()
        )
    } else if (key == "regex" && (typeToken[0].value == "HashMap" || typeToken[0].value == "Map")) {
        quote(
            {=> let map = HashMap<String, $(typeToken[4 .. typeToken.size - 1])>()
                  map.putAll(App.beanFactory.getWithRegex<$(typeToken[4 .. typeToken.size - 1])>($(pattern)))
                  map
            }()
        )
    }else if (key == "regex"){
        let exMsg = "bean type of ${typeToken.toString()} name regex as ${pattern} is not found"
        quote(
            App.beanFactory.getFirstWithRegex<$typeToken>($(pattern)).getOrThrow{BeanException($exMsg)}
        )
    }else{
        let exMsg = "bean type of ${typeToken.toString()} named as ${pattern} is not found"
        quote(
            App.beanFactory.get<$typeToken>($(pattern)).getOrThrow{BeanException($exMsg)}
        )
    }
}
