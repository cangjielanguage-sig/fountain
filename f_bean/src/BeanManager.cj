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

public class BeanManager <: Comparable<BeanManager> {
    private static let serialGen = AtomicInt64(1)
    private let serial = serialGen.fetchAdd(1)
    public BeanManager(private let meta: BeanMeta) {}
    public func destroy(o: Any): Unit {
        if(let Some(fb) <- factoryBean){
            fb.beanDestroy(o)
        }else{
            meta.destroy(o)
        }
    }
    public func destroy(): Unit {
        if(let Some(fb) <- factoryBean){
            fb.destroy()
        }
    }

    public prop name: String {
        get() {
            let n = meta.name
            if(n.isEmpty()){
                "${typeInfo}-${serial}"
            }else{
                n
            }
        }
    }
    public prop typeInfo: TypeInfo {
        get(){
            meta.typeInfo
        }
    }
    public prop scope: BeanScope{
        get(){
            meta.scope
        }
    }
    public prop primary: Bool {
        get(){
            meta.primary
        }
    }
    private prop order: Int64 {
        get(){
            meta.order
        }
    }
    public prop lazy: Bool {
        get(){
            meta.lazy
        }
    }
    prop dependencies: Array<BeanDependency>{
        get(){
            meta.dependencies
        }
    }
    public func compare(other: BeanManager): Ordering {
        var ordering =
        if(this.primary && !other.primary){
            Ordering.LT
        }else if(other.primary && !this.primary){
            Ordering.GT
        }else{
            this.order.compare(other.order)
        }
        if(ordering == EQ){
            ordering = this.serial.compare(other.serial)
        }
        ordering
    }
    private let mutex = ReentrantMutex()
    private var bean: ?Any = None
    private var factoryBean: ?FactoryBean = None
    //如果creator()返回的是值类型会先用Box<Any>包装一遍再执行postConstruct，返回的也是包装以后的
    public func get(): Any {
        func creator(){
            var o = match(meta.creator()){
                case x: FactoryBean =>
                    x.postConstruct()
                    let bean = x.get()
                    x.beanPostConstruct(bean)
                    factoryBean = x
                    x
                case x => x
            }
            if (o is Object) {
                meta.postConstruct(o)
                o
            } else {
                let o = Box<Any>(o)
                meta.postConstruct(o)
                o.value
            }
        }
        match(scope){
            case Singleton =>
                if(let None <- bean){
                    synchronized(mutex){
                        if(let None <- bean){
                            this.bean = creator()
                        }
                    }
                }
                this.bean
            case _ => creator()
        }
    }
}
