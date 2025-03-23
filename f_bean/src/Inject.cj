/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_bean

/**
 * 用于参数注入，可以注解成员变量、成员变量形参、一般形参
 * @Constructor
 * public init(bean1: BeanClass){}
 *
 * @Constructor
 * public static func creator(@Inject["beanName"]bean1: BeanClass){}
 *
 * @Constructor
 * public init(@Inject["beanName"]bean1: BeanClass){}
 */
@Annotation[target: [Parameter, MemberVariable]]
public class Inject{
    public const Inject(public let pattern!: InjectionPattern){}

    public func extract(): (String, String){
        match(pattern){
            case Name(n) => ("name", n)
            case Prefix(n) => ("prefix", n)
            case Suffix(n) => ("suffix", n)
            case Wildcard(n) => ("wildcard", n)
            case Regex(n) => ("regex", n)
        }
    }
}
public enum InjectionPattern{
    | Name(String)
    | Prefix(String)
    | Suffix(String)
    | Wildcard(String)
    | Regex(String)
}
