/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_mvc

public class MVCConfig {
    private static const confPrefix = "fountain.mvc"
    public static let UPLOAD_HALF_BUFFER_SIZE = "${confPrefix}.upload.half.buffer.size"
    public static const DEFAULT_UPLOAD_HALF_BUFFER_SIZE = 2048
    public static let DOWNLOAD_BUFFER_SIZE = "${confPrefix}.download.half.buffer.size"
    public static const DEFAULT_DOWNLOAD_BUFFER_SIZE = 4096

    public static let MVC_DEBUGGING = "${confPrefix}.mvc.debugging"
    public static const DEFAULT_MVC_DEBUGGING = false

    public static let UPLOAD_DIR = "${confPrefix}.upload.dir"
    public static const DEFAULT_UPLOAD_DIR = "/tmp/fountain/upload"

    public static let UPLOAD_STORE_IN_MEMORY = "${confPrefix}.upload.store.in.memory"
    public static const DEFAULT_UPLOAD_STORE_IN_MEMORY = false

    public static let ACCESS_CONTROL_ALLOW_ORIGIN = "${confPrefix}.access.control.allow.origin"
    public static const DEFAULT_ACCESS_CONTROL_ALLOW_ORIGIN = "*"

    public static let ACCESS_CONTROL_ALLOW_HEADERS = "${confPrefix}.access.control.allow.headers"
    public static const DEFAULT_ACCESS_CONTROL_ALLOW_HEADERS = "*"

    public static let ACCESS_CONTROL_MAX_AGE = "${confPrefix}.access.control.max.age"
    public static const DEFAULT_ACCESS_CONTROL_MAX_AGE = 0

    public static let AUTH_FAILURE_STATUS = "${confPrefix}.auth.failure.status"
    public static const DEFAULT_AUTH_FAILURE_STATUS = 511u16
    public static let AUTH_FAILURE_MESSAGE = "${confPrefix}.auth.failure.message"
    public static let AUTH_FAILURE_MESSAGE_KIND = "${confPrefix}.auth.failure.message.kind"
    public static const DEFAULT_AUTH_FAILURE_MESSAGE_KIND = FailureMessageKind.Text

    public static let PRIVILEGE_FAILURE_STATUS = "${confPrefix}.privilege.failure.status"
    public static const DEFAULT_PRIVILEGE_FAILURE_STATUS = 510u16
    public static let PRIVILEGE_FAILURE_MESSAGE = "${confPrefix}.privilege.failure.message"
    public static let PRIVILEGE_FAILURE_MESSAGE_KIND = "${confPrefix}.privilege.failure.message.kind"
    public static const DEFAULT_PRIVILEGE_FAILURE_MESSAGE_KIND = FailureMessageKind.Text

    public static let HOST = "${confPrefix}.host"
    public static let PORT = "${confPrefix}.port"
    public static let READ_TIMEOUT = "${confPrefix}.read.timeout"
    public static let WRITE_TIMEOUT = "${confPrefix}.write.timeout"
    public static let READ_HEADER_TIMEOUT = "${confPrefix}.read.header.timeout"
    public static let KEEP_ALIVE_TIMEOUT = "${confPrefix}.keep.alive.timeout"
    public static let MAX_REQUEST_HEADER_SIZE = "${confPrefix}.max.request.header.size"
    public static let MAX_REQUEST_BODY_SIZE = "${confPrefix}.max.request.body.size"
    public static let HEADER_TABLE_SIZE = "${confPrefix}.header.table.size"
    public static let MAX_CONCURRENT_STREAMS = "${confPrefix}.max.concurrent.steams"
    public static let INITITAL_WINDOW_SIZE = "${confPrefix}.initial.window.size"
    public static let MAX_FRAME_SIZE = "${confPrefix}.max.frame.size"
    public static let MAX_HEADER_LIST_SIZE = "${confPrefix}.max.header.list.size"

