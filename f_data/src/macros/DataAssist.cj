/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

macro package f_data.macros

import std.ast.*
import std.collection.{HashSet, ArrayList}
import f_data.*
import f_macros.*

/*
 * Props Hash Compare Equal ToString Fields
 */
public macro DataAssist(attr: Tokens, input: Tokens): Tokens {
    let set = HashSet<String>()
    for (t in attr) {
        set.put(t.value.toAsciiLower())
    }
    func generate(tag: String, decl: CompositeDecl, fn: (CompositeDecl) -> Unit): Unit {
        if(set.contains(tag)){
            fn(decl)
        }
    }
    let decl = parseDecl(input)
    match(decl){
        case d: CompositeDecl =>
            generate('props', d, generateProps)
            generate('hash', d, generateHash)
            generate('equal', d, generateEqual)
            generate('compare', d, generateCompare)
            generate('tostring', d, generateToString)
            if(d is ClassDecl){
                generate('fields', d, generateToFields)
            }else if(set.contains('fields')){
                throw IllegalArgumentException('input must be a class for fields attr of @DataAssist')
            }
            decl.toTokens()
        case _ =>
            throw IllegalArgumentException("input must be a struct decl or a class decl")
    }
}
func generateProps(decl: CompositeDecl){
    let decls = decl.body.decls
    let appended = ArrayList<Decl>()
    for(decl in decls){
        match(decl){
            case d: VarDecl where !(d.isStatic() || d.isPublic()) =>
                let propIdentifier = decl.identifier
                let varName = Token(IDENTIFIER, "_${propIdentifier.value}_")
                decl.identifier = varName
                let propDecl =
                if(decl.keyword.kind == VAR){
                    parseDecl(quote(
                        public mut prop $propIdentifier{
                            get(){
                                $varName
                            }
                            set(value){
                                $varName = value
                            }
                        }
                    ))
                }else{
                    parseDecl(quote(
                        public prop $propIdentifier{
                            get(){
                                $varName
                            }
                        }
                    ))
                }
                appended.append(propDecl)
            case _ => continue
        }
    }
    decls.appendAll(appended)
}
func generateHash(d: CompositeDecl){
    if(d.superTypes.isEmpty()){
        d.upperBound = `upperbound`[0]
    }
    d.superTypes.append(RefType(quote(Hashable)))
    var hashed = `nl`
    for(d in d.body.decls where d is VarDecl){
        hashed += quote(
            match($(d.identifier)){
                case x: Hashable => hasher.write(x.hashCode())
                case _ => ()
            }
        ) + `nl`
    }
    d.body.decls.append(parseDecl(quote(
        private var __hAsh__ = 0
    )))
    d.body.decls.append(parseDecl(quote(
        public func hashCode(): Int64{
            if(__hAsh__ == 0){
                let hasher = DefaultHasher()
                $hashed
                __hAsh__ = hasher.finish()
            }
            __hAsh__
        }
    )))
}
func generateEqual(d: CompositeDecl){
    let generic = try{
        d.genericParam.toTokens()
    }catch(e: Exception){
        `empty_tokens`
    }
    if(d.superTypes.isEmpty()){
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$generic)
    d.superTypes.append(QualifiedType(quote(Equatable<$typeName>)))
    var eq = `nl`
    for(d in d.body.decls where d is VarDecl){
        eq += quote(
            result = {=>
                try{
                    let typeInfo = TypeInfo.of($(d.identifier))
                    let eq = typeInfo.getInstanceFunction("==", typeInfo)
                    eq.apply($(d.identifier), other.$(d.identifier))
                }catch(e: Exception){
                    true
                }
            }()
            if(!result){
                return false
            }
        ) + `nl`
    }
    d.body.decls.append(parseDecl(quote(
        public operator func ==(other: $typeName): Bool {
            var result = true
            $eq
            true
        }
    )))
}
func generateCompare(d: CompositeDecl){
    let generic = try{
        d.genericParam.toTokens()
    }catch(e: Exception){
        `empty_tokens`
    }
    if(d.superTypes.isEmpty()){
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$generic)
    d.superTypes.append(QualifiedType(quote(Comparable<$typeName>)))
    var cmp = `nl`
    for(d in d.body.decls where d is VarDecl){
        cmp += quote(
            result = {=>
                try{
                    let typeInfo = TypeInfo.of($(d.identifier))
                    let cmp = typeInfo.getInstanceFunction("compare", typeInfo)
                    cmp.apply($(d.identifier), other.$(d.identifier))
                }catch(e: Exception){
                    EQ
                }
            }()
            if(result != EQ){
                return result
            }
        ) + `nl`
    }
    d.body.decls.append(parseDecl(quote(
        public func compare(other: $typeName): Bool {
            var result = Ordering.EQ
            $cmp
            result
        }
    )))
}
func generateToString(d: CompositeDecl){
    let generic = try{
        d.genericParam.toTokens()
    }catch(e: Exception){
        `empty_tokens`
    }
    if(d.superTypes.isEmpty()){
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$generic)
    d.superTypes.append(RefType(quote(ToString)))
    var str = `nl` + `lsquare`
    for(d in d.body.decls where d is VarDecl){
        str += quote(
            result.append($(d.identifier.value))
            result.append(" = ")
            match($(d.identifier)){
                case x: ToString => result.append(x.toString())
                case _ => result.append("_")
            }
            result.append("; ")
        ) + `nl`
    }
    str += `rsquare`
    d.body.decls.append(parseDecl(quote(
        public func toString(): Bool {
            var result = StringBuilder()
            $str
            result
        }
    )))
}
func generateToFields(d: CompositeDecl) {
    let klassDecl = (d as ClassDecl).getOrThrow{DataException("current decl ${d.identifier.value} must be a class decl")}
    let klassIdentifier = quote($(klassDecl.identifier)$(klassDecl.genericParam))
    if(klassDecl.superTypes.isEmpty()){
        klassDecl.upperBound = `upperbound`[0]
    }
    klassDecl.superTypes.append(QualifiedType(quote(DataObject<$(klassIdentifier)>)))
    let body = klassDecl.body.decls
    var fields = `lsquare`
    var i = 0
    for (f in body) {
        if (i > 0) {
            fields += `comma`
        }
        fields += 
        match(f){
            case x: VarDecl where x.isPublic() =>
                if (x.isVar()) {
                    quote(MutableField($(x.identifier.value), TypeInfo.of(x.$(x.identifier)), {o =>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>() + ", but recceives " + TypeInfo.of(o))}.$(x.identifier).toData()
                    }){o, d, flag =>
                        match ($(x.declType).tryFromData(d, flag: flag)) {
                            case Some(x) =>
                                (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>() + ", but receives " + TypeInfo.of(o))}.$(x.identifier) = (x as $(x.declType)).getOrThrow()
                                true
                            case _ => false
                        }
                    })
                } else {
                    quote(ReadonlyField($(x.identifier.value), TypeInfo.of(x.$(x.identifier))){o=>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>() + ", but recceives " + TypeInfo.of(o))}.$(x.identifier).toData()
                    })
                }
            case x: PropDecl where x.isPublic() =>
                if (x.isMut()) {
                    quote(MutableField($(x.identifier.value), TypeInfo.of(x.$(x.identifier)), {o =>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>() + ", but recceives " + TypeInfo.of(o))}.$(x.identifier).toData()
                    }){o, d, flag =>
                        match ($(x.declType).tryFromData(d, flag: flag)) {
                            case Some(x) =>
                                (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>() + ", but recceives " + TypeInfo.of(o))}.$(x.identifier) = (x as $(x.declType)).getOrThrow()
                                true
                            case _ => false
                        }
                    })
                } else {
                    quote(ReadonlyField($(x.identifier.value), TypeInfo.of(x.$(x.identifier))){o=>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>() + ", but recceives " + TypeInfo.of(o))}.$(x.identifier).toData()
                    })
                }
            case _ => 
                i++
                continue
        }
        i++
    }
    let openModi = if(klassDecl.isAbstract() || klassDecl.isOpen()){
        `open`
    }else{
        `empty_tokens`
    }
    fields += `rsquare`
    let fieldsName = Token(IDENTIFIER, "___dAtA__fIElds_")
    body.appendAll([VarDecl(quote(
        private static let $(fieldsName) = ObjectFields.createFields<$klassIdentifier>($fields){
            $klassIdentifier()
        }
    )), FuncDecl(quote(
        public static func dataFields(): ObjectFields {
            $fieldsName
        }
    )), FuncDecl(quote(
        public $openModi func toData(): Data {
            ObjectData<$klassIdentifier>(this)
        }
    )), FuncDecl(quote(
        public static func fromData(data: Data, flag!: DataConversionFlag = SILENCE): Object {
            tryFromData(data, flag: flag).getOrThrow{DataException("current data " + data + " cannot be converted to " + TypeInfos.get<$klassIdentifier>())}
        }
    )), FuncDecl(quote(
        public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): ?Object {
            match(ObjectData<$klassIdentifier>.populate(data, flag: flag)){
                case Some(o) => o
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException(data.toString() + 'cannot be converted to ' + TypeInfos.get<$klassIdentifier>())
                case _ => None
            }
        }
    ))])
}
