/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
*/
macro package f_data.validation.macros

import std.ast.*
import f_macros.*

public macro Validations(input: Tokens): Tokens {
    let decl = (parseDecl(input) as ClassDecl).getOrThrow()
    let name = decl.identifier + try{
        decl.genericParam.toTokens()
    }catch(e: Exception){
        `empty_tokens`
    }
    var tokens =
    baseValidations("IntegerValidation", name) +
    baseValidations("DecimalValidation", name) +
    baseValidations("EmailValidation", name) +
    baseValidations("EmailValidation", name) +
    chineseCellPhoneValidations(name) +
    integerRangeValidations(name) +
    regexValidations(name) +
    dateTimeValidations(name) +
    durationValidations(name) +
    stringsValidations("PascalsValidation", name) +
    stringsValidations("CamelsValidation", name) +
    stringsValidations("UpperUnderScoresValidation", name) +
    stringsValidations("LowerUnderScoresValidation", name) +
    stringsValidations("UpperHyphensValidation", name) +
    stringsValidations("LowerHyphensValidation", name) +
    quote(DummyValidator<$name>.instance)
    let validatorsName = Token(IDENTIFIER, "validators_${name.toString().replace(" ","").replace(",","_").replace("<","_").replace(">","_")}")
    input + `nl` + quote(
        let $validatorsName = Validators<$name>($tokens)
        extend<T> $name <: ValidatorsExtend<$name> {
            public static func validators(): Validators<$name> {
                $validatorsName
            }
        }
    ) + `nl`
}

func baseValidations(macroName: String, declName: Tokens): Tokens {
    var tokens = `empty_tokens`
    for (m in getChildMessages(macroName)) {
        let (name, dataType, rule) = extractMessage(m)
        let customised = m.getBool("customised")
        tokens += if(customised){
            quote(
                CustomisedValidator<$declName>($rule, $(name.value)){target, value => target.$name = $(dataType).parse(value)}
            )
        }else{
            let validator = Token(IDENTIFIER, "${rule}Validator") + quote(<$declName>)
            quote(
                $validator($(name.value)){target, value => target.$name = $(dataType).parse(value)}
            )
        } + `comma`
    }
    tokens
}
func chineseCellPhoneValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "ChineseCellPhoneValidator") + quote(<$declName>)
    var tokens = `empty_tokens`
    for(m in getChildMessages("ChineseCellPhoneValidation")){
        let (name, dataType, rule) = extractMessage(m)
        let withCode = m.getBool("NationalCode")
        let separator = m.getString("separator")
        tokens += quote(
            $validator($withCode, $separator, $(name.value)){target, value => target.$name = value}
        ) + `comma`
    }
    tokens
}
func integerRangeValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "IntegerRangeValidator") + quote(<$declName>)
    var tokens = `empty_tokens`
    for(m in getChildMessages("IntegerRangeValidation")){
        let (name, dataType, rule) = extractMessage(m)
        let range = m.getString("range")
        tokens += quote(
            $validator($range, $(name.value)){target, value => target.$name = $(dataType).parse(value)}
        ) + `comma`
    }
    tokens
}
func regexValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "IntegerRangeValidator") + quote(<$declName>)
    var tokens = `empty_tokens`
    for(m in getChildMessages("RegexValidation")){
        let (name, dataType, rule) = extractMessage(m)
        let regex = m.getString("regex")
        tokens += quote(
            $validator($regex, $(name.value)){target, value =>
                target.$name = match(value){
                    case x: $(dataType) => x
                    case x => $(dataType).parse(x)
                }
            }
        ) + `comma`
    }
    tokens
}
func dateTimeValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "DateTimeValidator") + quote(<$declName>)
    var tokens = `empty_tokens`
    for(m in getChildMessages("DateTimeValidation")){
        let (name, dataType, rule) = extractMessage(m)
        let format = m.getString("format")
        tokens += quote(
            $validator($format, $(name.value)){target, value => target.$name = DateTime.parse(value)}
        ) + `comma`
    }
    tokens
}
func durationValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "DurationValidator") + quote(<$declName>)
    var tokens = `empty_tokens`
    for(m in getChildMessages("DurationValidation")){
        let (name, dataType, rule) = extractMessage(m)
        tokens += quote(
            $validator($(name.value)){target, value => target.$name = Duration.parse(value)}
        ) + `comma`
    }
    tokens
}
func integersValidations(declName: Tokens): Tokens {
    let validator = Token(IDENTIFIER, "IntegersValidator") + quote(<$declName>)
    var tokens = `empty_tokens`
    for(m in getChildMessages("IntegersValidation")){
        let (name, dataType, rule) = extractMessage(m)
        tokens += quote(
            $validator($(name.value)){target, value => target.$name = $(dataType).parse(value)}
        ) + `comma`
    }
    tokens
}
func stringsValidations(macroName: String, declName: Tokens): Tokens {
    var tokens = `empty_tokens`
    for(m in getChildMessages(macroName)){
        let (name, dataType, rule) = extractMessage(m)
        let validator = Token(IDENTIFIER, "${rule}Validator") + quote(<$declName>)
        tokens += quote(
            $validator($(name.value)){target, value => target.$name = value.split(",")}
        ) + `comma`
    }
    tokens
}


func extractMessage(m: MacroMessage): (Token, Tokens, String){
    let name = Token(IDENTIFIER, m.getString("name"))
    let dataType = cangjieLex(m.getString("type"))
    let rule = m.getString("rule")
    (name, dataType, rule)
}