    public static let SERVICE_POOL_CAPACITY = "${confPrefix}.service.pool.capacity"
    public static let SERVICE_POOL_QUEUE_CAPACITY = "${confPrefix}.service.pool.queue.capacity"
    public static let SERVICE_POOL_PREHEAT = "${confPrefix}.service.pool.preheat"

    private static prop isMVCDebugging: Bool {
        get() {
            Config.getValue<Bool>(MVC_DEBUGGING) ?? DEFAULT_MVC_DEBUGGING
        }
    }
    public static prop servicePoolConfig: ?ServicePoolConfig {
        get(){
            let capacity = Config.getValue<Int64>(SERVICE_POOL_CAPACITY)
            let queueCapacity = Config.getValue<Int64>(SERVICE_POOL_QUEUE_CAPACITY)
            let preheat = Config.getValue<Int64>(SERVICE_POOL_PREHEAT)
            match((capacity, queueCapacity, preheat)) {
                case (Some(c), Some(qc), Some(ph)) =>
                    ServicePoolConfig(
                        capacity: c,
                        queueCapacity: qc,
                        preheat: ph
                    )
                case (Some(c), Some(qc), Option<Int64>.None) =>
                    ServicePoolConfig(
                        capacity: c,
                        queueCapacity: qc
                    )
                case (Some(c), Option<Int64>.None, Option<Int64>.None) =>
                    ServicePoolConfig(
                        capacity: c
                    )
                case (Option<Int64>.None, Some(qc), Option<Int64>.None) =>
                    ServicePoolConfig(
                        queueCapacity: qc
                    )
                case (Some(c), Option<Int64>.None, Some(ph)) =>
                    ServicePoolConfig(
                        capacity: c,
                        preheat: ph
                    )
                case (Option<Int64>.None, Option<Int64>.None, Some(ph)) =>
                    ServicePoolConfig(
                        preheat: ph
                    )
                case (Option<Int64>.None, Some(qc), Some(ph)) =>
                    ServicePoolConfig(
                        queueCapacity: qc,
                        preheat: ph
                    )
                case _ => None<ServicePoolConfig>
            }
        }
    }
    public static prop host: String {
        get(){
            Config.getString(HOST) ?? "0.0.0.0"
        }
    }
    public static prop port: UInt16 {
        get(){
            Config.getValue<UInt16>(PORT) ?? 8080
        }
    }
    private static func duration(key: String) {
        match(Config.getString(key)){
            case Some(x) => Duration.tryParse(x)
            case _ => None<Duration>
        }
    }

    public static prop readTimeout: ?Duration {
        get(){
            duration(READ_TIMEOUT)
        }
    }
    public static prop writeTimeout: ?Duration {
        get(){
            duration(WRITE_TIMEOUT)
        }
    }
    public static prop readHeaderTimeout: ?Duration {
        get(){
            duration(READ_HEADER_TIMEOUT)
        }
    }
    public static prop keepAliveTimeout: ?Duration {
        get(){
            duration(KEEP_ALIVE_TIMEOUT)
        }
    }
    public static prop maxRequestHeaderSize: ?Int64 {
        get(){
            Config.getValue<Int64>(MAX_REQUEST_HEADER_SIZE)
        }
    }
    public static prop maxRequestBodySize: ?Int64 {
        get(){
            Config.getValue<Int64>(MAX_REQUEST_BODY_SIZE)
        }
    }
    private static func uint32(key: String): ?UInt32 {
        match(Config.getValue<UInt32>(key)) {
            case Some(x) => UInt32(x)
            case _ => None
        }
    }
    public static prop headerTableSize: ?UInt32 {
        get(){
            uint32(HEADER_TABLE_SIZE)
        }
    }
    public static prop maxConcurrentStreams: ?UInt32 {
        get(){
            uint32(MAX_CONCURRENT_STREAMS)
        }
    }
    public static prop initialWindowSize: ?UInt32 {
        get(){
            uint32(INITITAL_WINDOW_SIZE)
        }
    }
    public static prop maxFrameSize: ?UInt32 {
        get(){
            uint32(MAX_FRAME_SIZE)
        }
    }
    public static prop maxHeaderListSize: ?UInt32 {
        get(){
            uint32(MAX_HEADER_LIST_SIZE)
        }
    }
    private static func getStatus(key: String, default: UInt16){
        let status =
        match(Config.getValue<UInt16>(key)){
            case Some(x) => UInt16(x)
            case _ => default
        }
        HttpStatus.valueOf(status)
    }
    private static func getMessageKind(key: String, kind: FailureMessageKind) {
        match(Config.getString(key)) {
            case Some(x) => FailureMessageKind.parse(x)
            case _ => kind
        }
    }
    public static prop authFailureStatus: HttpStatus {
        get() {
            getStatus(AUTH_FAILURE_STATUS, DEFAULT_AUTH_FAILURE_STATUS)
        }
    }
    public static prop authFailureMessage: Array<Byte> {
        get() {
            let msg = Config.getString(AUTH_FAILURE_MESSAGE) ?? authFailureStatus.reasonPhrase
            authFailureMessageKind.toBytes(msg)
        }
    }
    public static prop authFailureMessageKind: FailureMessageKind {
        get() {
            getMessageKind(AUTH_FAILURE_MESSAGE_KIND, DEFAULT_AUTH_FAILURE_MESSAGE_KIND)
        }
    }

