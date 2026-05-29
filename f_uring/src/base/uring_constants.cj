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
 * io_uring 常量定义
 * 仅在 Linux 平台可用
 */

// ==================== io_uring_setup flags ====================

/** io_context is polled */
@When[os == "Linux"]
public const IORING_SETUP_IOPOLL: UInt32 = 0x00000001

/** SQ poll thread */
@When[os == "Linux"]
public const IORING_SETUP_SQPOLL: UInt32 = 0x00000002

/** sq_thread_cpu is valid */
@When[os == "Linux"]
public const IORING_SETUP_SQ_AFF: UInt32 = 0x00000004

/** app defines CQ size */
@When[os == "Linux"]
public const IORING_SETUP_CQSIZE: UInt32 = 0x00000008

/** clamp SQ/CQ ring sizes */
@When[os == "Linux"]
public const IORING_SETUP_CLAMP: UInt32 = 0x00000010

/** attach to existing wq */
@When[os == "Linux"]
public const IORING_SETUP_ATTACH_WQ: UInt32 = 0x00000020

/** start with ring disabled */
@When[os == "Linux"]
public const IORING_SETUP_R_DISABLED: UInt32 = 0x00000040

/** continue submit on error */
@When[os == "Linux"]
public const IORING_SETUP_SUBMIT_ALL: UInt32 = 0x00000080

/** cooperative task running */
@When[os == "Linux"]
public const IORING_SETUP_COOP_TASKRUN: UInt32 = 0x00000100

/** taskrun flag for notification */
@When[os == "Linux"]
public const IORING_SETUP_TASKRUN_FLAG: UInt32 = 0x00000200

/** SQEs are 128 byte */
@When[os == "Linux"]
public const IORING_SETUP_SQE128: UInt32 = 0x00000400

/** CQEs are 32 byte */
@When[os == "Linux"]
public const IORING_SETUP_CQE32: UInt32 = 0x00000800

/** only one task is allowed to submit */
@When[os == "Linux"]
public const IORING_SETUP_SINGLE_ISSUER: UInt32 = 0x00001000

/** defer running task work to get events */
@When[os == "Linux"]
public const IORING_SETUP_DEFER_TASKRUN: UInt32 = 0x00002000

/** application provides ring memory */
@When[os == "Linux"]
public const IORING_SETUP_NO_MMAP: UInt32 = 0x00004000

/** register ring fd, return registered fd index */
@When[os == "Linux"]
public const IORING_SETUP_REGISTERED_FD_ONLY: UInt32 = 0x00008000

// ==================== io_uring_enter flags ====================

/** get events */
@When[os == "Linux"]
public const IORING_ENTER_GETEVENTS: UInt32 = 0x00000001

/** SQ poll wakeup */
@When[os == "Linux"]
public const IORING_ENTER_SQ_WAKEUP: UInt32 = 0x00000002

/** SQ poll wait */
@When[os == "Linux"]
public const IORING_ENTER_SQ_WAIT: UInt32 = 0x00000004

/** extended argument */
@When[os == "Linux"]
public const IORING_ENTER_EXT_ARG: UInt32 = 0x00000008

/** use registered ring fd */
@When[os == "Linux"]
public const IORING_ENTER_REGISTERED_RING: UInt32 = 0x00000010

// ==================== SQE flags (IOSQE_*) ====================

/** use fixed fileset */
@When[os == "Linux"]
public const IOSQE_FIXED_FILE: UInt8 = 0x01

/** issue after inflight IO */
@When[os == "Linux"]
public const IOSQE_IO_DRAIN: UInt8 = 0x02

/** links next sqe */
@When[os == "Linux"]
public const IOSQE_IO_LINK: UInt8 = 0x04

/** like LINK, but stronger */
@When[os == "Linux"]
public const IOSQE_IO_HARDLINK: UInt8 = 0x08

/** always go async */
@When[os == "Linux"]
public const IOSQE_ASYNC: UInt8 = 0x10

