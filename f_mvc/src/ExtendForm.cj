/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_mvc

internal import encoding.url.Form

public interface ExtendForm{}
extend Form <: ExtendForm {
    public func getValue<T>(name: String): ?T where T <: DataParsable<T> {
        match(get(name)) {
            case Some(x) => T.tryParse(x)
            case _ => None<T>
        }
    }
    public func getAllValues<T>(name: String): ArrayList<T> where T <: DataParsable<T> {
        let list = ArrayList<T>()
        for(v in getAll(name)) {
            list.add(T.parse(v))
        }
        list
    }
    public func set<T>(name: String, value: T): Unit where T <: ToString {
        set(name, value.toString())
    }
    public func add<T>(name: String, value: T): Unit where T <: ToString {
        add(name, value.toString())
    }
    public func set<T>(name: String, value: Array<T>): Unit where T <: ToString {
        let val = StringBuilder()
        var i = 0
        while(i < value.size) {
            if (val.size > 0) {
                val.append(",")
            }
            val.append(value[i])
            i++
        }
        set(name, val.toString())
    }

    public func set<C, T>(name: String, value: C): Unit where T <: ToString, C <: Collection<T> {
        let val = StringBuilder()
        for (v in value) {
            if (val.size > 0) {
                val.append(",")
            }
            val.append(v)
        }
        set(name, val.toString())
    }
    public func add<T>(values: Array<(String, T)>): Unit where T <: ToString {
        for(v in values) {
            add<T>(v[0], v[1])
        }
    }

    public func set<T>(values: Array<(String, T)>): Unit where T <: ToString {
        for(v in values) {
            set<T>(v[0], v[1])
        }
    }

    public func add<C, T>(values: C): Unit where T <: ToString, C <: Collection<(String, T)> {
        for(v in values) {
            add<T>(v[0], v[1])
        }
    }

    public func set<C, T>(values: C): Unit where T <: ToString, C <: Collection<(String, T)> {
        for(v in values) {
            set<T>(v[0], v[1])
        }
    }
}
