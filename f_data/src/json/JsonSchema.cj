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
package fountain::f_data.json

public interface ToJsonSchema {
    static func toJsonSchema<T>(): JsonObject where T <: ObjectData<T>
}

extend JsonObject <: ToJsonSchema {
    private static func toJsonSchema(fieldType: TypeInfo, schema: ?JsonSchema): JsonObject {
        let property = JsonObject()
        if(fieldType == TypeInfo.of<Bool>()){
            property.add("type", JsonString("boolean"))
            if(let Some(s: JsonBoolSchema) <- schema){
                if(let Some(default) <- s.default){
                    property.add("default", JsonBool(default))
                }
                if(let Some(title) <- s.title){
                    property.add("title", JsonString(title))
                }
                if(let Some(description) <- s.description){
                    property.add("description", JsonString(description))
                }
            }
        }else if(fieldType == TypeInfo.of<Int8>() ||
                fieldType == TypeInfo.of<Int16>() ||
                fieldType == TypeInfo.of<Int32>() ||
                fieldType == TypeInfo.of<Int64>() ||
                fieldType == TypeInfo.of<UInt8>() ||
                fieldType == TypeInfo.of<UInt16>() ||
                fieldType == TypeInfo.of<UInt32>() ||
                fieldType == TypeInfo.of<UInt64>()
        ) {
            property.add("type", JsonString("integer"))
            if(let Some(s: JsonIntSchema) <- schema){
                if(let Some(minimum) <- s.minimum){
                    if(s.exclusiveMinimum){
                        property.add("exclusiveMinimum", JsonInt(minimum))
                    }else{
                        property.add("minimum", JsonInt(minimum))
                    }
                }
                if(let Some(maximum) <- s.maximum){
                    if(s.exclusiveMaximum){
                        property.add("exclusiveMaximum", JsonInt(maximum))
                    }else{
                        property.add("maximum", JsonInt(maximum))
                    }
                }
                if(let Some(multipleOf) <- s.multipleOf){
                    property.add("multipleOf", JsonInt(multipleOf))
                }
                if(let Some(enumeration) <- s.enumeration){
                    property.add("enum", JsonValue.fromStr(enumeration).asArray())
                }
                if(let Some(title) <- s.title){
                    property.add("title", JsonString(title))
                }
                if(let Some(description) <- s.description){
                    property.add("description", JsonString(description))
                }
                if(let Some(default) <- s.default){
                    property.add("default", JsonInt(default))
                }
            }
        }else if(fieldType == TypeInfo.of<Float32>() ||
                fieldType == TypeInfo.of<Float64>() ||
                fieldType == TypeInfo.of<Float16>()
        ) {
            property.add("type", JsonString("number"))
            if(let Some(s: JsonFloatSchema) <- schema){
                if(let Some(minimum) <- s.minimum){
                    if(s.exclusiveMinimum){
                        property.add("exclusiveMinimum", JsonDecimal(minimum))
                    }else{
                        property.add("minimum", JsonDecimal(minimum))
                    }
                }
                if(let Some(maximum) <- s.maximum){
                    if(s.exclusiveMaximum){
                        property.add("exclusiveMaximum", JsonDecimal(maximum))
                    }else{
                        property.add("maximum", JsonDecimal(maximum))
                    }
                }
                if(let Some(multipleOf) <- s.multipleOf){
                    property.add("multipleOf", JsonDecimal(multipleOf))
                }
                if(let Some(enumeration) <- s.enumeration){
                    property.add("enum", JsonValue.fromStr(enumeration).asArray())
                }
                if(let Some(title) <- s.title){
                    property.add("title", JsonString(title))
                }
                if(let Some(description) <- s.description){
                    property.add("description", JsonString(description))
                }
                if(let Some(default) <- s.default){
                    property.add("default", JsonDecimal(default))
                }
            }
        }else if(fieldType == TypeInfo.of<String>()){
            property.add("type", JsonString("string"))
            if(let Some(s: JsonStringSchema) <- schema){
                if(let Some(minLength) <- s.minLength){
                    property.add("minLength", JsonInt(minLength))
                }
                if(let Some(maxLength) <- s.maxLength){
                    property.add("maxLength", JsonInt(maxLength))
                }
                if(let Some(pattern) <- s.pattern){
                    property.add("pattern", JsonString(pattern))
                }
                if(let Some(enumeration) <- s.enumeration){
                    property.add("enum", JsonValue.fromStr(enumeration).asArray())
                }
                if(let Some(title) <- s.title){
                    property.add("title", JsonString(title))
                }
                if(let Some(description) <- s.description){
                    property.add("description", JsonString(description))
                }
                if(let Some(default) <- s.default){
                    property.add("default", JsonString(default))
                }
            }
        }else if (fieldType.qualifiedName.startsWith('Option<') || fieldType.qualifiedName.startsWith('std.core.Option<')){
            let qualifiedName = fieldType.qualifiedName
            let start = qualifiedName.indexOf('<').getOrThrow() + 1
            let generic = qualifiedName[start .. qualifiedName.size - 1] |> TypeInfo.get
            let property = toJsonSchema(generic, schema)
            property.add("nullable", JsonBool(true))
            return property
        }else if(fieldType.qualifiedName.startsWith('Array<') || 
                fieldType.qualifiedName.startsWith('std.core.Array<') || 
                fieldType.qualifiedName.startsWith('std.collection.ArrayList<') || 
                fieldType.qualifiedName.startsWith('std.collection.List<') ||
                fieldType.qualifiedName.startsWith('std.collection.Set<') ||
                fieldType.qualifiedName.startsWith('std.collection.HashSet<') ||
                fieldType.qualifiedName.startsWith('std.collection.TreeSet<')){
            property.add("type", JsonString("array"))
            if(let Some(s: JsonArraySchema) <- schema){
                if(let Some(minItems) <- s.minItems){
                    property.add("minItems", JsonInt(minItems))
                }
                if(let Some(maxItems) <- s.maxItems){
                    property.add("maxItems", JsonInt(maxItems))
                }
                if(let Some(uniqueItems) <- s.uniqueItems){
                    property.add("uniqueItems", JsonBool(uniqueItems))
                }
                if(let Some(title) <- s.title){
                    property.add("title", JsonString(title))
                }
                if(let Some(description) <- s.description){
                    property.add("description", JsonString(description))
                }
                if(let Some(items) <- s.items){
                    let qualifiedName = fieldType.qualifiedName
                    let start = qualifiedName.indexOf('<').getOrThrow() + 1
                    let genericType = qualifiedName[start .. qualifiedName.size - 1] |> TypeInfo.get
                    property.add("items", toJsonSchema(genericType, items))
                }else if(fieldType is ClassTypeInfo){
                    property.add('items', toJsonSchema(fieldType))
                }
            }
        }else {
            return toJsonSchema(fieldType)
        }
        property
    }
    private static func toJsonSchema(typeInfo: TypeInfo): JsonObject {
        let schema = JsonObject()
        schema.add("type", JsonString("object"))
        if(let Some(s) <- typeInfo.findAnnotation<JsonObjectSchema>()) {
            if(let Some(required) <- s.required){
                schema.add("required", JsonValue.fromStr(required).asArray())
            }
            if(let Some(additionalProperties) <- s.additionalProperties){
                schema.add("additionalProperties", JsonBool(additionalProperties))
            }
            if(let Some(title) <- s.title){
                schema.add("title", JsonString(title))
            }
            if(let Some(description) <- s.description){
                schema.add("description", JsonString(description))
            }
        }
        let properties = JsonObject()
        schema.add("properties", properties)
        if(let fields: Iterator<MutableField> <- typeInfo.getStaticFunction('mutableFields').apply(typeInfo)){
            for(f in fields){
                let fieldType = f.fieldTypeInfo
                properties.add(f.name, toJsonSchema(fieldType, f.tryFindAnnotation<JsonSchema>()))
            }
        }
        schema
    }
    public static func toJsonSchema<T>(): JsonObject where T <: ObjectData<T> {
        toJsonSchema(TypeInfo.of<T>())
    }
}