/** select buffer from sqe->buf_group */
@When[os == "Linux"]
public const IOSQE_BUFFER_SELECT: UInt8 = 0x20

/** don't post CQE if request succeeded */
@When[os == "Linux"]
public const IOSQE_CQE_SKIP_SUCCESS: UInt8 = 0x40

// ==================== CQE flags (IORING_CQE_F_*) ====================

/** buffer ID in upper 16 bits */
@When[os == "Linux"]
public const IORING_CQE_F_BUFFER: UInt32 = 0x00000001

/** parent SQE will generate more CQEs */
@When[os == "Linux"]
public const IORING_CQE_F_MORE: UInt32 = 0x00000002

/** more data to read after socket recv */
@When[os == "Linux"]
public const IORING_CQE_F_SOCK_NONEMPTY: UInt32 = 0x00000004

/** notification CQE */
@When[os == "Linux"]
public const IORING_CQE_F_NOTIF: UInt32 = 0x00000008

/** buffer shift for extracting buffer ID */
@When[os == "Linux"]
public const IORING_CQE_BUFFER_SHIFT: Int32 = 16

// ==================== SQ ring flags (IORING_SQ_*) ====================

/** needs io_uring_enter wakeup */
@When[os == "Linux"]
public const IORING_SQ_NEED_WAKEUP: UInt32 = 0x00000001

/** CQ ring is overflown */
@When[os == "Linux"]
public const IORING_SQ_CQ_OVERFLOW: UInt32 = 0x00000002

/** task should enter the kernel */
@When[os == "Linux"]
public const IORING_SQ_TASKRUN: UInt32 = 0x00000004

// ==================== CQ ring flags (IORING_CQ_*) ====================

/** disable eventfd notifications */
@When[os == "Linux"]
public const IORING_CQ_EVENTFD_DISABLED: UInt32 = 0x00000001

// ==================== io_uring opcodes (IORING_OP_*) ====================

@When[os == "Linux"]
public const IORING_OP_NOP: UInt8 = 0

@When[os == "Linux"]
public const IORING_OP_READV: UInt8 = 1

@When[os == "Linux"]
public const IORING_OP_WRITEV: UInt8 = 2

@When[os == "Linux"]
public const IORING_OP_FSYNC: UInt8 = 3

@When[os == "Linux"]
public const IORING_OP_READ_FIXED: UInt8 = 4

@When[os == "Linux"]
public const IORING_OP_WRITE_FIXED: UInt8 = 5

@When[os == "Linux"]
public const IORING_OP_POLL_ADD: UInt8 = 6

@When[os == "Linux"]
public const IORING_OP_POLL_REMOVE: UInt8 = 7

@When[os == "Linux"]
public const IORING_OP_SYNC_FILE_RANGE: UInt8 = 8

@When[os == "Linux"]
public const IORING_OP_SENDMSG: UInt8 = 9

@When[os == "Linux"]
public const IORING_OP_RECVMSG: UInt8 = 10

@When[os == "Linux"]
public const IORING_OP_TIMEOUT: UInt8 = 11

@When[os == "Linux"]
public const IORING_OP_TIMEOUT_REMOVE: UInt8 = 12

@When[os == "Linux"]
public const IORING_OP_ACCEPT: UInt8 = 13

@When[os == "Linux"]
public const IORING_OP_ASYNC_CANCEL: UInt8 = 14

@When[os == "Linux"]
public const IORING_OP_LINK_TIMEOUT: UInt8 = 15

@When[os == "Linux"]
public const IORING_OP_CONNECT: UInt8 = 16

@When[os == "Linux"]
public const IORING_OP_FALLOCATE: UInt8 = 17

@When[os == "Linux"]
public const IORING_OP_OPENAT: UInt8 = 18

@When[os == "Linux"]
public const IORING_OP_CLOSE: UInt8 = 19

@When[os == "Linux"]
public const IORING_OP_FILES_UPDATE: UInt8 = 20

