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

private func toStringCond(primary: String, secondly: String): StringCond {
    if(primary.isEmpty() && secondly.isEmpty()){
        return IgnoreCond
    }
    Exactly(if(primary.isEmpty()){
        secondly
    }else{
        primary
    })
}
private func getArrayConfig<T>(primary: String, secondly: String, fn: (String) -> Array<T>): Array<T> {
    fn(primary)
}

private func getArrayConfig<T>(primary: String, secondly: String, default: Array<T>, fn: (String, String) -> Array<T>): Array<T> {
    let values = fn(primary, secondly)
    if (values.isEmpty()) {
        default
    } else {
        values
    }
}

public func getArrayConfig<T>(primary: String, secondly: String): Array<T> where T <: DataParsable<T> {
    getArrayConfig<T>(primary, secondly) {k => Config.getDatas<T>(k)}
}

public func getArrayConfig<T>(primary: String, secondly: String, default: Array<T>): Array<T> where T <: DataParsable<T> {
    getArrayConfig<T>(primary, secondly, default, getArrayConfig<T>)
}

public func getStringArrayConfig(primary: String, secondly: String): Array<String> {
    getArrayConfig<String>(primary, secondly) {k => Config.getStringArray(k)}
}

public func getStringArrayConfig(primary: String, secondly: String, default: Array<String>): Array<String> {
    getArrayConfig<String>(primary, secondly, default, getStringArrayConfig)
}

private func getConfig<T>(primary: String, secondly: String, fn: (String) -> ?T): ?T {
    fn(primary)
}

private func getConfig<T>(primary: String, secondly: String, default: T, fn: (String, String) -> ?T): T {
    fn(primary, secondly) ?? default
}

private func getConfig<T>(primary: String, secondly: String, default: ?T, fn: (String, String) -> ?T): ?T {
    let values = fn(primary, secondly)
    if (values.isSome()) {
        values
    } else {
        default
    }
}

public func getConfig<T>(primary: String, secondly: String): ?T where T <: DataParsable<T> {
    getConfig<T>(primary, secondly, Config.getData<T>)
}

public func getConfig<T>(primary: String, secondly: String, default: T): T where T <: DataParsable<T> {
    getConfig<T>(primary, secondly, default, getConfig<T>)
}

public func getConfig<T>(primary: String, secondly: String, default: ?T): ?T where T <: DataParsable<T> {
    getConfig<T>(primary, secondly, default, getConfig<T>)
}

public func getStringConfig(primary: String, secondly: String): ?String {
    getConfig<String>(primary, secondly, Config.getString)
}

public func getStringConfig(primary: String, secondly: String, default: String): String {
    getConfig<String>(primary, secondly, default, getStringConfig)
}

public func getStringConfig(primary: String, secondly: String, default: ?String): ?String {
    getConfig<String>(primary, secondly, default, getStringConfig)
}

public func getBean<T>(primary: StringCond, secondly: String): ?T where T <: Object {
    BeanFactory.instance.getFirst<T>(cond: primary)
}

public func getBean<T>(primary: String, secondly: String): ?T where T <: Object {
    getBean<T>(toStringCond(primary, secondly), secondly)
}

public func getBean<T>(primary: StringCond, secondly: String, default: ?T): ?T where T <: Object {
    let bean = getBean<T>(primary, secondly)
    if (bean.isSome()) {
        bean
    } else {
        default
    }
}

public func getBean<T>(primary: String, secondly: String, default: ?T): ?T where T <: Object {
    getBean<T>(Exactly(primary), secondly, default)
}

public func getBean<T>(primary: StringCond, secondly: String, default: T): T where T <: Object {
    getBean<T>(primary, secondly) ?? default
}

public func getBean<T>(primary: String, secondly: String, default: T): T where T <: Object {
    getBean<T>(Exactly(primary), secondly, default)
}

public func getBeanList<T>(primary: StringCond, secondly: String): ArrayList<T> where T <: Object {
    BeanFactory.instance.getList<T>(cond: primary)
}

public func getBeanList<T>(primary: String, secondly: String): ArrayList<T> where T <: Object {
    getBeanList<T>(toStringCond(primary, secondly), secondly)
}

public func getBeanList<T>(primary: StringCond, secondly: String, default: ArrayList<T>): ArrayList<T> where T <: Object {
    let beans = getBeanList<T>(primary, secondly)
    if (beans.isEmpty()) {
        beans
    } else {
        default
    }
}

public func getBeanList<T>(primary: String, secondly: String, default: ArrayList<T>): ArrayList<T> where T <: Object {
    getBeanList<T>(toStringCond(primary, secondly), secondly)
}

public func getBeanMap<T>(primary: StringCond, secondly: String): HashMap<String, T> where T <: Object {
    BeanFactory.instance.getMap<T>(cond: primary)
}

public func getBeanMap<T>(primary: String, secondly: String): HashMap<String, T> where T <: Object {
    getBeanMap<T>(Exactly(primary), secondly)
}

public func getBeanMap<T>(primary: StringCond, secondly: String, default: HashMap<String, T>): HashMap<String, T> where T <: Object {
    let beans = getBeanMap<T>(primary, secondly)
    if (beans.isEmpty()) {
        beans
    } else {
        default
    }
}

public func getBeanMap<T>(primary: String, secondly: String, default: HashMap<String, T>): HashMap<String, T> where T <: Object {
    getBeanMap<T>(Exactly(primary), secondly, default)
}
