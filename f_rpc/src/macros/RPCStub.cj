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
macro package fountain::f_rpc.macros

import std.ast.*
/**
 * attr 用于指定skeleton的版本号、fountain::f_bean名称、是否精确版本号，分别有以下属性：
 * 
 * version: 指定skeleton的版本号，没有默认值，不指定将报错。version 包含两位或三位版本数字。
 * name: 指定fountain::f_bean名称，默认为空
 * exactlyVersion: 是否精确版本号，默认为false。false时只保留version的前两位版本数字，true时保留version的所有版本数字。
 * 格式：version='1.0.0' name=beanName exactlyVersion=true
 * **注意**：目前只能实现被RPCStub修饰的接口直接声明的实例成员函数，不能实现属性，也不能实现父接口的函数
 * 当存在环境变量rpc_currentSkeleton，且变量值与当前项目名称一致时或者与被@RPCStub修饰的接口有相同的包名，宏RPCStub展开的代码将不会注册到IOC
 */
public macro RPCStub(attr: Tokens, input: Tokens): Tokens {
    var version = ''
    var name = ''
    var exactlyVersion = false
    var i = 0
    while (i < attr.size){
        let t = attr[i]
        match(t.value){
            case 'name' => 
                i += 2
                name = attr[i].value
            case 'version' =>
                i += 2
                version = attr[i].value
            case 'exactlyVersion' =>
                i += 2
                exactlyVersion = attr[i].value == 'true'
            case _ => ()
        }
        i++
    }
    if(version == ''){
        diagReport(DiagReportLevel.ERROR, attr, 'version is required for attr of fountain::f_rpc.RPCStub', '')
        throw RPCException()
    }
    genStub(exactlyVersion, version, name, parseDecl(input))
}
private func genStub(exactlyVersion: Bool, version: String, name: String, decl: Decl): Tokens {
    try{
        decl.genericParam
        diagReport(DiagReportLevel.ERROR, decl.toTokens(), 'decl ${decl.identifier.value} must not be with generic param fountain::f_rpc stub', '')
        throw RPCException()
    }catch(_){}
    var tokens = `empty_tokens`
    match(decl){
        case x: InterfaceDecl => 
            let typeName = x.identifier
            for(d in x.body.decls){
                if(let f: FuncDecl <- d && !isStatic(f)){
                    if(tokens.size > 0){
                        tokens += `nl`
                    }
                    tokens += genStub(exactlyVersion, version, name, typeName, f)
                }else{
                    diagReport(DiagReportLevel.ERROR, d.toTokens(), 'decl ${d.identifier.value} in ${x.identifier.value} must be a instance func decl for fountain::f_rpc stub', '')
                    throw RPCException()
                }
            }
        case x => 
            diagReport(DiagReportLevel.ERROR, decl.toTokens(), '${x.identifier.value} must be a interface decl', '')
            throw RPCException()
    }
    let className = Token(IDENTIFIER, '${decl.identifier.value}_Stub__')
    quote(
        $decl
        public class $(className) <: $(decl.identifier){
            $tokens
        }
        private let _ = {=>
            let skeleton = ClientConfig.currentSkeleton
            let klass = TypeInfo.of<$(className)>()
            let qualified = klass.qualifiedName
            let modStart = (qualified.indexOf('::') ?? -1) + 1
            let modEnd = qualified.indexOf('.', modStart).getOrThrow()
            if(skeleton == '' || !(skeleton == qualified[0 .. modEnd] || skeleton == qualified[modStart .. modEnd])) {
                BeanFactory.instance.register<$(className)>{$(className)()}
            }
        }()
    )
}
private func genStub(exactlyVersion: Bool, version: String, name: String, typeName: Token, decl: FuncDecl): Tokens {
    var argTypes = `lsquare`
    var argValues = `lsquare`
    for(arg in decl.funcParams){
        if(argTypes.size > 1){
            argTypes += `comma`
            argValues += `comma`
        }
        argTypes += quote(TypeInfo.of<$(arg.paramType)>().qualifiedName)
        argValues += quote(DataAny($(arg.identifier).toData()))
    }
    argTypes = `rsquare`
    argValues = `rsquare`
    quote(
        public func $(decl.identifier)($(decl.funcParams)): $(decl.declType) {
            let version = $(version)
            let name = $(name)
            let typeName = TypeInfo.of<$(typeName)>().qualifiedName
            let methodName = $(decl.identifier.value)
            let argTypeNames = $(argTypes)
            let meta = ServiceMeta(version, name, typeName, methodName, argTypeNames, exactlyVersion: $exactlyVersion)
            let args: Array<Data> = $(argValues)
            let message = RPCMessage(meta, args)
            RPCClient.call<$(decl.declType)>(message)
        }
    )
}