@When[os == "Linux"]
public const IORING_OP_STATX: UInt8 = 21

@When[os == "Linux"]
public const IORING_OP_READ: UInt8 = 22

@When[os == "Linux"]
public const IORING_OP_WRITE: UInt8 = 23

@When[os == "Linux"]
public const IORING_OP_FADVISE: UInt8 = 24

@When[os == "Linux"]
public const IORING_OP_MADVISE: UInt8 = 25

@When[os == "Linux"]
public const IORING_OP_SEND: UInt8 = 26

@When[os == "Linux"]
public const IORING_OP_RECV: UInt8 = 27

@When[os == "Linux"]
public const IORING_OP_OPENAT2: UInt8 = 28

@When[os == "Linux"]
public const IORING_OP_EPOLL_CTL: UInt8 = 29

@When[os == "Linux"]
public const IORING_OP_SPLICE: UInt8 = 30

@When[os == "Linux"]
public const IORING_OP_PROVIDE_BUFFERS: UInt8 = 31

@When[os == "Linux"]
public const IORING_OP_REMOVE_BUFFERS: UInt8 = 32

@When[os == "Linux"]
public const IORING_OP_TEE: UInt8 = 33

@When[os == "Linux"]
public const IORING_OP_SHUTDOWN: UInt8 = 34

@When[os == "Linux"]
public const IORING_OP_RENAMEAT: UInt8 = 35

@When[os == "Linux"]
public const IORING_OP_UNLINKAT: UInt8 = 36

@When[os == "Linux"]
public const IORING_OP_MKDIRAT: UInt8 = 37

@When[os == "Linux"]
public const IORING_OP_SYMLINKAT: UInt8 = 38

@When[os == "Linux"]
public const IORING_OP_LINKAT: UInt8 = 39

@When[os == "Linux"]
public const IORING_OP_MSG_RING: UInt8 = 40

@When[os == "Linux"]
public const IORING_OP_FSETXATTR: UInt8 = 41

@When[os == "Linux"]
public const IORING_OP_SETXATTR: UInt8 = 42

@When[os == "Linux"]
public const IORING_OP_FGETXATTR: UInt8 = 43

@When[os == "Linux"]
public const IORING_OP_GETXATTR: UInt8 = 44

@When[os == "Linux"]
public const IORING_OP_SOCKET: UInt8 = 45

@When[os == "Linux"]
public const IORING_OP_URING_CMD: UInt8 = 46

@When[os == "Linux"]
public const IORING_OP_SEND_ZC: UInt8 = 47

@When[os == "Linux"]
public const IORING_OP_SENDMSG_ZC: UInt8 = 48

// ==================== io_uring_params features (IORING_FEAT_*) ====================

@When[os == "Linux"]
public const IORING_FEAT_SINGLE_MMAP: UInt32 = 0x00000001

@When[os == "Linux"]
public const IORING_FEAT_NODROP: UInt32 = 0x00000002

@When[os == "Linux"]
public const IORING_FEAT_SUBMIT_STABLE: UInt32 = 0x00000004

@When[os == "Linux"]
public const IORING_FEAT_RW_CUR_POS: UInt32 = 0x00000008

@When[os == "Linux"]
public const IORING_FEAT_CUR_PERSONALITY: UInt32 = 0x00000010

@When[os == "Linux"]
public const IORING_FEAT_FAST_POLL: UInt32 = 0x00000020

@When[os == "Linux"]
public const IORING_FEAT_POLL_32BITS: UInt32 = 0x00000040

@When[os == "Linux"]
public const IORING_FEAT_SQPOLL_NONFIXED: UInt32 = 0x00000080

@When[os == "Linux"]
public const IORING_FEAT_EXT_ARG: UInt32 = 0x00000100

@When[os == "Linux"]
public const IORING_FEAT_NATIVE_WORKERS: UInt32 = 0x00000200

@When[os == "Linux"]
public const IORING_FEAT_RSRC_TAGS: UInt32 = 0x00000400

