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
package f_rx

/**
 * 背压策略
 */
public enum BackPressure {
    /**
     * 直接丢弃
     */
    | Discarding
    /**
     * 丢弃队列头部数据
     */
    | DropOldest
    /**
     * 一直阻塞
     */
    | AlwaysBlocking
    /**
     * 阻塞指定时长后丢弃
     */
    | BlockingOrDiscarding(Duration)
    /**
     * 阻塞指定时长后抛出异常
     */
    | BlockingOrThrowing(Duration)
    /**
     * 阻塞指定时长后丢弃队列头部数据
     */
    | BlockingOrDroppingOldest(Duration)
    /**
     * 立即抛出异常
     */
    | Throwing
    /**
     * 使用当前线程处理
     */
    | Current
    /**
     * 使用新线程处理
     */
    | NewThread
    /**
     * 使用指定函数处理
     */
    | Action((() -> Unit) -> Unit)
    /**
     * 阻塞指定时间后使用当前线程处理
     */
    | BlockingOrCurrent(Duration)
    /**
     * 阻塞指定时间后创建新线程处理
     */
    | BlockingOrNewThread(Duration)
    /**
     * 阻塞指定时间后使用指定函数处理
     */
    | BlockingOrAction(Duration, (() -> Unit) -> Unit)
}
