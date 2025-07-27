/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
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
}
