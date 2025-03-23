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

//实现本接口的类是一个工厂，本接口的实现需要使用@BeanCreation[...]注册到BeanFactory，
//从BeanFactory用本接口实现对应的beanName得到的是接口实现的get()函数返回的Bean
public interface FactoryBean {
    prop singletonFactory: Bool
    func get(): Any
    func postConstruct(){}
    func destroy(){}
    func beanPostConstruct(bean: Any): Unit {
        BeanMeta.defaultPostConstruct(bean)
    }
    func beanDestroy(bean: Any): Unit {
        BeanMeta.defaultDestroy(bean)
    }
}
