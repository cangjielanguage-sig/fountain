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
 * props hash compare equal tostring toString fields
 */
public macro DataAssist(attr: Tokens, input: Tokens): Tokens {
    match (parseDecl(input)) {
        case d: ClassDecl =>
            let set = HashSet<String>()
            for (t in attr) {
                set.put(t.value.toAsciiLower())
            }
            func generate(tag: String, decl: ClassDecl, exclusion: HashSet<String>,
                fn: (ClassDecl, HashSet<String>) -> Unit): Unit {
                if (set.contains(tag)) {
                    fn(decl, exclusion)
                }
            }
            let excludeProp = HashSet<String>()
            let excludeHash = HashSet<String>()
            let excludeEqual = HashSet<String>()
            let excludeCompare = HashSet<String>()
            let excludeToString = HashSet<String>()
            let excludeFields = HashSet<String>()
            func populateExclusion(message: MacroMessage, name: String, set: HashSet<String>): Unit {
                if (message.hasItem(name)) {
                    set.put(message.getString(name))
                }
            }
            for (message in getChildMessages('DataExclude')) {
                populateExclusion(message, 'prop', excludeProp)
                populateExclusion(message, 'hash', excludeHash)
                populateExclusion(message, 'equal', excludeEqual)
                populateExclusion(message, 'compare', excludeCompare)
                populateExclusion(message, 'tostring', excludeToString)
                populateExclusion(message, 'field', excludeFields)
            }
            generate('props', d, excludeProp, generateProps)
            generate('hash', d, excludeHash, generateHash)
            generate('equal', d, excludeEqual, generateEqual)
            generate('compare', d, excludeCompare, generateCompare)
            generate('tostring', d, excludeToString, generateToString)
            generate('fields', d, excludeFields, generateToFields)
            d.toTokens()
        case _ => throw IllegalArgumentException("input must be a class decl")
    }
}

func generateProps(decl: ClassDecl, exclusion: HashSet<String>) {
    let decls = decl.body.decls
    let appended = ArrayList<Decl>()
    func gen(v: VarDecl) {
        if(v.isStatic() || v.isPublic()){
            return
        }
        let name = v.identifier
        if (exclusion.contains(name.value)) {
            return
        }
        let t = v.declType
        let mutable = v.keyword.value == 'var'
        v.identifier = Token(IDENTIFIER, v.identifier.value + '_')
        let (mutToken, setter) = if (mutable) {
            (quote(mut), quote(
                set(value){
                    $(v.identifier) = value
                }
            ))
        } else {
            let empty = quote()
            (empty, empty)
        }
        appended.append(
            PropDecl(
                quote(
            public $mutToken prop $name: $(t){
                get(){
                    $(v.identifier)
                }
                $(setter)
            }
        )
            ))
    }
    for (decl in decls) {
        match (decl) {
            case d: VarDecl where !(d.isStatic() || d.isPublic()) => gen(d)
            case d: PrimaryCtorDecl =>
                let vars = ArrayList<Decl>()
                let assigns = ArrayList<Node>()
                let args = ArrayList<FuncParam>()
                for (p in d.funcParams where p.isMemberParam()) {
                    let member = VarDecl()
                    member.modifiers = p.modifiers
                    member.keyword = p.keyword
                    member.identifier = p.identifier
                    member.colon = p.colon
                    member.declType = p.paramType
                    if (p.assign.kind.toString() == 'ASSIGN') {
                        member.assign = p.assign
                        member.expr = p.expr
                    }
                    vars.append(member)
                    args.append(p)
                    p.modifiers = ArrayList<Modifier>()
                    p.keyword = Token(ILLEGAL)
                    gen(member)
                    assigns.append(parseExpr(quote(this.$(member.identifier) = $(p.identifier))))
                }
                decls.prependAll(vars)
                d.block.nodes.prependAll(assigns)
            case _ => continue
        }
    }
    decls.appendAll(appended)
}

func generateHash(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    d.superTypes.append(RefType(quote(Hashable)))
    var hashed = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        hashed += quote(
            match($(d.identifier)){
                case x: Hashable => hasher.write(x.hashCode())
                case _ => ()
            }
        ) +
            `nl`
    }
    d.body.decls.append(parseDecl(quote(
        private var __hAsh__ = 0
    )))
    d
        .body
        .decls
        .append(
            parseDecl(
                quote(
        public func hashCode(): Int64{
            if(__hAsh__ == 0){
                var hasher = DefaultHasher()
                $hashed
                __hAsh__ = hasher.finish()
            }
            __hAsh__
        }
    )
            ))
}

