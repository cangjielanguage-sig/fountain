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

internal import stdx.net.http.HttpHeaders

public interface ExtendHttpHeaders{}
extend HttpHeaders <: ExtendHttpHeaders {
    public func getFirstValue<T>(name: String): ?T where T <: DataParsable<T>{
        match (this.getFirst(name)) {
            case Some(x) => T.tryParse(x)
            case _ => None<T>
        }
    }
    public func getValues<T>(name: String): Collection<T> where T <: DataParsable<T> {
        let list = ArrayList<T>()
        for (v in get(name)) {
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
        let header = StringBuilder()
        var i = 0
        while(i < value.size) {
            if (header.size > 0) {
                header.append(",")
            }
            header.append(value[i])
            i++
        }
        set(name, header.toString())
    }

    public func set<C, T>(name: String, value: C): Unit where T <: ToString, C <: Collection<T> {
        let header = StringBuilder()
        for (v in value) {
            if (header.size > 0) {
                header.append(",")
            }
            header.append(v)
        }
        set(name, header.toString())
    }
    public func add<T>(headers: Array<(String, T)>): Unit where T <: ToString {
        for(h in headers) {
            add<T>(h[0], h[1])
        }
    }

    public func set<T>(headers: Array<(String, T)>): Unit where T <: ToString {
        for(h in headers) {
            set<T>(h[0], h[1])
        }
    }

    public func add<C, T>(headers: C): Unit where T <: ToString, C <: Collection<(String, T)> {
        for(h in headers) {
            add<T>(h[0], h[1])
        }
    }

    public func set<C, T>(headers: C): Unit where T <: ToString, C <: Collection<(String, T)> {
        for(h in headers) {
            set<T>(h[0], h[1])
        }
    }
}
