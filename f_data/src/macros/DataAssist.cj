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
                set.add(t.value.toAsciiLower())
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
                    set.add(message.getString(name))
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
        if (v.isStatic() || v.isPublic()) {
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
        appended.add(
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
                    vars.add(member)
                    args.add(p)
                    p.modifiers = ArrayList<Modifier>()
                    p.keyword = Token(ILLEGAL)
                    gen(member)
                    assigns.add(parseExpr(quote(this.$(member.identifier) = $(p.identifier))))
                }
                for(i in 0 .. vars.size) {
                    decls.add(vars[i], at: i)
                }
                for(i in 0 .. assigns.size) {
                    d.block.nodes.add(assigns[i], at: i)
                }
            case _ => continue
        }
    }
    decls.add(all: appended)
}

func generateHash(d: ClassDecl, exclusion: HashSet<String>) {
    if (d.superTypes.isEmpty()) {
        d.upperBound = `upperbound`[0]
    }
    d.superTypes.add(RefType(quote(Hashable)))
    var hashed = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        hashed += match ((d as VarDecl).getOrThrow().declType.toTokens().toString().replace(' ', '')) {
            case 'Int' | 'UInt' | 'Byte' | "IntNative" | 'UIntNative' | 'Int64' | 'UInt64' | 'Int32' | 'UInt32' | 'Int16' | 'UInt16' | 'Int8' | 'UInt8' | 'Float64' | 'Float32' | 'Float16' | 'BigInt' | 'Decimal' | '?Int' | '?UInt' | '?Byte' | "?IntNative" | '?UIntNative' | '?Int64' | '?UInt64' | '?Int32' | '?UInt32' | '?Int16' | '?UInt16' | '?Int8' | '?UInt8' | '?Float64' | '?Float32' | '?Float16' | '?BigInt' | '?Decimal' | 'Option<Int>' | 'Option<UInt>' | 'Option<Byte>' | "Option<IntNative>" | 'Option<UIntNative>' | 'Option<Int64>' | 'Option<UInt64>' | 'Option<Int32>' | 'Option<UInt32>' | 'Option<Int16>' | 'Option<UInt16>' | 'Option<Int8>' | 'Option<UInt8>' | 'Option<Float64>' | 'Option<Float32>' | 'Option<Float16>' | 'Option<BigInt>' | 'Option<Decimal>' | 'Bool' | '?Bool' | 'Option<Bool>' | 'Rune' | '?Rune' | 'Option<Rune>' | 'String' | '?String' | 'Option<String>' | 'Duration' | '?Duration' | 'Option<Duration>' | 'DateTime' | '?DateTime' | 'Option<DateTime>' => quote(
                hasher.write($(d.identifier).hashCode()))
            case _ => quote(
                match($(d.identifier)){
                case x: Hashable => hasher.write(x.hashCode())
                case _ => ()
            })
        } + `nl`
    }
    d.body.decls.add(parseDecl(quote(
        private var __hAsh__ = 0
    )))
    d
        .body
        .decls
        .add(
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
    d.superTypes.add(RefType(quote(Equatable<$typeName>)))
    var hashTokens = `empty_tokens`
    var eq = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        if (d.identifier.value == '__hAsh__') {
            hashTokens = quote(
                if(this.hashCode() != other.hashCode()){
                    return false
                })
            continue
        }
        let declType = (d as VarDecl).getOrThrow().declType
        eq += match (declType.toTokens().toString().replace(' ', '')) {
            case 'Int' | 'UInt' | 'Byte' | "IntNative" | 'UIntNative' | 'Int64' | 'UInt64' | 'Int32' | 'UInt32' | 'Int16' | 'UInt16' | 'Int8' | 'UInt8' | 'Float64' | 'Float32' | 'Float16' | 'BigInt' | 'Decimal' | '?Int' | '?UInt' | '?Byte' | "?IntNative" | '?UIntNative' | '?Int64' | '?UInt64' | '?Int32' | '?UInt32' | '?Int16' | '?UInt16' | '?Int8' | '?UInt8' | '?Float64' | '?Float32' | '?Float16' | '?BigInt' | '?Decimal' | 'Option<Int>' | 'Option<UInt>' | 'Option<Byte>' | "Option<IntNative>" | 'Option<UIntNative>' | 'Option<Int64>' | 'Option<UInt64>' | 'Option<Int32>' | 'Option<UInt32>' | 'Option<Int16>' | 'Option<UInt16>' | 'Option<Int8>' | 'Option<UInt8>' | 'Option<Float64>' | 'Option<Float32>' | 'Option<Float16>' | 'Option<BigInt>' | 'Option<Decimal>' | 'Bool' | '?Bool' | 'Option<Bool>' | 'Rune' | '?Rune' | 'Option<Rune>' | 'String' | '?String' | 'Option<String>' | 'Duration' | '?Duration' | 'Option<Duration>' | 'DateTime' | '?DateTime' | 'Option<DateTime>' => quote(
                result = this.$(d.identifier) == other.$(d.identifier))
            case _ => quote(
                result = match($(d.identifier)){
                case x: Equatable<$(declType)> => x == other.$(d.identifier)
                case _ => true
            })
        } + `nl` + quote(
            if(!result){
                return false
            }
        ) + `nl`
    }
    d
        .body
        .decls
        .add(
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
    d.superTypes.add(RefType(quote(Comparable<$typeName>)))
    var cmp = `nl`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        let declType = (d as VarDecl).getOrThrow().declType
        cmp += match (declType.toTokens().toString().replace(' ', '')) {
            case 'Int' | 'UInt' | 'Byte' | "IntNative" | 'UIntNative' | 'Int64' | 'UInt64' | 'Int32' | 'UInt32' | 'Int16' | 'UInt16' | 'Int8' | 'UInt8' | 'Float64' | 'Float32' | 'Float16' | 'BigInt' | 'Decimal' | 'Bool' | 'Rune' | 'String' | 'Duration' | 'DateTime' => quote(
                result = this.$(d.identifier).compare(other.$(d.identifier)))
            case _ => quote(
                result = match($(d.identifier)){
                case x: Comparable<$(declType)> => x.compare(other.$(d.identifier))
                case _ => EQ
            })
        } + `nl` + quote(
            if(result != EQ){
                return result
            }
        ) + `nl`
    }
    d
        .body
        .decls
        .add(
            parseDecl(
                quote(
        public func compare(other: $typeName): Bool {
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
    d.superTypes.add(RefType(quote(ToString)))
    var str = quote($(d.identifier)$(d.genericParamTokens)) + `lsquare`
    for (d in d.body.decls where d is VarDecl &&
        !(isStatic(d) || exclusion.contains(d.identifier.value) || exclusion.contains('${d.identifier.value}_'))) {
        str += match ((d as VarDecl).getOrThrow().toTokens().toString().replace(' ', '')) {
            case 'Int' | 'UInt' | 'Byte' | "IntNative" | 'UIntNative' | 'Int64' | 'UInt64' | 'Int32' | 'UInt32' | 'Int16' | 'UInt16' | 'Int8' | 'UInt8' | 'Float64' | 'Float32' | 'Float16' | 'BigInt' | 'Decimal' | '?Int' | '?UInt' | '?Byte' | "?IntNative" | '?UIntNative' | '?Int64' | '?UInt64' | '?Int32' | '?UInt32' | '?Int16' | '?UInt16' | '?Int8' | '?UInt8' | '?Float64' | '?Float32' | '?Float16' | '?BigInt' | '?Decimal' | 'Option<Int>' | 'Option<UInt>' | 'Option<Byte>' | "Option<IntNative>" | 'Option<UIntNative>' | 'Option<Int64>' | 'Option<UInt64>' | 'Option<Int32>' | 'Option<UInt32>' | 'Option<Int16>' | 'Option<UInt16>' | 'Option<Int8>' | 'Option<UInt8>' | 'Option<Float64>' | 'Option<Float32>' | 'Option<Float16>' | 'Option<BigInt>' | 'Option<Decimal>' | 'Bool' | '?Bool' | 'Option<Bool>' | 'Rune' | '?Rune' | 'Option<Rune>' | 'String' | '?String' | 'Option<String>' | 'Duration' | '?Duration' | 'Option<Duration>' | 'DateTime' | '?DateTime' | 'Option<DateTime>' => quote(
                    result.append($(d.identifier.value))
                    result.append(" = ")
                    result.append(this.$(d.identifier).toString())
                    result.append("; "))
            case _ => quote(
                match($(d.identifier)){
                case x: ToString => 
                    result.append($(d.identifier.value))
                    result.append(" = ")
                    result.append(x.toString())
                    result.append("; ")
                case _ => ()
            })
        } + `nl`
    }
    str += `rsquare`
    d
        .body
        .decls
        .add(
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
    klassDecl.superTypes.add(RefType(quote(ObjectData<$(klassIdentifier)>)))
    let body = klassDecl.body.decls
    var fields = ArrayList<Expr>()
    for (d in body where (d is VarDecl || d is PropDecl) && !isStatic(d) && isPublic(d) &&
        !exclusion.contains(d.identifier.value)) {
        let expr = match (d) {
            case x: VarDecl =>
                var declType = x.declType.toTokens()
                var optionSetExpr = quote(
                    match(o){
                        case v: $klassIdentifier => v.$(x.identifier) = None
                            return true
                        case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                    }
                )
                var isOption = true
                if (declType[0].kind == QUEST) {
                    declType = declType[1..]
                } else if (declType[0].kind == IDENTIFIER && declType[0].value == 'Option') {
                    declType = declType[2..declType.size - 1]
                } else {
                    optionSetExpr = quote(
                        throw DataException('data is None for field ' + $(x.identifier.value) + ' of ' + TypeInfos.get<$(klassIdentifier)>().toString()))
                    isOption = false
                }
                var optionGetExpr = if (isOption) {
                    quote(
                        match(o){
                            case v: $klassIdentifier => match(v.$(x.identifier)){
                                case Some(x: $(declType)) => x.toData()
                                case _ => DataNone.INSTANCE
                            }
                            case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                        }
                    )
                } else {
                    quote(
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())}.$(x.identifier).toData())
                }
                if (x.isVar()) {
                    TrailingClosureExpr(
                        quote(
                        MutableField($(x.identifier.value), TypeInfos.get<$(declType)>(), {o =>
                        $optionGetExpr
                    }){o, d, flag =>
                        if(d is DataNone){
                            if((flag & IGNORE_NONE) != 0){
                                return false
                            }else{
                                $optionSetExpr
                            }
                        }
                        match (convert<$(declType)>(d, flag: flag)) {
                            case Some(x: $(declType)) =>
                                match(o){
                                    case v: $klassIdentifier => v.$(x.identifier) = x
                                    case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                                }
                                true
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => false
                            case _ => throw DataException('data ' + d.toString() + 'cannot be converted to ' + TypeInfos.get<$(declType)>().toString())
                        }
                    })
                    )
                } else {
                    TrailingClosureExpr(
                        quote(
                        ReadonlyField($(x.identifier.value), TypeInfos.get<$(declType)>()){o=>
                        $optionGetExpr
                    })
                    )
                }
            case x: PropDecl =>
                var declType = x.declType.toTokens()
                var optionSetExpr = quote(
                    match(o){
                        case v: $klassIdentifier => v.$(x.identifier) = None
                            return true
                        case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                    }
                )
                var isOption = true
                if (declType[0].kind == QUEST) {
                    declType = declType[1..]
                } else if (declType[0].kind == IDENTIFIER && declType[0].value == 'Option') {
                    declType = declType[2..declType.size - 1]
                } else {
                    optionSetExpr = quote(
                        throw DataException('data is None for field ' + $(x.identifier.value) + ' of ' + TypeInfos.get<$(klassIdentifier)>().toString()))
                    isOption = false
                }
                var optionGetExpr = if (isOption) {
                    quote(
                        match(o){
                            case v: $klassIdentifier => match(v.$(x.identifier)){
                                case Some(x: $(declType)) => x.toData()
                                case _ => DataNone.INSTANCE
                            }
                            case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                        }
                    )
                } else {
                    quote(
                        (o as $klassIdentifier).getOrThrow{DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())}.$(x.identifier).toData())
                }
                if (x.isMut()) {
                    TrailingClosureExpr(
                        quote(
                        MutableField($(x.identifier.value), TypeInfos.get<$(declType)>(), {o =>
                        $optionGetExpr
                    }){o, d, flag =>
                        if(d is DataNone){
                            if((flag & IGNORE_NONE) != 0){
                                return false
                            }else{
                                $optionSetExpr
                            }
                        }
                        match (convert<$(declType)>(d, flag: flag)) {
                            case Some(x: $(declType)) =>
                                match(o){
                                    case v: $klassIdentifier => v.$(x.identifier) = x
                                    case _ => throw DataException("type of current instance does not match, expected " + TypeInfos.get<$(klassIdentifier)>().toString() + ", but receives " + TypeInfo.of(o).toString())
                                }
                                true
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => false
                            case _ => throw DataException('data ' + d.toString() + 'cannot be converted to ' + TypeInfos.get<$(declType)>().toString())
                        }
                    })
                    )
                } else {
                    TrailingClosureExpr(
                        quote(
                        ReadonlyField($(x.identifier.value), TypeInfos.get<$(declType)>()){o =>
                        $optionGetExpr
                    })
                    )
                }
            case _ => continue
        }
        fields.add(expr)
    }
    let openModi = if (klassDecl.isAbstract() || klassDecl.isOpen()) {
        `open`
    } else {
        `empty_tokens`
    }
    let fieldsName = Token(IDENTIFIER, "___dAtA__fIElds_")
    var fieldTokens = `lsquare`
    var i = 0
    while (i < fields.size) {
        if (i > 0) {
            fieldTokens += `comma`
        }
        fieldTokens += fields[i].toTokens()
        i++
    }
    fieldTokens += `rsquare`
    body.add(
        all: [
            VarDecl(
                quote(
        private static let $(fieldsName) = ObjectFields<$klassIdentifier>($fieldTokens){
            $klassIdentifier()
        }
    )
            ),
            FuncDecl(
                quote(
        public static func dataFields(): ObjectFields<$klassIdentifier> {
            $fieldsName
        }
    )),
            FuncDecl(
                quote(
        public $openModi func toData(): Data {
            DataObject<$klassIdentifier>(this)
        }
    )
            ),
            FuncDecl(
                quote(
        public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
            match(DataObject<$klassIdentifier>.populate(data, flag: flag)){
                case Some(o: $klassIdentifier) => o
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException(data.toString() + 'cannot be converted to ' + TypeInfos.get<$klassIdentifier>().toString())
                case _ => None<$klassIdentifier>
            }
        }
    )
            )
        ]
    )
}