@When[os == "Linux"]
public const IORING_FEAT_CQE_SKIP: UInt32 = 0x00000800

@When[os == "Linux"]
public const IORING_FEAT_LINKED_FILE: UInt32 = 0x00001000

@When[os == "Linux"]
public const IORING_FEAT_REG_REG_RING: UInt32 = 0x00002000

// ==================== fsync flags ====================

@When[os == "Linux"]
public const IORING_FSYNC_DATASYNC: UInt32 = 0x00000001

// ==================== timeout flags ====================

@When[os == "Linux"]
public const IORING_TIMEOUT_ABS: UInt32 = 0x00000001

@When[os == "Linux"]
public const IORING_TIMEOUT_UPDATE: UInt32 = 0x00000002

@When[os == "Linux"]
public const IORING_TIMEOUT_BOOTTIME: UInt32 = 0x00000004

@When[os == "Linux"]
public const IORING_TIMEOUT_REALTIME: UInt32 = 0x00000008

@When[os == "Linux"]
public const IORING_LINK_TIMEOUT_UPDATE: UInt32 = 0x00000010

@When[os == "Linux"]
public const IORING_TIMEOUT_ETIME_SUCCESS: UInt32 = 0x00000020

@When[os == "Linux"]
public const IORING_TIMEOUT_MULTISHOT: UInt32 = 0x00000040

// ==================== splice flags ====================

/** the last bit of __u32 */
@When[os == "Linux"]
public const SPLICE_F_FD_IN_FIXED: UInt32 = 0x80000000

// ==================== poll flags ====================

@When[os == "Linux"]
public const IORING_POLL_ADD_MULTI: UInt32 = 0x00000001

@When[os == "Linux"]
public const IORING_POLL_UPDATE_EVENTS: UInt32 = 0x00000002

@When[os == "Linux"]
public const IORING_POLL_UPDATE_USER_DATA: UInt32 = 0x00000004

@When[os == "Linux"]
public const IORING_POLL_ADD_LEVEL: UInt32 = 0x00000008

// ==================== async cancel flags ====================

/** cancel all requests that match */
@When[os == "Linux"]
public const IORING_ASYNC_CANCEL_ALL: UInt32 = 0x00000001

/** key off 'fd' for cancelation */
@When[os == "Linux"]
public const IORING_ASYNC_CANCEL_FD: UInt32 = 0x00000002

/** match any request */
@When[os == "Linux"]
public const IORING_ASYNC_CANCEL_ANY: UInt32 = 0x00000004

/** 'fd' is a fixed descriptor */
@When[os == "Linux"]
public const IORING_ASYNC_CANCEL_FD_FIXED: UInt32 = 0x00000008

// ==================== recv/send flags ====================

@When[os == "Linux"]
public const IORING_RECVSEND_POLL_FIRST: UInt32 = 0x00000001

@When[os == "Linux"]
public const IORING_RECV_MULTISHOT: UInt32 = 0x00000002

@When[os == "Linux"]
public const IORING_RECVSEND_FIXED_BUF: UInt32 = 0x00000004

@When[os == "Linux"]
public const IORING_SEND_ZC_REPORT_USAGE: UInt32 = 0x00000008

// ==================== accept flags ====================

@When[os == "Linux"]
public const IORING_ACCEPT_MULTISHOT: UInt32 = 0x00000001

// ==================== msg_ring flags ====================

@When[os == "Linux"]
public const IORING_MSG_RING_CQE_SKIP: UInt32 = 0x00000001

@When[os == "Linux"]
public const IORING_MSG_RING_FLAGS_PASS: UInt32 = 0x00000002

// ==================== register opcodes ====================

@When[os == "Linux"]
public const IORING_REGISTER_BUFFERS: UInt32 = 0

@When[os == "Linux"]
public const IORING_UNREGISTER_BUFFERS: UInt32 = 1

