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
package f_data.validation

import std.collection.HashMap
import std.convert.Parsable
import std.time.DateTime
import f_data.*

public interface Validator<T> {
    prop name: String
    func set(data: T, value: String): Unit
}

public class Validators<T> {
    private let validatorMap = HashMap<String, Validator<T>>()
    public init(validators: Array<Validator<T>>) {
        for (v in validators where !(v is DummyValidator<T>)) {
            validatorMap[v.name] = v
        }
    }
    public func validator(name: String): Validator<T> {
        validatorMap[name]
    }
}

public interface ValidatorsExtend<T> {
    static func validators(): Validators<T>
}

public class DummyValidator<T> <: Validator<T> {
    public const init() {}
    // public static const instance = DummyValidator<T>()
    public prop name: String {
        get() {
            ""
        }
    }
    public func set(data: T, value: String): Unit {
    }
}

abstract sealed class BaseValidator<T> <: Validator<T> {
    BaseValidator(private let rule: String, private let _name_: String, private let setter: (T, String) -> Unit) {}
    public prop name: String {
        get() {
            _name_
        }
    }
    protected open func validate(value: String): Bool {
        validate(rule, value)
    }
    public func set(data: T, value: String): Unit {
        if (validate(value)) {
            setter(data, value)
        } else {
            throw IllegalArgumentException("${value} does not match")
        }
    }
}

public class IntegerValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("Integer", _name_, setter)
    }
}

public class DecimalValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("Decimal", _name_, setter)
    }
}

public class EmailValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("Email", _name_, setter)
    }
}

public class ChineseCellPhoneValidator<T> <: BaseValidator<T> {
    private let withCode: Bool
    private let separator: String
    public init(withCode: Bool, separator: String, _name_: String, setter: (T, String) -> Unit) {
        super("ChineseCellPhone", _name_, setter)
        this.withCode = withCode
        this.separator = separator
    }
    public func validate(value: String): Bool {
        super.validate(value) && (!withCode || match (separator) {
            case ")" => value.startsWith("(86)")
            case x => value.startsWith("86${x}")
        })
    }
}

public class IntegerRangeValidator<T> <: BaseValidator<T> {
    private let range: Range<Int64>
    public init(range: String, _name_: String, setter: (T, String) -> Unit) {
        super("IntegerRange", _name_, setter)
        let (start, end) = match ((range[0], range[range.size - 1])) {
            case (b'[', b']') => (true, true)
            case (b'[', b')') => (true, false)
            case (b'(', b']') => (false, true)
            case (b'(', b')') => (false, false)
            case _ => throw IllegalArgumentException("illegal IntegerRange: ${range}")
        }
        let r = range[1..range.size - 1].split(",")
        this.range = Range(Int64.parse(r[0].trimAscii()), Int64.parse(r[1].trimAscii()), 1, start, end, end)
    }
    public func validate(value: String): Bool {
        if (let Some(v) <- Int64.tryParse(value)) {
            ((range.hasStart && v >= range.start) || (!range.hasStart && v > range.start)) && ((range.hasEnd && v <= range
                .end) || (!range.hasEnd && v < range.end))
        } else {
            false
        }
    }
}

public class DateTimeValidator<T> <: BaseValidator<T> {
    private let format: String
    public init(format: String, _name_: String, setter: (T, String) -> Unit) {
        super("DateTime: ${format}", _name_, setter)
        this.format = format
    }
    public func validate(value: String): Bool {
        DateTime.parse(value, format)
        true
    }
}

public class DurationValidator<T> <: BaseValidator<T> {
    private static let format = Regex(#"^-?(\d+)(d|h|m|s|ms|us|ns))$"#)
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("Duration", _name_, setter)
    }
    public func validate(value: String): Bool {
        format.matches(value)
    }
}

public class IntegersValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("Integers", _name_, setter)
    }
}

public class PascalsValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("Pascals", _name_, setter)
    }
}

public class CamelsValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("Camels", _name_, setter)
    }
}

public class LowerUnderScoresValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("LowerUnderScores", _name_, setter)
    }
}

public class UpperUnderScoresValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("UpperUnderScores", _name_, setter)
    }
}

public class LowerHyphensValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("LowerHyphens", _name_, setter)
    }
}

public class UpperHyphensValidator<T> <: BaseValidator<T> {
    public init(_name_: String, setter: (T, String) -> Unit) {
        super("UpperHyphens", _name_, setter)
    }
}

public class CustomisedValidator<T> <: BaseValidator<T> {
    public init(rule: String, _name_: String, setter: (T, String) -> Unit) {
        super(rule, _name_, setter)
    }
}
