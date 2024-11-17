/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

import std.collection.concurrent.ConcurrentHashMap
import f_collection.TreeSet

public interface Data {
    func toModel(): DataModel
}

extend Int8 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend UInt8 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Int16 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend UInt16 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Int32 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend UInt32 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Int64 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend UInt64 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend IntNative <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend UIntNative <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Float16 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Float32 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Float64 <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend BigInt <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Decimal <: Data {
    public func toModel(): RealModel {
        RealModel(this)
    }
}

extend Bool <: Data {
    public func toModel(): BoolModel {
        if (this) {
            BoolModel.TRUE
        } else {
            BoolModel.FALSE
        }
    }
}

extend Rune <: Data {
    public func toModel(): RuneModel {
        RuneModel(this)
    }
}

extend String <: Data {
    public func toModel(): StringModel {
        StringModel(this)
    }
}

extend Duration <: Data {
    public func toModel(): DurationModel {
        DurationModel(this)
    }
}

extend DateTime <: Data {
    public func toModel(): DateTimeModel {
        DateTimeModel(this)
    }
}

extend<T> Array<T> <: Data where T <: Data {
    public func toModel(): DataModel {
        match (this) {
            case x: Array<Byte> => ByteArrayModel(x)
            case _ =>
                let model = SequenceModel()
                for (v in this) {
                    model.append(v)
                }
                model
        }
    }
}
public interface SequenceData<T> <: Data where T <: Data {
    func iterator(): Iterator<T>
    func toModel(): DataModel {
        let model = SequenceModel()
        for (v in iterator()) {
            model.append(v)
        }
        model
    }
} 
extend<T> ArrayList<T> <: SequenceData<T> where T <: Data {
}
extend<T> HashSet<T> <: SequenceData<T> where T <: Data & Hashable & Equatable<T> {

}
extend<T> TreeSet<T> <: SequenceData<T> where T <: Data & Comparable<T> {

}
extend<K, V> HashMap<K, V> <: Data where K <: Data & Hashable & Equatable<K>, V <: Data {
    public func toModel(): DataModel{
        match(this){
            case x: HashMap<String, V> => 
                let model = StringKeyMapModel()
                for((k, v) in x){
                    model.put(k, v)
                }
                model
            case x => 
                let model = SequenceModel()
                for((k, v) in x){
                    model.append(TupleModel.create(k, v))
                }
                model
        }
    }
}
extend<K, V> TreeMap<K, V> <: Data where K <: Data & Comparable<K>, V <: Data {
    public func toModel(): DataModel{
        match(this){
            case x: TreeMap<String, V> => 
                let model = StringKeyMapModel()
                for((k, v) in x){
                    model.put(k, v)
                }
                model
            case x => 
                let model = SequenceModel()
                for((k, v) in x){
                    model.append(TupleModel.create(k, v))
                }
                model
        }
    }
}
extend<K, V> ConcurrentHashMap<K, V> <: Data where K <: Data & Hashable & Equatable<K>, V <: Data {
    public func toModel(): DataModel{
        match(this){
            case x: ConcurrentHashMap<String, V> => 
                let model = StringKeyMapModel()
                for((k, v) in x){
                    model.put(k, v)
                }
                model
            case x => 
                let model = SequenceModel()
                for((k, v) in x){
                    model.append(TupleModel.create(k, v))
                }
                model
        }
    }
}