public sealed abstract class JsonSchema {
    public const init(){}
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class JsonBoolSchema <: JsonSchema {
    public const JsonBoolSchema(
        public let default!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class JsonIntSchema <: JsonSchema {
    public const JsonIntSchema(
        public let minimum!: ?Int64 = None,
        public let maximum!: ?Int64 = None,
        public let multipleOf!: ?Int64 = None,
        public let exclusiveMinimum!: Bool = false,
        public let exclusiveMaximum!: Bool = false,
        public let default!: ?Int64 = None,
        public let enumeration!: ?String = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class JsonFloatSchema <: JsonSchema {
    public const JsonFloatSchema(
        public let minimum!: ?Float64 = None,
        public let maximum!: ?Float64 = None,
        public let multipleOf!: ?Float64 = None,
        public let exclusiveMinimum!: Bool = false,
        public let exclusiveMaximum!: Bool = false,
        public let default!: ?Float64 = None,
        public let enumeration!: ?String = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class JsonStringSchema <: JsonSchema {
    public const JsonStringSchema(
        public let minLength!: ?Int64 = None,
        public let maxLength!: ?Int64 = None,
        public let pattern!: ?String = None,
        public let format!: ?String = None,
        public let enumeration!: ?String = None,
        public let default!: ?String = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class JsonArraySchema <: JsonSchema {
    public const JsonArraySchema(
        public let items!: ?JsonSchema = None,
        public let minItems!: ?Int64 = None,
        public let maxItems!: ?Int64 = None,
        public let uniqueItems!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class JsonObjectSchema <: JsonSchema {
    public const JsonObjectSchema(
        public let required!: ?String = None,
        public let additionalProperties!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}