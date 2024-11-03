/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_base

/**
 * 工作队列满的策略
 */
public enum WorkerStrategy{
    /**
     * 抛出JobQueueFullException
     */
    | Abort
    /**
     * 丢弃当前任务
     */
    | DiscardCurrent
    /**
     * 丢弃队头的的任务
     */
    | DiscardOldest
    /**
     * 一直阻塞
     */
    | Block
    /**
     * 等待Duration，然后抛出JobQueueFullException
     */
    | AbortAfter(Duration)
    /**
     * 等待Duration，然后抛出JobQueueFullException
     */
    | DiscardCurrentAfter(Duration)
    /**
     * 等待Duration，然后抛出JobQueueFullException
     */
    | DiscardOldestAfter(Duration)
    /**
     * 当前线程执行
     */
    | CurrentThread
    /**
     * 创建新实例，如果是任务队列就创建新线程，如果是ByteBuffer就创建新的ByteBuffer
     * 创建的新实例不受原工作线程或ByteBuffer池管理，用完即弃。
     */
    | New
}
