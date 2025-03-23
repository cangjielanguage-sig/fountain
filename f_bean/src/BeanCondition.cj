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

public interface IBeanCondition {
    func on(ringChecker: RingChecker): Bool
}

@Annotation[target: [Type, MemberFunction]]
public class BeanCondition <: IBeanCondition {
    public const BeanCondition(public let condition: IBeanCondition) {}
    public func on(ringChecker: RingChecker): Bool {
        condition.on(ringChecker)
    }
}

public class OnAnd <: IBeanCondition {
    public const OnAnd(public let conditions: Array<IBeanCondition>) {}

    public func on(ringChecker: RingChecker): Bool {
        for (c in conditions where !c.on(ringChecker)) {
            return false
        }
        return true
    }
}

public class OnOr <: IBeanCondition {
    public const OnOr(public let conditions: Array<IBeanCondition>) {}

    public func on(ringChecker: RingChecker): Bool {
        for (c in conditions where c.on(ringChecker)) {
            return true
        }
        return false
    }
}

public class OnNot <: IBeanCondition {
    public const OnNot(public let condition: IBeanCondition) {}
    public func on(ringChecker: RingChecker) {
        !condition.on(ringChecker)
    }
}
/**
 * 值是运行时计算并传入构造器
 */
public class OnBool <: IBeanCondition {
    public const OnBool(public let cond: (RingChecker) -> Bool) {}
    public func on(ringChecker: RingChecker): Bool {
        cond(ringChecker)
    }
}

/**
 * 只支持WithType和Missing，由于反射无法获得子类型，故其它的TypeDef一律返回true
 */
public class OnType <: IBeanCondition {
    public const OnType(public let typeDef: TypeDef) {}
    public func on(ringChecker: RingChecker): Bool {
        match (typeDef) {
            case WithType(t) => try {
                TypeInfo.of(t)
                true
            } catch (_) {
                false
            }
            case Missing(t) => try {
                TypeInfo.of(t)
                false
            } catch (_) {
                false
            }
            case _ => true //反射无法获得子类型，故一律返回true
        }
    }
}

/**
 * 当前应用的bean符合本注解的条件才初始化被它修饰的Bean
 */
public class OnBean <: IBeanCondition {
    public const OnBean(
        public let nameDef!: ?BeanNameDef = None,
        public let typeDef!: ?TypeDef = None,
        public let beanDef!: ?BeanDef = None
    ) {}
    public func on(ringChecker: RingChecker): Bool {
        BeanChecker(dependency: false, nameDef: nameDef, typeDef: typeDef, beanDef: beanDef).on(ringChecker)
    }
}

var _webApp = false
public func setWebApp() {
    _webApp = true
}
/**
 * 当前是WebApp才初始化被它修饰的bean
 */
public class OnWebApp <: IBeanCondition {
    public const init() {}
    public func on(ringChecker: RingChecker): Bool {
        _webApp
    }
}

/**
 * 当前应用的配置符合本注解的条件才初始化被它修饰的Bean
 */
public class OnConf <: IBeanCondition {
    public const OnConf(public let conf: ConfDef<String>) {}

    public func on(ringChecker: RingChecker): Bool {
        func extractValue(key: String) {
            Config.getString(key).getOrThrow {BeanException("config item of ${key} does not exist")}
        }
        match (conf) {
            case WithKey(key) => Config.getString(key).isSome()
            case WithoutKey(key) => Config.getString(key).isNone()
            case MatchValue(key, val) => extractValue(key) == val
            case NotMatchValue(key, val) => extractValue(key) != val
        }
    }
}

/**
 * 当前应用的环境变量符合本注解的条件才初始化被它修饰的Bean
 */
public class OnEnv <: IBeanCondition {
    public const OnEnv(public let env: ConfDef<String>) {}

    public func on(ringChecker: RingChecker): Bool {
        let enviroment = Process.current.environment
        match (env) {
            case WithKey(key) => enviroment.contains(key)
            case WithoutKey(key) => !enviroment.contains(key)
            case MatchValue(key, val) => enviroment.get(key) == val
            case NotMatchValue(key, val) => enviroment.get(key) != val
        }
    }
}
/**
 * 当前应用的命令行参数符合本注解的条件才初始化被它修饰的Bean
 */
public class OnCmdArg <: IBeanCondition {
    public const OnCmdArg(public let cmd: ConfDef<String>) {}

    public func on(ringChecker: RingChecker): Bool {
        let args = Process.current.arguments
        match (cmd) {
            case WithKey(key) => CmdArgs.instance.getArg(key).isSome()
            case WithoutKey(key) => CmdArgs.instance.getArg(key).isNone()
            case MatchValue(key, val) => CmdArgs.instance.getArg(key) == val
            case NotMatchValue(key, val) => CmdArgs.instance.getArg(key) != val
        }
    }
}
/**
 * 指定文件符合本注解的条件才初始化被它修饰的Bean
 */
public class OnFile <: IBeanCondition {
    public const OnFile(public let path!: String, public let missing!: Bool = false) {}

    public func on(ringChecker: RingChecker): Bool {
        let exists = exists(this.path)
        (missing && !exists) || (!missing && exists)
    }
}
