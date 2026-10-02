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
package fountain::f_uring.base

/**
 * io_uring 包入口文件
 *
 * 本包提供 Linux io_uring 的高性能异步 I/O 绑定，基于 liburing FFI 封装。
 *
 * ## 快速开始
 *
 * ```cj
 * package fountain::f_uring.base
 *
 * try(ring = IoUring(64)) {
 *     let sqe = ring.getSQE()
 *     if (let Some(s) <- sqe) {
 *         ioUringPrepNop(s)
 *         ioUringSQESetData64(s, 1)
 *         ring.submit()
 *     }
 *     let cqe = ring.waitCQE()
 *     if (let Some(c) <- cqe) {
 *         println("result: ${ioUringCQEGetRes(c)}")
 *         ring.cqeSeen(c)
 *     }
 * }
 * ```
 *
 * ## 主要组件
 *
 * - **IoUring** — 核心 io_uring 封装，实现 Resource 接口
 * - **IoUringPool** — 多实例池，适用于多线程场景
 * - **IoUringParamsBuilder** — 初始化参数构建器
 * - **IoUringFuture / IoUringPromise** — 基于 Mutex+Condition 的异步 Future
 * - **CompletionRegistry** — 完成槽位注册表
 * - **IOUringBufferRing** — Provided Buffer Ring
 * - **RegisteredFiles / RegisteredBuffers** — 固定文件/缓冲区注册
 *
 * ## 无锁并发（需额外导入）
 *
 * ```cj
 * import fountain::f_uring.lockfree.*
 * ```
 *
 * - **IoUringLockFree** — 无锁并发 io_uring 封装
 * - **AtomicSlotAllocator** — 原子槽位分配器
 * - **CompletionSlotArray** — generation 保护的回调数组
 * - **CompletionCallback / LambdaCompletionCallback** — 完成回调
 *
 * ## 线程安全
 *
 * - IoUring 实例非线程安全，多线程需用 IoUringPool 或 IoUringLockFree
 * - IoUringLockFree.submitAsync 内部用 Mutex 保护 getSQE+submit
 * - 收割路径建议在主线程用 reap() + sleep 轮询
 *
 * ## 平台限制
 *
 * 所有声明使用 @When[os == "Linux"] 条件编译，仅 Linux 平台可用。
 */
