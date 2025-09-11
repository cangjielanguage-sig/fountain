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
macro package f_data.validation.macros

import std.ast.*
import f_macros.*

public macro Validations(input: Tokens): Tokens {
    let decl = (parseDecl(input) as ClassDecl).getOrThrow()
    let name = decl.identifier + try {
        decl.genericParam.toTokens()
    } catch (e: Exception) {
        `empty_tokens`
    }
    let tokens = quote().append(baseValidations("IntegerValidation", name))
                        .append(baseValidations("DecimalValidation", name))
                        .append(baseValidations("EmailValidation", name))
                        .append(baseValidations("EmailValidation", name))
                        .append(chineseCellPhoneValidations(name))
                        .append(integerRangeValidations(name))
                        .append(regexValidations(name))
                        .append(dateTimeValidations(name))
                        .append(durationValidations(name))
                        .append(stringsValidations("PascalsValidation", name))
                        .append(stringsValidations("CamelsValidation", name))
                        .append(stringsValidations("UpperUnderScoresValidation", name))
                        .append(stringsValidations("LowerUnderScoresValidation", name))
                        .append(stringsValidations("UpperHyphensValidation", name))
                        .append(stringsValidations("LowerHyphensValidation", name))
                        .append(quote(DummyValidator<$name>.INSTANCE))
    let validatorsName = Token(IDENTIFIER,
        "validators_${name.toString().replace(" ", "").replace(",", "_").replace("<", "_").replace(">", "_")}")
    input + `nl` + quote(
        let $validatorsName = Validators<$name>($tokens)
        extend<T> $name <: ValidatorsExtend<$name> {
            public static func validators(): Validators<$name> {
                $validatorsName
            }
        }
    ) +
        `nl`
}

func baseValidations(macroName: String, declName: Tokens): Tokens {
    let tokens = quote()
    for (m in getChildMessages(macroName)) {
        let (name, dataType, rule) = extractMessage(m)
        let customised = m.getBool("customised")
        tokens.append(if (customised) {
            quote(
                CustomisedValidator<$declName>($rule, $(name.value)){target, value => target.$name = $(dataType).parse(value)}
            )
        } else {
            let validator = Token(IDENTIFIER, "${rule}Validator") + quote(<$declName>)
            quote(
                $validator($(name.value)){target, value => target.$name = $(dataType).parse(value)}
            )
        }).append(`comma`)
    }
    tokens
}

func chineseCellPhoneValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "ChineseCellPhoneValidator") + quote(<$declName>)
    let tokens = quote()
    for (m in getChildMessages("ChineseCellPhoneValidation")) {
        let (name, dataType, rule) = extractMessage(m)
        let withCode = m.getBool("NationalCode")
        let separator = m.getString("separator")
        tokens.append(quote(
            $validator($withCode, $separator, $(name.value)){target, value => target.$name = value}
        )).append(`comma`)
    }
    tokens
}

func integerRangeValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "IntegerRangeValidator") + quote(<$declName>)
    let tokens = quote()
    for (m in getChildMessages("IntegerRangeValidation")) {
        let (name, dataType, rule) = extractMessage(m)
        let range = m.getString("range")
        tokens.append(quote(
            $validator($range, $(name.value)){target, value => target.$name = $(dataType).parse(value)}
        )).append(`comma`)
    }
    tokens
}

func regexValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "IntegerRangeValidator") + quote(<$declName>)
    let tokens = quote()
    for (m in getChildMessages("RegexValidation")) {
        let (name, dataType, rule) = extractMessage(m)
        let regex = m.getString("regex")
        tokens.append(quote(
            $validator($regex, $(name.value)){target, value =>
                target.$name = match(value){
                    case x: $(dataType) => x
                    case x => $(dataType).parse(x)
                }
            }
        )).append(`comma`)
    }
    tokens
}

func dateTimeValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "DateTimeValidator") + quote(<$declName>)
    let tokens = quote()
    for (m in getChildMessages("DateTimeValidation")) {
        let (name, dataType, rule) = extractMessage(m)
        let format = m.getString("format")
        tokens.append(quote(
            $validator($format, $(name.value)){target, value => target.$name = DateTime.parse(value)}
        )).append(`comma`)
    }
    tokens
}

func durationValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "DurationValidator") + quote(<$declName>)
    let tokens = quote()
    for (m in getChildMessages("DurationValidation")) {
        let (name, dataType, rule) = extractMessage(m)
        tokens.append(quote(
            $validator($(name.value)){target, value => target.$name = Duration.parse(value)}
        )).append(`comma`)
    }
    tokens
}

func integersValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "IntegersValidator") + quote(<$declName>)
    let tokens = quote()
    for (m in getChildMessages("IntegersValidation")) {
        let (name, dataType, rule) = extractMessage(m)
        tokens.append(quote(
            $validator($(name.value)){target, value => target.$name = $(dataType).parse(value)}
        )).append(`comma`)
    }
    tokens
}

func stringsValidations(macroName: String, declName: Tokens): Tokens {
    let tokens = quote()
    for (m in getChildMessages(macroName)) {
        let (name, dataType, rule) = extractMessage(m)
        let validator = Token(IDENTIFIER, "${rule}Validator") + quote(<$declName>)
        tokens.append(quote(
            $validator($(name.value)){target, value => target.$name = value.split(",")}
        )).append(`comma`)
    }
    tokens
}

func extractMessage(m: MacroMessage): (Token, Tokens, String) {
    let name = Token(IDENTIFIER, m.getString("name"))
    let dataType = cangjieLex(m.getString("type"))
    let rule = m.getString("rule")
    (name, dataType, rule)
}