func generateEqual(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$(d.genericParamTokens))
    d.superTypes.append(RefType(quote(Equatable<$typeName>)))
    var hashTokens = `empty_tokens`
    var eq = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        if(d.identifier.value == '__hAsh__'){
            hashTokens = quote(
                if(this.__hAsh__ != other.__hAsh__){
                    return false
                })
            continue
        }
        let declType = (d as VarDecl).getOrThrow().declType
        eq += quote(
            result = if((this.$(d.identifier) is Equatable<$declType>) && let x: Bool <- TypeInfos.get<$declType>().getInstanceFunction('==', [TypeInfos.get<$declType>()]).apply(this.$(d.identifier), [other.$(d.identifier)])){
                x
            }else{
                true
            }
            if(!result){
                return false
            }
        ) +
            `nl`
    }
    d
        .body
        .decls
        .append(
            parseDecl(
                quote(
        public operator func ==(other: $typeName): Bool {
            $hashTokens
            var result = true
            $eq
            true
        }
    )
            ))
}

func generateCompare(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    let typeName = quote($(d.identifier)$(d.genericParamTokens))
    d.superTypes.append(RefType(quote(Comparable<$typeName>)))
    var hashTokens = `empty_tokens`
    var cmp = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        if(d.identifier.value == '__hAsh__'){
            hashTokens = quote(
                if(this.__hAsh__.compare(other.__hAsh__) != EQ){
                    return result
                })
            continue
        }
        let declType = (d as VarDecl).getOrThrow().declType
        cmp += quote(
            result = if((this.$(d.identifier) is Comparable<$declType>) && let x: Ordering <- TypeInfos.get<$declType>().getInstanceFunction('compare', [TypeInfos.get<$declType>()]).apply(this.$(d.identifier), [other.$(d.identifier)])){
                x
            } else {
                EQ
            }
            if(result != EQ){
                return result
            }
        ) +
            `nl`
    }
    d
        .body
        .decls
        .append(
            parseDecl(
                quote(
        public func compare(other: $typeName): Bool {
            $hashTokens
            var result = Ordering.EQ
            $cmp
            result
        }
    )
            ))
}

func generateToString(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    d.superTypes.append(RefType(quote(ToString)))
    var str = quote($(d.identifier)$(d.genericParamTokens)) + `lsquare`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        str += quote(
            result.append($(d.identifier.value))
            result.append(" = ")
            match($(d.identifier)){
                case x: ToString => result.append(x.toString())
                case _ => result.append("_")
            }
            result.append("; ")
        ) +
            `nl`
    }
    str += `rsquare`
    d
        .body
        .decls
        .append(
            parseDecl(
                quote(
        public func toString(): Bool {
            var result = StringBuilder()
            $str
            result
        }
    )
            ))
}

