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
package fountain::f_data.base

public abstract class Validator {
    private let messageIfNotMatch_: String
    public const Validator(messageIfNotMatch!: String = '') {
        this.messageIfNotMatch_ = messageIfNotMatch
    }
    public func validate(value: ?String): Bool

    public const operator func &(right: Validator): Validator {
        AndValidator(this, right)
    }
    public const operator func |(right: Validator): Validator {
        OrValidator(this, right)
    }
    public const operator func !(): Validator {
        NotValidator(this)
    }
    public prop description: String
    public prop messageIfNotMatch: String {
        get(){
            if(this.messageIfNotMatch_.isEmpty()){
                description
            }else{
                this.messageIfNotMatch_
            }
        }
    }
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class CombinedValidator <: Validator {
    public const CombinedValidator(messageIfNotMatch: String, public let validator: Validator){
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public const init(validator: Validator){
        this('', validator)
    }
    public func validate(value: ?String): Bool {
        this.validator.validate(value)
    }
    public prop description: String {
        get(){
            validator.description
        }
    }
}
public class DummyValidator <: Validator {
    public static const instance = DummyValidator()
    private const init() {}
    public func validate(value: ?String): Bool {
        return true
    }
    public prop description: String {
        get(){
            ''
        }
    }
}
public class AndValidator <: Validator{
    const AndValidator(private let left: Validator, private let right: Validator){}
    public func validate(value: ?String): Bool {
        left.validate(value) && right.validate(value)
    }
    public prop description: String {
        get(){
            '(必须同时满足 ${left.description} 与 ${right.description})'
        }
    }
}
public class OrValidator <: Validator{
    const OrValidator(private let left: Validator, private let right: Validator){}
    public func validate(value: ?String): Bool {
        left.validate(value) || right.validate(value)
    }
    public prop description: String {
        get(){
            '(满足 ${left.description} 或 ${right.description} 之一)'
        }
    }
}
public class NotValidator <: Validator{
    const NotValidator(private let condition: Validator){}
    public func validate(value: ?String): Bool {
        !condition.validate(value)
    }
    public prop description: String {
        get(){
            '(必须不满足 ${condition.description})'
        }
    }
}