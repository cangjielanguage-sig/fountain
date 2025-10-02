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
macro package f_orm.macros

import std.ast.*
import std.collection.HashMap
import f_macros.*
import f_orm.exception.ORMException
import f_util.CaseFormat

/**
 * 必须跟@ORMField配合使用
 * 使用宏@ORMField 注解public mut prop或public var指定当前属性或成员变量是不是主键以及映射的列名，所有的仓颉mut prop必须是驼峰命名法。
 * @ORMField[true LowerUnderScore dataType] 表示当前属性映射主键，属性名转为LowerUnderScore就是列名，列的类型是dataType。
 * @ORMField[true "column_name" dataType] 表示当前属性映射主键，不论属性名是什么列名一定是"column_name"。
 * 第一部分可以是true或false，true表示当前属性映射主键，false表示映射的不是主键。
 * dataType必须是枚举orm.dialect.DataType的值。
 * 每一部分都是可选的。
 * 没有使用@ORMField注解的按照映射的不是主键，且按照列名是LowerUnderScore处理。
 */
public macro QueryMappersGenerator(input: Tokens): Tokens {
    expandQueryMappers(input)
}
private func expandQueryMappers(input: Tokens): Tokens {
    let decl = match(parseDecl(input)){
        case d: ClassDecl => d
        case d: MacroExpandDecl => 
            var decl = extract(d)
            let tokens = expandQueryMappers(decl.toTokens())
            decl = parseDecl(tokens)
            decl = replaceMacroInputDecl(d, decl)
            return decl.toTokens()
        case _ => 
            diagReport(ERROR, input, 'QueryMappersGenerator supports a class', '')
            throw ORMException("QueryMappersGenerator supports a class") 
    }
    let name = quote($(decl.identifier))
    let body = decl.body.decls
    let props = extractMutProps(body)
    let vars = extractVars(body)
    let map = HashMap<String, (Bool, String, Token)>()
    for (m in getChildMessages("ORMField")) {
        let name = m.getString("field")
        let id = if (m.hasItem("id")) {
            m.getBool("id")
        } else {
            false
        }
        let column = if (m.hasItem("column")) {
            m.getString("column")
        } else {
            ""
        }
        let dataType = if (m.hasItem("dataType")) {
            m.getString("dataType")
        } else {
            ""
        }
        map[name] = (id, column, Token(IDENTIFIER, dataType))
    }
    let mapperMetaFn = {
        n: String => if (let Some(m) <- map.get(n)) {
            m
        } else {
            (false, CaseFormat.Camel.convert(n, CaseFormat.LowerUnderScore), Token(IDENTIFIER, ""))
        }
    }
    let mappers = quote($(`lsquare`)).append(generateMappers(name, props, mapperMetaFn))
    let varMappers = generateMappers(name, vars, mapperMetaFn)
    if (varMappers.size > 0) {
        mappers.append(`comma`).append(varMappers)
    }
    mappers.append(`rsquare`)
    let queryMappersName = Token(IDENTIFIER, "_qUEry__mAppErs_")
    let superTypes = decl.superTypes
    let mapperTokens = quote(
        let creator = {=> $name()}
        let mappers = $mappers
        $(`nl`)
    )
    for (st in superTypes) {
        mapperTokens.append(quote(
            if (let Some(x) <- QueryMappers<$st>.create<$name>(creator, mappers)) {
                return x
            }
            $(`nl`)
        ))
    }
    if (superTypes.isEmpty()) {
        decl.upperBound = `upperbound`[0]
    }
    decl.superTypes.add(RefType(quote(QueryMappersInit<$name>)))
    body.add(
        all: [parseDecl(
            quote(
        private static let $queryMappersName = {=>
            $mapperTokens
            QueryMappers<$name> (
                creator: creator,
                mappers: mappers
            )
        }()
    )),
            parseDecl(
            quote(
        public static func isSimpleData(): Bool {
            false
        }
    )),
            parseDecl(
            quote(
        public static func queryMappers(): QueryMappers<$name>{
            $queryMappersName
        }
    ))])
    decl.toTokens()
}

func generateMappers(name: Tokens, props: Array<PropDecl>, mapperMetaFn: (String) -> (Bool, String, Token)): Tokens {
    let tokens = quote()
    for (i in 0..props.size) {
        if (i > 0) {
            tokens.append(`comma`)
        }
        let decl = props[i]
        let propName = decl.identifier
        let dts = quote($(decl.declType))
        let meta = mapperMetaFn(propName.value)
        tokens.append(generateMappers(name, propName, dts, meta))
    }
    tokens
}

func generateMappers(name: Tokens, vars: Array<VarDecl>, mapperMetaFn: (String) -> (Bool, String, Token)): Tokens {
    let tokens = quote()
    for (i in 0..vars.size) {
        if (i > 0) {
            tokens.append(`comma`)
        }
        let decl = vars[i]
        let varName = decl.identifier
        let dts = quote($(decl.declType))
        let meta = mapperMetaFn(varName.value)
        tokens.append(generateMappers(name, varName, dts, meta))
    }
    tokens
}