func generateToFields(d: ClassDecl, exclusion: HashSet<String>) {
    let klassDecl = (d as ClassDecl).getOrThrow {
        DataException("current decl ${d.identifier.value} must be a class decl")
    }
    let klassIdentifier = quote($(klassDecl.identifier)$(d.genericParamTokens))
    if (klassDecl.superTypes.isEmpty()) {
        klassDecl.upperBound = `upperbound`[0]
    }
    klassDecl.superTypes.append(RefType(quote(DataObject<$(klassIdentifier)>)))
    let body = klassDecl.body.decls
    var fields = ArrayList<Expr>()
    for (d in body where (d is VarDecl || d is PropDecl) && !isStatic(d) && isPublic(d) && !exclusion.contains(d.identifier.value)) {
        let expr =  match (d) {
            case x: VarDecl =>
                var declType = x.declType.toTokens()
                var optionExpr = quote(
                    match(o){
                        case v: $klassIdentifier => v.$(x.identifier) = None
                            return true
                        case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                    }
                )
                if(declType[0].kind == QUEST){
                    declType = declType[1 ..]
                }else if(declType[0].kind == IDENTIFIER && declType[0].value == 'Option'){
                    declType = declType[2 .. declType.size - 1]
                }else{
                    optionExpr = quote(throw DataException('data is None for field $(x.identifier.value) of $(klassIdentifier)'))
                }
                if (x.isVar()) {
                    TrailingClosureExpr(quote(
                        MutableField($(x.identifier.value), TypeInfos.get<$(declType)>(), {o =>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())}.$(x.identifier).toData()
                    }){o, d, flag =>
                        if(d is DataNone){
                            if((flag & IGNORE_NONE) != 0){
                                return false
                            }else{
                                $optionExpr
                            }
                        }
                        match ($(declType).tryFromData(d, flag: flag)) {
                            case Some(x) =>
                                match(o){
                                    case v: $klassIdentifier => v.$(x.identifier) = x
                                    case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                                }
                                true
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => false
                            case _ => throw DataException('data ' + d.toString() + 'cannot be converted to ' + TypeInfos.get<$(declType)>().toString())
                        }
                    }))
                } else {
                    TrailingClosureExpr(quote(
                        ReadonlyField($(x.identifier.value), TypeInfos.get<$(declType)>()){o=>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())}.$(x.identifier).toData()
                    }))
                }
            case x: PropDecl =>
                var declType = x.declType.toTokens()
                var optionExpr = quote(
                    match(o){
                        case v: $klassIdentifier => v.$(x.identifier) = None
                            return true
                        case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                    }
                )
                if(declType[0].kind == QUEST){
                    declType = declType[1 ..]
                }else if(declType[0].kind == IDENTIFIER && declType[0].value == 'Option'){
                    declType = declType[2 .. declType.size - 1]
                }else{
                    optionExpr = quote(throw DataException('data is None for field $(x.identifier.value) of $(klassIdentifier)'))
                }
                if (x.isMut()) {
                    TrailingClosureExpr(quote(
                        MutableField($(x.identifier.value), TypeInfos.get<$(declType)>(), {o =>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())}.$(x.identifier).toData()
                    }){o, d, flag =>
                        if(d is DataNone){
                            if((flag & IGNORE_NONE) != 0){
                                return false
                            }else{
                                $optionExpr
                            }
                        }
                        match ($(declType).tryFromData(d, flag: flag)) {
                            case Some(x) =>
                                match(o){
                                    case v: $klassIdentifier => v.$(x.identifier) = x
                                    case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                                }
                                true
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => false
                            case _ => throw DataException('data ' + d.toString() + 'cannot be converted to ' + TypeInfos.get<$(declType)>().toString())
                        }
                    }))
                } else {
                    TrailingClosureExpr(quote(
                        ReadonlyField($(x.identifier.value), TypeInfos.get<$(declType)>()){o =>
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())}.$(x.identifier).toData()
                    }))
                }
            case _ =>
                continue
        }
        fields.append(expr)
    }
    let openModi = if (klassDecl.isAbstract() || klassDecl.isOpen()) {
        `open`
    } else {
        `empty_tokens`
    }
    let fieldsName = Token(IDENTIFIER, "___dAtA__fIElds_")
    var fieldTokens = `lsquare`
    var i = 0
    while(i < fields.size) {
        if(i > 0){
            fieldTokens += `comma`
        }
        fieldTokens += fields[i].toTokens()
        i++
    }
    fieldTokens += `rsquare`
    body.appendAll(
        [
            VarDecl(
                quote(
        private static let $(fieldsName) = ObjectFields.createFields<$klassIdentifier>($fieldTokens){
            $klassIdentifier()
        }
    )
            ),
            FuncDecl(
                quote(
        public static func dataFields(): ObjectFields {
            $fieldsName
        }
    )),
            FuncDecl(
                quote(
        public $openModi func toData(): Data {
            ObjectData<$klassIdentifier>(this)
        }
    )
            ),
            FuncDecl(
                quote(
        public static func fromData(data: Data, flag!: DataConversionFlag = SILENCE): $klassIdentifier {
            tryFromData(data, flag: flag).getOrThrow{DataException("current data " + data.toString() + " cannot be converted to " + TypeInfos.get<$klassIdentifier>().toString())}
        }
    )
            ),
            FuncDecl(
                quote(
        public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): ?$klassIdentifier {
            match(ObjectData<$klassIdentifier>.populate(data, flag: flag)){
                case Some(o) => o
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException(data.toString() + 'cannot be converted to ' + TypeInfos.get<$klassIdentifier>().toString())
                case _ => None
            }
        }
    )
            )
        ]
    )
}
