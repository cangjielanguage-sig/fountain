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
package fountain::f_rpc.base

import std.sync.AtomicBool
import fountain::f_codec.default.DefaultCodec

/**
 * RPC 用到的池的配置项（f_rpc 自己不建池，它把 f_codec 的两个全局池按配置初始化）。
 *
 * 为什么在这里：池的等待上限 `maxWaiting` 是**池初始化参数**（见 .autocode/bugs/bug-archived-on-20261004.md 7.6），
 * f_pool 不读配置；由使用方在自己的配置里给出值 —— ORM 那边是 `orm_databasePoolMaxWaiting`，
 * RPC 这边就是本文件这些 `rpc_codec*` 项。
 *
 * 可见性用 `protected`（module 级）：本文件在 `f_rpc.base`，而调用方 `f_rpc.client` /
 * `f_rpc.server` 是**兄弟包**（`internal` 只覆盖"当前包及其子包"）。
 *
 * 调用时机：`RPCServer.start()` / `RPCClient.start()`（首次），只初始化一次。
 * **不要**在包初始化期读配置（§7.7 的教训：那一刻 Config 可能未就绪，会把整包 init 打挂）。
 */

/** 编码缓冲池（`BytesListOutputStream` 背后的 ArrayListPool）的初始/最小/最大条目数。 */
protected const RPC_CODEC_BUFFER_POOL_INIT_SIZE = 'rpc_codecBufferPoolInitSize'
protected const RPC_CODEC_BUFFER_POOL_MIN_SIZE = 'rpc_codecBufferPoolMinSize'
protected const RPC_CODEC_BUFFER_POOL_MAX_SIZE = 'rpc_codecBufferPoolMaxSize'
/** 字节数组池（文件载荷 / 大块字节）的初始/最小/最大条目数与单条数组长度。 */
protected const RPC_CODEC_BYTES_POOL_INIT_SIZE = 'rpc_codecBytesPoolInitSize'
protected const RPC_CODEC_BYTES_POOL_MIN_SIZE = 'rpc_codecBytesPoolMinSize'
protected const RPC_CODEC_BYTES_POOL_MAX_SIZE = 'rpc_codecBytesPoolMaxSize'
protected const RPC_CODEC_BYTES_POOL_ARRAY_SIZE = 'rpc_codecBytesPoolArraySize'
/**
 * 两个池共用的等待上限：池耗尽时 `get(timeout: Duration.Max)` 超过它就 WARN 并返回 None；
 * 配成 ≤ 0（如 `0s`）表示真无限等待（实现仍每轮让出 CPU）。缺省 30s，与 f_pool / f_codec 的默认一致。
 * 配置值按 `Duration.toString()` 的格式书写，例如 `rpc_codecPoolMaxWaiting=30s`。
 */
protected const RPC_CODEC_POOL_MAX_WAITING = 'rpc_codecPoolMaxWaiting'

private func codecBufferPoolInitSize(): Int64 {
    Config.getValue<Int64>(RPC_CODEC_BUFFER_POOL_INIT_SIZE) ?? 1024
}
private func codecBufferPoolMinSize(): Int64 {
    Config.getValue<Int64>(RPC_CODEC_BUFFER_POOL_MIN_SIZE) ?? 1024
}
private func codecBufferPoolMaxSize(): Int64 {
    Config.getValue<Int64>(RPC_CODEC_BUFFER_POOL_MAX_SIZE) ?? 1024
}
private func codecBytesPoolInitSize(): Int64 {
    Config.getValue<Int64>(RPC_CODEC_BYTES_POOL_INIT_SIZE) ?? 0
}
private func codecBytesPoolMinSize(): Int64 {
    Config.getValue<Int64>(RPC_CODEC_BYTES_POOL_MIN_SIZE) ?? 1
}
private func codecBytesPoolMaxSize(): Int64 {
    Config.getValue<Int64>(RPC_CODEC_BYTES_POOL_MAX_SIZE) ?? 1024
}
private func codecBytesPoolArraySize(): Int64 {
    Config.getValue<Int64>(RPC_CODEC_BYTES_POOL_ARRAY_SIZE) ?? 4096
}
/** 缺省 30s；配成 ≤ 0（如 `0s`）视为"真无限等待"。 */
private func codecPoolMaxWaiting(): Duration {
    let duration = Config.getData<Duration>(RPC_CODEC_POOL_MAX_WAITING) ?? Duration.second * 30
    if (duration <= Duration.Zero) {
        Duration.Max
    } else {
        duration
    }
}
private let codecPoolsInitialized = AtomicBool(false)
/**
 * 按配置初始化 codec 的两个池（编码缓冲池 / 字节数组池）。
 * 首次调用生效，之后重复调用直接返回 —— 不把正在被借用的池换掉。
 */
protected func initCodecPools(): Unit {
    if (!codecPoolsInitialized.compareAndSwap(false, true)) {
        return
    }
    let maxWaiting = codecPoolMaxWaiting()
    DefaultCodec.setBufferPool(
        initSize: codecBufferPoolInitSize(), minSize: codecBufferPoolMinSize(), maxSize: codecBufferPoolMaxSize(),
        maxWaiting: maxWaiting)
    DefaultCodec.setBytesPool(
        initSize: codecBytesPoolInitSize(), minSize: codecBytesPoolMinSize(), maxSize: codecBytesPoolMaxSize(),
        arraySize: codecBytesPoolArraySize(), maxWaiting: maxWaiting)
    rpclog.debug {
        '[FOUNTAIN_RPC.pool] codec pools initialized: bufferPool(init=${codecBufferPoolInitSize()}, min=${codecBufferPoolMinSize()}, max=${codecBufferPoolMaxSize()}), bytesPool(init=${codecBytesPoolInitSize()}, min=${codecBytesPoolMinSize()}, max=${codecBytesPoolMaxSize()}, arraySize=${codecBytesPoolArraySize()}), maxWaiting=${maxWaiting}'
    }
}