@When[os == "Linux"]
public const IORING_REGISTER_FILES: UInt32 = 2

@When[os == "Linux"]
public const IORING_UNREGISTER_FILES: UInt32 = 3

@When[os == "Linux"]
public const IORING_REGISTER_EVENTFD: UInt32 = 4

@When[os == "Linux"]
public const IORING_UNREGISTER_EVENTFD: UInt32 = 5

@When[os == "Linux"]
public const IORING_REGISTER_FILES_UPDATE: UInt32 = 6

@When[os == "Linux"]
public const IORING_REGISTER_EVENTFD_ASYNC: UInt32 = 7

@When[os == "Linux"]
public const IORING_REGISTER_PROBE: UInt32 = 8

@When[os == "Linux"]
public const IORING_REGISTER_PERSONALITY: UInt32 = 9

@When[os == "Linux"]
public const IORING_UNREGISTER_PERSONALITY: UInt32 = 10

@When[os == "Linux"]
public const IORING_REGISTER_RESTRICTIONS: UInt32 = 11

@When[os == "Linux"]
public const IORING_REGISTER_ENABLE_RINGS: UInt32 = 12

@When[os == "Linux"]
public const IORING_REGISTER_FILES2: UInt32 = 13

@When[os == "Linux"]
public const IORING_REGISTER_FILES_UPDATE2: UInt32 = 14

@When[os == "Linux"]
public const IORING_REGISTER_BUFFERS2: UInt32 = 15

@When[os == "Linux"]
public const IORING_REGISTER_BUFFERS_UPDATE: UInt32 = 16

@When[os == "Linux"]
public const IORING_REGISTER_IOWQ_AFF: UInt32 = 17

@When[os == "Linux"]
public const IORING_UNREGISTER_IOWQ_AFF: UInt32 = 18

@When[os == "Linux"]
public const IORING_REGISTER_IOWQ_MAX_WORKERS: UInt32 = 19

@When[os == "Linux"]
public const IORING_REGISTER_RING_FDS: UInt32 = 20

@When[os == "Linux"]
public const IORING_UNREGISTER_RING_FDS: UInt32 = 21

@When[os == "Linux"]
public const IORING_REGISTER_PBUF_RING: UInt32 = 22

@When[os == "Linux"]
public const IORING_UNREGISTER_PBUF_RING: UInt32 = 23

@When[os == "Linux"]
public const IORING_REGISTER_SYNC_CANCEL: UInt32 = 24

@When[os == "Linux"]
public const IORING_REGISTER_FILE_ALLOC_RANGE: UInt32 = 25

/** flag to use registered ring fd */
@When[os == "Linux"]
public const IORING_REGISTER_USE_REGISTERED_RING: UInt32 = 0x80000000

// ==================== resource flags ====================

@When[os == "Linux"]
public const IORING_RSRC_REGISTER_SPARSE: UInt32 = 0x00000001

@When[os == "Linux"]
public const IORING_REGISTER_FILES_SKIP: Int32 = -2

@When[os == "Linux"]
public const IO_URING_OP_SUPPORTED: UInt16 = 0x0001

// ==================== buffer ring flags ====================

@When[os == "Linux"]
public const IOU_PBUF_RING_MMAP: UInt32 = 0x00000001

/** incremental buffer consumption (kernel 6.12+) */
@When[os == "Linux"]
public const IOU_PBUF_RING_INC: UInt32 = 0x00000002

// ==================== magic constants ====================

/** auto-allocate direct descriptor */
@When[os == "Linux"]
public const IORING_FILE_INDEX_ALLOC: UInt32 = 0xFFFFFFFF

/** magic value for timeout user_data */
@When[os == "Linux"]
public const LIBURING_UDATA_TIMEOUT: UInt64 = 0xFFFFFFFFFFFFFFFF

/** notif usage: zerocopy copied */
@When[os == "Linux"]
public const IORING_NOTIF_USAGE_ZC_COPIED: UInt32 = 0x80000000
