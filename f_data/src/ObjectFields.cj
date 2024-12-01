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

public class ObjectFields<T> <: Iterable<ReadableField> where T <: ObjectData<T>{
    private let mutables = HashMap<String, MutableField>()
    private let readables = HashMap<String, ReadableField>()
    private ObjectFields(
        fields: Array<ReadableField>,
        private let creator: ()-> T
    ){
        //createFields(...)的嵌套函数populateFields(fields)会将fields填充到mutables readables
    }
    public static func createFields(fields: Array<ReadableField>, creator: ()-> T): ObjectFields<T> {
        let objf = ObjectFields<T>(fields, creator)
        func populateField(name: String, field: ReadableField, throwIfDuplicate!: Bool = true) {
            if(!objf.readables.putIfAbsent(name, field) && throwIfDuplicate){
                throw DataException('duplicate field ${name} in ${TypeInfos.get<T>()}')
            }
            match(field){
                case x: MutableField where !objf.mutables.putIfAbsent(name, x) && throwIfDuplicate => 
                    throw DataException('duplicate field ${name} in ${TypeInfos.get<T>()}')
                case _ => false
            }
        }
        func populateFields(fields: Iterable<ReadableField>, throwIfDuplicate!: Bool = true){
            for(f in fields){
                populateField(f.name, f, throwIfDuplicate: throwIfDuplicate)
            }
        }
        func populateFields(name: String, annotations: Collection<Annotation>) {
            let f = 
            if(let Some(f) <- objf.readables.get(name)){
                f
            }else{
                return
            }
            for(annotation in annotations) {
                match(annotation){
                    case x: FieldAlias => 
                        for(n in x.name.split(',')){
                            populateField(n, f)
                        }
                    case _ => ()
                }
            }
        }
        populateFields(fields)
        let currentType = (TypeInfos.get<T>() as ClassTypeInfo).getOrThrow()
        // for(v in currentType.instanceVariables) {
        //     populateFields(v.name, v.annotations)
        // }
        // for(p in currentType.instanceProperties) {
        //     populateFields(p.name, p.annotations)
        // }
        match(currentType.superClass) {
            case Some(x) where x != TypeInfos.get<Object>() && x.isSubtypeOf(TypeInfos.get("f_data.ObjectData<${x.qualifiedName}>")) =>
                let superFields = x.getStaticFunction("dataFields").apply()
                let superFieldsIterator = (superFields as ObjectFields<T>).getOrThrow().iterator()
                populateFields(superFieldsIterator, throwIfDuplicate: false)
            case _ => ()
        }
        objf
    }
    public func create(): T {
        creator()
    }
    public func iterator(): Iterator<ReadableField> {
        readables.values().iterator()
    }
    public func multableFields(): Iterator<MutableField> {
        mutables.values().iterator()
    }
    public func mutableField(name: String): ?MutableField {
        mutables.get(name)
    }
    public func readableField(name: String): ?ReadableField {
        readables.get(name)
    }
}
