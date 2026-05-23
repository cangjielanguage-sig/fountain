package fountain::f_hydra

import std.ffi.CPointer
import fountain.f_hydra.ffi.onnx_types.{
    OrtStatus
}
import fountain.f_hydra.ffi.onnx_bridge.*
import fountain.f_hydra.ffi.faiss_bridge.*

// Unified FFI error checking framework
// Every FFI call must go through one of these three check functions.

public class FfiCheck {

    // Check ONNX Runtime OrtStatus return value.
    // null = success (no-op).
    // non-null = read error message, release status, throw Exception.
    public static func checkOrtStatus(status: CPointer<OrtStatus>, context: String) {
        if (status.isNull()) {
            return
        }
        unsafe {
            let msgPtr = OrtGetErrorMessage(status)
            let desc = msgPtr.readCString()
            OrtReleaseStatus(status)
            throw Exception("FfiError: ${context}: ${desc}")
        }
    }

    // Check Faiss API return value.
    // >= 0 = success (no-op).
    // < 0 = throw Exception with error code and context.
    public static func checkFaissReturn(ret: Int32, context: String) {
        if (ret >= 0) {
            return
        }
        throw Exception("FfiError: ${context}: Faiss returned error code ${ret}")
    }

    // Check CPointer is non-null.
    // null = throw Exception with context.
    // non-null = return the pointer (for chaining).
    public static func checkNotNull<T>(ptr: CPointer<T>, context: String): CPointer<T> {
        if (ptr.isNull()) {
            throw Exception("FfiError: ${context}: unexpected null pointer")
        }
        ptr
    }
}
