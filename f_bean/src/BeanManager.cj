/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::f_bean

public class BeanManager <: Comparable<BeanManager> & ToString {
    private static let serialGen = AtomicInt64(1)
    private let mutex = Mutex()
    public let index = serialGen.fetchAdd(1)
    private let _name: String
    private let _bean = AtomicOptionReference()
    /**
     * §2.18 / BEAN-5：`scope.isSingleton` 的判定结果在构造期算一次。
     * 原先是每次取 bean 都算：默认 scope（`BeanScope.singleton` 常量）靠 `refEq` 短路约 20 ns，
     * 自定义 scope 实例则退到 `typeInfo` 比较、约 170 ns/次（每次还要两次 `TypeInfo.of` 获取）。
     * 该值构造后不再改变，用普通 `let` 成员即可（与 `meta`/`beanType`/`_name` 同一发布路径，无需原子）。
     */
    private let _singleton: Bool
    public BeanManager(
        public let meta: BeanMeta,
        public let beanType: TypeInfo,
        private let creator: () -> Object
    ) {
        _singleton = meta.scope.isSingleton
        _name = if (meta.name.isEmpty()) {
            '${beanType.qualifiedName}_${index}'
        } else {
            meta.name
        }
    }

    public func toString(): String {
        'name: ${name}; lazy: ${meta.lazy}; scope: ${meta.scope}; order: ${meta.order}; primary:${meta.primary}; condition: ${meta.condition}; type: ${beanType}'
    }

    internal func doDestroy(): Unit {
        if (let Some(b) <- _bean.load() && let x: Destroy <- b) {
            x.destroy()
        }
    }
    /**
     * 如果有自定义BeanScope，调用这个函数生成销毁函数，
     * 同一自定义BeanScope且相同生命周期的的bean应在生命周期结束时统一调用本函数生成的函数销毁bean。
     */
    internal func generateDestroy(object: Object): () -> Unit {
        {
            => if (let x: Destroy <- object) {
                x.destroy()
            }
        }
    }
    internal func on(factory: BeanFactory): Bool {
        meta.condition.on(factory)
    }
    internal func initIfNeed(): Bool {
        if (shouldInitBean && !meta.lazy && _singleton) {
            _bean.store(new())
            true
        }else{
            false
        }
    }
    private func new(): Object {
        let o = creator()
        if (let x: PostConstruct <- o) {
            x.postConstruct()
        }
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
            if (_singleton) {
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
