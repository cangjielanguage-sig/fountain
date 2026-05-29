package fountain::f_hydra

import std.ffi.{CPointer, CString, Ptr}
import fountain.f_hydra.ffi.onnx_types.*

// ONNX Runtime C API v1.17+ foreign function declarations.

// === Environment management ===

@C foreign
func OrtCreateEnv(level: Int64, name: CString, out: CPointer<CPointer<OrtEnv>>): CPointer<OrtStatus>

@C foreign
func OrtReleaseEnv(env: CPointer<OrtEnv>): ()

// === Session options ===

@C foreign
func OrtCreateSessionOptions(out: CPointer<CPointer<OrtSessionOptions>>): CPointer<OrtStatus>

@C foreign
func OrtReleaseSessionOptions(options: CPointer<OrtSessionOptions>): ()

@C foreign
func OrtSetIntraOpNumThreads(options: CPointer<OrtSessionOptions>, numThreads: Int64): CPointer<OrtStatus>

@C foreign
func OrtSetSessionGraphOptimizationLevel(options: CPointer<OrtSessionOptions>, level: Int64): CPointer<OrtStatus>

// === Session creation ===

@C foreign
func OrtCreateSession(env: CPointer<OrtEnv>, modelPath: CString, options: CPointer<OrtSessionOptions>, out: CPointer<CPointer<OrtSession>>): CPointer<OrtStatus>

@C foreign
func OrtReleaseSession(session: CPointer<OrtSession>): ()

// === Input/output metadata ===

@C foreign
func OrtSessionGetInputCount(session: CPointer<OrtSession>, out: CPointer<UInt64>): CPointer<OrtStatus>

@C foreign
func OrtSessionGetOutputCount(session: CPointer<OrtSession>, out: CPointer<UInt64>): CPointer<OrtStatus>

@C foreign
func OrtSessionGetInputName(session: CPointer<OrtSession>, index: UInt64, allocator: CPointer<OrtAllocator>, out: CPointer<CString>): CPointer<OrtStatus>

@C foreign
func OrtSessionGetOutputName(session: CPointer<OrtSession>, index: UInt64, allocator: CPointer<OrtAllocator>, out: CPointer<CString>): CPointer<OrtStatus>

// === Allocator ===

@C foreign
func OrtGetAllocatorWithDefaultOptions(out: CPointer<CPointer<OrtAllocator>>): CPointer<OrtStatus>

// === Memory info ===

@C foreign
func OrtCreateCpuMemoryInfo(memType: Int64, memUsage: Int64, out: CPointer<CPointer<OrtMemoryInfo>>): CPointer<OrtStatus>

@C foreign
func OrtReleaseMemoryInfo(memInfo: CPointer<OrtMemoryInfo>): ()

// === Tensor creation (zero-copy) ===

@C foreign
func OrtCreateTensorWithDataAsOrtValue(
    memInfo: CPointer<OrtMemoryInfo>,
    data: CPointer<UInt8>,
    dataSize: UInt64,
    shape: CPointer<Int64>,
    rank: UInt64,
    elementType: Int64,
    out: CPointer<CPointer<OrtValue>>
): CPointer<OrtStatus>

// === Inference ===

@C foreign
func OrtRun(
    session: CPointer<OrtSession>,
    runOptions: CPointer<OrtRunOptions>,
    inputNames: CPointer<CString>,
    inputs: CPointer<CPointer<OrtValue>>,
    inputCount: UInt64,
    outputNames: CPointer<CString>,
    outputCount: UInt64,
    outputs: CPointer<CPointer<OrtValue>>
): CPointer<OrtStatus>

// === Tensor data access ===

@C foreign
func OrtGetTensorMutableData(value: CPointer<OrtValue>, out: CPointer<CPointer<UInt8>>): CPointer<OrtStatus>

// === Value lifecycle ===

@C foreign
func OrtReleaseValue(value: CPointer<OrtValue>): ()

// === Error handling ===

@C foreign
func OrtGetErrorMessage(status: CPointer<OrtStatus>): CString

@C foreign
func OrtReleaseStatus(status: CPointer<OrtStatus>): ()
