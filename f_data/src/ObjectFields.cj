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

public class ObjectFields<O> <: Iterable<ReadableField> where O <: Object & DataObject<O> {
    private let mutables = HashMap<String, MutableField>()
    private let readables = HashMap<String, ReadableField>()
    public ObjectFields(
        fields: Array<ReadableField>,
        private let creator: ()-> O
    ){
        func populateField(name: String, field: ReadableField) {
            readables.putIfAbsent(name, field)
            match(field){
                case x: MutableField => mutables.putIfAbsent(name, x)
                case _ => false
            }
        }
        func populateFields(fields: Iterable<ReadableField>){
            for(f in fields){
                populateField(f.name, f)
            }
        }
        let currentType = (TypeInfos.get<O>() as ClassTypeInfo).getOrThrow()
        populateFields(fields)
        func populateFields(name: String, annotations: Collection<Annotation>) {
            for(annotation in annotations) {
                match(annotation){
                    case x: FieldAlias => populateField(x.name, readables[name])
                    case _ => ()
                }
            }
        }
        for(v in currentType.instanceVariables) {
            populateFields(v.name, v.annotations)
        }
        for(p in currentType.instanceProperties) {
            populateFields(p.name, p.annotations)
        }
        match(currentType.superClass) {
            case Some(x) where x != TypeInfos.get<Object>() =>
                let superFields = TypeInfos.get("fountain/data.DataObject<${x.qualifiedName}>").getStaticFunction("dataFields").apply()
                let superFieldsIterator = (TypeInfo.of(superFields).getInstanceFunction("iterator").apply(superFields) as Iterator<ReadableField>).getOrThrow()
                populateFields(superFieldsIterator)
            case _ => ()
        }
    }
    public func create(): O {
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
