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
 * IoUringParams 构建器
 *
 * 使用流式 API 构建 IOUringParams 实例。
 * 每个 setter 方法返回 this，支持链式调用。
 *
 * 使用示例：
 * ```cj
 * let params = IoUringParamsBuilder()
 *     .setSQPOLL()
 *     .setSQPOLLIdle(2000)
 *     .build()
 * let ring = IoUring(64, params)
 * ```
 */
@When[os == "Linux"]
public class IoUringParamsBuilder {
    private var params: IOUringParams = IOUringParams()

    public init() {}

    /**
     * 启用 SQPOLL 模式
     * 
     * 内核线程轮询 SQ，避免系统调用开销。
     * 需要 CAP_SYS_NICE 权限或非特权 SQPOLL 支持。
     */
    public func setSQPOLL(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_SQPOLL
        this
    }

    /**
     * 设置 SQPOLL 空闲超时
     * 
     * 仅在 SQPOLL 模式下有效。
     * 内核线程空闲指定毫秒后自动退出。
     * 
     * @param ms 空闲超时（毫秒）
     */
    public func setSQPOLLIdle(ms: UInt32): IoUringParamsBuilder {
        params.sqThreadIdle = ms
        this
    }

    /**
     * 设置 CQ 队列大小
     * 
     * 默认 CQ 大小为 SQ 的 2 倍。通过此方法可显式指定。
     * 
     * @param size CQ 条目数
     */
    public func setCQSize(size: UInt32): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_CQSIZE
        params.cqEntries = size
        this
    }

    /**
     * 启用 Single Issuer 模式
     * 
     * 优化单线程提交场景的性能。
     */
    public func setSingleIssuer(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_SINGLE_ISSUER
        this
    }

    /**
     * 启用延迟任务运行
     * 
     * 完成事件在提交线程上下文中处理，减少上下文切换。
     */
    public func setDeferTaskRun(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_DEFER_TASKRUN
        this
    }

    /**
     * 启用 I/O 轮询
     * 
     * 内核主动轮询 I/O 完成事件，降低延迟。
     * 适用于低延迟场景，但会占用更多 CPU。
     */
    public func setIOPoll(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_IOPOLL
        this
    }

    /**
     * 绑定 SQ 线程到指定 CPU
     * 
     * 仅在 SQPOLL 模式下有效。
     * 
     * @param cpu CPU 编号
     */
    public func setSQAff(cpu: UInt32): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_SQ_AFF
        params.sqThreadCpu = cpu
        this
    }

    /**
     * 启用 CQ 大小限制
     * 
     * 当 CQ 大小超过可用内存时，限制为可用大小而非失败。
     */
    public func setClamp(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_CLAMP
        this
    }

    /**
     * 绑定到已有工作队列
     * 
     * 多个 io_uring 实例共享同一个内核线程池。
     * 
     * @param wqFd 工作队列文件描述符
     */
    public func setAttachWQ(wqFd: UInt32): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_ATTACH_WQ
        params.wqFd = wqFd
        this
    }

    /**
     * 启用提交全部模式
     * 
     * io_uring_enter 调用时提交所有待处理的 SQE。
     */
    public func setSubmitAll(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_SUBMIT_ALL
        this
    }

    /**
     * 启用协作式任务运行
     * 
     * 完成事件在任务上下文中处理，减少中断。
     */
    public func setCoopTaskRun(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_COOP_TASKRUN
        this
    }

    /**
     * 启用 128 字节 SQE
     * 
     * 扩展 SQE 大小到 128 字节，支持 uring_cmd 等大操作码。
     */
    public func setSQE128(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_SQE128
        this
    }

    /**
     * 启用 32 字节 CQE
     * 
     * 扩展 CQE 大小到 32 字节，包含额外 16 字节的 big_cqe 数据。
     */
    public func setCQE32(): IoUringParamsBuilder {
        params.flags = params.flags | IORING_SETUP_CQE32
        this
    }

    /**
     * 构建并返回 IOUringParams 值
     * 
     * 返回的是 params 的值拷贝（@C struct 是值类型）。
     * 构建器可以复用来创建多个不同配置的 params。
     * 
     * @return 构建好的 IOUringParams 实例
     */
    public func build(): IOUringParams {
        params
    }
}
