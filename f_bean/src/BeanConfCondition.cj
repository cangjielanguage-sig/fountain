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
 * 配置项满足条件时on返回true
 */
public enum ConfCond <: BeanCondition {
    /**
     * 忽略配置条件
     */
    | IgnoreConf
    /**
     * 存在配置项是返回true
     */
    | Exists(String)
    /**
     * 不存在配置项时返回true
     */
    | NotExists(String)
    /**
     * 存在配置项且配置项的值满足StringCond，如果StringCond.IgnoreCond相当于Exists(String)
     */
    | Value(String, StringCond)

    public func on(_: BeanFactory): Bool {
        match(this){
            case IgnoreConf => true
            case Exists(key) => Config.getString(key).isSome()
            case NotExists(key) => Config.getString(key).isNone()
            case Value(key, val) => match(Config.getString(key)){
                case Some(x) => val.on(x)
                case _ => false
            }
        }
    }
}