func generateMappers(name: Tokens, fieldName: Token, dts: Tokens, meta: (Bool, String, Token)): Tokens {
    let dataType = quote()
    var nullable = false
    for (j in 0..dts.size) {
        let dt = dts[j]
        if (j == 0 && dt.value == "?") {
            nullable = true
            dataType.append(dts[j + 1])
        } else if (j == 0 && dt.value == "Option") {
            nullable = true
            dataType.append(dts[j + 2])
        } else {
            dataType.append(dt)
            continue
        }
        break
    }
    let dataTypeStr = dataType.toString().replace(' ', '')
    let dataTypeToken = Token(IDENTIFIER, '${dataType[0].value}DataType')
    let fieldNameStr = Token(STRING_LITERAL, fieldName.value)
    let columnName = Token(STRING_LITERAL, meta[1])
    let columnType = meta[2]
    if (meta[0]) {
        quote(
                IdQueryMapper<$dataType, $name>(
                    dataType: $(dataTypeToken)($nullable, $columnName),
                    putter: {o, v => o.$fieldName = ORMConverter.convert<$dataType>(v)}
                )
            )
    } else if (dataType[0].value == "ArrayList") {
        let listGeneric = quote()
        for (j in 2..dataType.size - 1) {
            let dt = dataType[j]
            if (j == 2 && dt.value == "?") {
                nullable = true
                listGeneric.append(quote(Option<))
            } else if (j == 2 && dt.value == "Option") {
                nullable = true
                listGeneric.append(dt)
            } else {
                listGeneric.append(dt)
            }
        }
        if (nullable) {
            listGeneric.append(`gt`)
        }
        if (nullable && columnType.value.isEmpty()) {
            quote(
                    if (TypeInfo.of<$(listGeneric[2])>().isSubtypeOf(TypeInfo.of<InputStream>()) || $(listGeneric[2]).isSimpleData()) {
                        GroupedSingleQueryMapper<$(listGeneric[2]), $name>(
                            name: $columnName,
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        NullableGroupedQueryMapper<$(listGeneric[2]), $name>(
                            ignoreNone: false,
                            grouped: $(listGeneric[2]).queryMappers(),
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else if (nullable) {
            quote(
                    if (TypeInfo.of<$(listGeneric[2])>().isSubtypeOf(TypeInfo.of<InputStream>()) || $(listGeneric[2]).isSimpleData()) {
                        GroupedSingleQueryMapper<$(listGeneric[2]), $name>(
                            name: $columnName,
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        NullableGroupedQueryMapper<$(listGeneric[2]), $name>(
                            ignoreNone: false,
                            grouped: $(listGeneric[2]).queryMappers(),
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else if (columnType.value == "") {
            quote(
                    if (TypeInfo.of<$(listGeneric)>().isSubtypeOf(TypeInfo.of<InputStream>()) || $(listGeneric).isSimpleData()) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        GroupedQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: $(listGeneric).queryMappers(),
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        } else {
            quote(
                    if (TypeInfo.of<$(listGeneric)>().isSubtypeOf(TypeInfo.of<InputStream>()) || $(listGeneric).isSimpleData()) {
                        GroupedSingleQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            groupedGetter: {o => o.$fieldName}
                        )
                    } else {
                        GroupedQueryMapper<$listGeneric, $name>(
                            name: $columnName,
                            grouped: $(listGeneric).queryMappers(),
                            groupedGetter: {o => o.$fieldName}
                        )
                    }
                )
        }
    } else if (nullable && columnType.value == "") {
        quote(
                if(TypeInfo.of<$(dataType)>().isSubtypeOf(TypeInfo.of<InputStream>())){
                    FieldQueryMapper<$dataType, $name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                }else if ($(dataType).isSimpleData()) {
                    FieldQueryMapper<$dataType, $name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                } else {
                    NullableNestQueryMapper<$dataType, $name> (
                        nested: $(dataType).queryMappers(),
                        nestGetter: {o => o.$fieldName}
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else if (nullable) {
        quote(
                if(TypeInfo.of<$(dataType)>().isSubtypeOf(TypeInfo.of<InputStream>())){
                    FieldQueryMapper<$dataType, $name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                }else if ($(dataType).isSimpleData()) {
                    FieldQueryMapper<$dataType, $name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v => o.$fieldName = v}
                    )
                } else {
                    NullableNestQueryMapper<$dataType, $name> (
                        nested: $(dataType).queryMappers(),
                        nestGetter: {o => o.$fieldName}
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else if (columnType.value == "") {
        quote(
                if(TypeInfo.of<$(dataType)>().isSubtypeOf(TypeInfo.of<InputStream>())){
                    QueryMapper<$name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataTypeStr))
                            }
                    })
                }else if ($(dataType).isSimpleData()) {
                    QueryMapper<$name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataTypeStr))
                            }
                    })
                } else {
                    NestQueryMapper<$dataType, $name> (
                        nested: $(dataType).queryMappers(),
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    } else {
        quote(
                if(TypeInfo.of<$(dataType)>().isSubtypeOf(TypeInfo.of<InputStream>())){
                    QueryMapper<$name> (
                        dataType: InputStreamDataType($nullable, $columnName),
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataTypeStr))
                            }
                    })
                }else if ($(dataType).isSimpleData()) {
                    QueryMapper<$name> (
                        dataType: $(dataTypeToken)($nullable, $columnName),
                        putter: {o, v =>
                            o.$fieldName =
                            match(v){
                                case x: Option<$dataType> => x.getOrThrow{ORMException("current value for " + $fieldNameStr + " must not be None")}
                                case x: $dataType =>  x
                                case _ => throw ORMException("current value must be type of " + $(dataTypeStr))
                            }
                    })
                } else {
                    NestQueryMapper<$dataType, $name> (
                        nested: $(dataType).queryMappers(),
                        nestPutter: {o, v => o.$fieldName = v}
                    )
                }
            )
    }
}
