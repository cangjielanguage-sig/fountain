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
    private let mutex = ReentrantMutex()
    public let index = serialGen.fetchAdd(1)
    private let _name: String
    private let _bean = AtomicOptionReference()
    public BeanManager(
        public let meta: BeanMeta,
        public let beanType: TypeInfo,
        private let creator: () -> Object,
        private let postConstruct!: (Object) -> Unit = {o =>},
        private let destroy!: (Object) -> Unit = {o =>}
    ) {
        _name = if (meta.name.isEmpty()) {
            '${beanType.qualifiedName}_${index}'
        } else {
            meta.name
        }
    }
    internal func doDestroy(): Unit {
        if (let Some(b) <- _bean.load()) {
            destroy(b)
        }
    }
    /**
     * 如果有自定义BeanScope，调用这个函数生成销毁函数，
     * 同一自定义BeanScope且相同生命周期的的bean应在生命周期结束时统一调用本函数生成的函数销毁bean。
     */
    internal func generateDestroy(object: Object): () -> Unit {
        {=> destroy(object)}
    }
    internal func on(factory: BeanFactory): Bool {
        meta.condition.on(factory)
    }
    internal func initIfNeed(): Unit {
        if (shouldInitBean && !meta.lazy && meta.scope.isSingleton) {
            _bean.store(new())
        }
    }
    private func new(): Object {
        let o = creator()
        postConstruct(o)
        match (o) {
            case x: FactoryBean => x.get()
            case _ => o
        }
    }
    public prop name: String {
        get() {
            _name
        }
    }
    public func compare(manager: BeanManager) {
        match (this.meta.compare(manager.meta)) {
            case EQ => this.name.compare(manager.name)
            case x => x
        }
    }
    public prop bean: Object {
        get() {
            if (meta.scope.isSingleton) {
                if (let Some(x) <- _bean.load()) {
                    x
                } else {
                    synchronized(mutex) {
                        if (let Some(x) <- _bean.load()) {
                            x
                        } else {
                            let o = new()
                            _bean.store(o)
                            o
                        }
                    }
                }
            } else {
                new()
            }
        }
    }
}
