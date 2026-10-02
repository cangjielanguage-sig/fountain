## JSON SCHEMA
```cj
package fountain::f_data.json

public interface ToJsonSchema {
    static func toJsonSchema<T>(): String where T <: ObjectData<T>
}

extend JsonObject <: ToJsonSchema

public sealed abstract class JsonSchema {
    public const init(){}
}

@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonBoolSchema <: JsonSchema {
    public const JsonBoolSchema(
        public let default!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}

@Annotation[target: [MemberVariable, MemberProperty]]
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

@Annotation[target: [MemberVariable, MemberProperty]]
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
@Annotation[target: [MemberVariable, MemberProperty]]
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
@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonArraySchema <: JsonSchema {
    public const JsonArraySchema(
        public let items!: ?JsonSchema = None,
        public let minItems!: ?Int64 = None,
        public let maxItems!: ?Int64 = None,
        public let uniqueItems!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
@Annotation[target: [MemberVariable, MemberProperty]]
public class JsonObjectSchema <: JsonSchema {
    public const JsonObjectSchema(
        public let required!: ?String = None,
        public let additionalProperties!: ?Bool = None,
        public let title!: ?String = None,
        public let description!: ?String = None){}
}
```
