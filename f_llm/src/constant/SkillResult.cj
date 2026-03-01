/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_llm.constant

/**
 * 技能返回给智能体的结果
 * 事件名要么由技能描述，要求大模型按照执行的结果把事件名和其它数据一起作为函数参数返回，再由函数调用将事件名和函数执行结果返回给智能体。
 * 要么由技能描述，要求大模型同时事件名和事件消息，智能体接收到以后
 */
public enum SkillResult {
    /**
     * 构造器参数是技能给智能体返回的事件名，智能体按照这个事件名构造新的事件
     */
    | NextEvent(String)
    /**
     * 第一个构造器参数是技能给智能体返回的事件名，智能体按照这个事件名构造新的事件
     * 第二个构造器参数是技能给智能体返回的事件数据，智能体按照这个事件名和数据构造新的事件
     * 第二个参数务必是简单字符串或者是MARKDOWN格式。
     * @param eventName 事件名
     * @param eventData 事件数据
     */
    | NextEvent(String, String)
}