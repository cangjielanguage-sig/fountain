/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_data.json

public interface ToJsonString {
    func toJsonString(): String
}
extend DataBool <: ToJsonString{
    public func toJsonString(): String{
        toString()
    }
}
extend DataDateTime <: ToJsonString{
    public func toJsonString(): String {
        '"${toString()}"'
    }
}
extend DataDuration <: ToJsonString {
    public func toJsonString(): String {
        '"${toString()}"'
    }
}
extend DataNone <: ToJsonString {
    public func toJsonString(): String {
        'null'
    }
}
extend<T> DataObject<T> <: ToJsonString where T <: Object & ObjectData<T> {
    public func toJsonString(): String {
        let builder = StringBuilder('{')
        var commaBefore = false
        for((name, value) in this){
            let valStr = 
            match(value){
                case x: ToJsonString => x.toJsonString()
                case _ => continue
            }
            if(commaBefore){
                builder.append(',')
            }
            builder.append('"${name}"', valStr)
            commaBefore = true
        }
        builder.append('}')
        builder.toString()
    }
}
extend DataReal <: ToJsonString {
    public func toJsonString(): String {
        toString()
    }
}
extend DataSequence <: ToJsonString {
    public func toJsonString(): String {
        let builder = StringBuilder('[')
        var commaBefore = false
        for(d in this){
            let valStr = 
            match(d){
                case x: ToJsonString => x.toJsonString()
                case _ => continue
            }
            if(commaBefore){
                builder.append(',')
            }
            builder.append(valStr)
            commaBefore = true
        }
        builder.append(']')
        builder.toString()
    }
}
extend StringKeyMapTuples <: ToJsonString {
    public func toJsonString(): String {
        let builder = StringBuilder('{')
        var commaBefore = false
        for(tuple in this){
            let valStr = 
            match((tuple.key, tuple.value)){
                case (x: DataString, y: ToJsonString) => '${x.toJsonString()}:${y.toJsonString()}'
                case _ => continue
            }
            if(commaBefore){
                builder.append(',')
            }
            builder.append(valStr)
            commaBefore = true
        }
        builder.append('}')
        builder.toString()
    }
}
extend DataString <: ToJsonString {
    public func toJsonString(): String {
        '"${toString()}"'
    }
}