    public static prop privilegeFailureStatus: HttpStatus {
        get() {
            getStatus(PRIVILEGE_FAILURE_STATUS, DEFAULT_PRIVILEGE_FAILURE_STATUS)
        }
    }
    public static prop privilegeFailureMessage: Array<Byte> {
        get() {
            let msg = Config.getString(PRIVILEGE_FAILURE_MESSAGE) ?? privilegeFailureStatus.reasonPhrase
            privilegeFailureMessageKind.toBytes(msg)
        }
    }
    public static prop privilegeFailureMessageKind: FailureMessageKind {
        get() {
            getMessageKind(PRIVILEGE_FAILURE_MESSAGE_KIND, DEFAULT_PRIVILEGE_FAILURE_MESSAGE_KIND)
        }
    }

    private static func bufferSize(bufferKey: String, default: Int64) {
        if (let Some(x) <- Config.getValue<Int64>(bufferKey)) {
                if (x > 0 && isMVCDebugging) {
                    x
                } else if (x <= 0) {
                    default
                }
                var s = 1
                while (s < x) {
                    s <<= 1
                }
                if (s >= default) {
                    s
                } else {
                    default
                }
            } else {
                default
            }
    }
    public static prop uploadHalfBufferSize: Int64 {
        get() {
            bufferSize(UPLOAD_HALF_BUFFER_SIZE, DEFAULT_UPLOAD_HALF_BUFFER_SIZE)
        }
    }
    public static prop downloadBufferSize: Int64 {
        get() {
            bufferSize(DOWNLOAD_BUFFER_SIZE, DEFAULT_DOWNLOAD_BUFFER_SIZE)
        }
    }
    public static prop uploadDir: String {
        get() {
            Config.getString(UPLOAD_DIR) ?? DEFAULT_UPLOAD_DIR
        }
    }
    public static prop uploadStoreInMemory: Bool {
        get() {
            Config.getValue<Bool>(UPLOAD_STORE_IN_MEMORY) ?? DEFAULT_UPLOAD_STORE_IN_MEMORY
        }
    }
    public static prop accessControlAllowOrigin: String {
        get(){
            Config.getString(ACCESS_CONTROL_ALLOW_ORIGIN) ?? DEFAULT_ACCESS_CONTROL_ALLOW_ORIGIN
        }
    }
    public static prop accessControlAllowHeaders: String {
        get(){
            Config.getString(ACCESS_CONTROL_ALLOW_HEADERS) ?? DEFAULT_ACCESS_CONTROL_ALLOW_HEADERS
        }
    }
    public static prop accessControlMaxAge: Int64 {
        get(){
            Config.getValue<Int64>(ACCESS_CONTROL_MAX_AGE) ?? DEFAULT_ACCESS_CONTROL_MAX_AGE
        }
    }

}
