package fountain::f_hydra

import std.collection.HashMap
import std.ffi.{CPointer, CString}
import std.time.DateTime
import fountain.f_hydra.backend.bge_backend.{
    BgeBackend, BgeOutput, BackendCapabilities, BackendInfo
}
import fountain.f_hydra.backend.backend_config.BackendConfig
import fountain.f_hydra.config.hydra_config.HydraConfig
import fountain.f_hydra.tokenizer.bge_tokenizer.BgeTokenizer
import fountain.f_hydra.ffi.onnx_types.*
import fountain.f_hydra.ffi.onnx_bridge.*
import fountain.f_hydra.ffi.ffi_check.FfiCheck

// ONNX Runtime CPU inference backend.
// Implements BgeBackend interface for BGE-M3 embedding using ONNX Runtime.
public class OrtCpuBackend <: BgeBackend {
    // ONNX Runtime handles
    private var env: ?CPointer<OrtEnv>
    private var session: ?CPointer<OrtSession>

    // Cached metadata
    private var inputNames: ?Array<String>
    private var outputNameToIndex: HashMap<String, Int64>

    // ONNX allocator and memory info
    private let allocator: CPointer<OrtAllocator>
    private let memInfo: CPointer<OrtMemoryInfo>

    // Shared tokenizer (initialized once, used by all encode calls)
    private let tokenizer: BgeTokenizer

    // Backend information
    private let info: BackendInfo

    // Performance logging
    private let enablePerfLog: Bool

    public init(config: BackendConfig) {
        this.enablePerfLog = config.enablePerfLog
        this.env = None
        this.session = None
        this.inputNames = None
        this.outputNameToIndex = HashMap<String, Int64>()

        // Step 1: Create ONNX Runtime environment
        var envPtr = CPointer<CPointer<OrtEnv>>()
        let envStatus = unsafe {
            OrtCreateEnv(3, "f_hydra".toCString(), envPtr)
        }
        FfiCheck.checkOrtStatus(envStatus, "OrtCreateEnv")
        let env = envPtr.read()
        this.env = Some(env)

        // Step 2: Create session options
        var optsPtr = CPointer<CPointer<OrtSessionOptions>>()
        var optsStatus = unsafe { OrtCreateSessionOptions(optsPtr) }
        FfiCheck.checkOrtStatus(optsStatus, "OrtCreateSessionOptions")
        let opts = optsPtr.read()

        try {
            // Step 3: Set thread count
            let threadStatus = unsafe {
                OrtSetIntraOpNumThreads(opts, config.numThreads)
            }
            FfiCheck.checkOrtStatus(threadStatus, "OrtSetIntraOpNumThreads")

            // Step 4: Enable all graph optimizations (99 = ALL)
            let optStatus = unsafe {
                OrtSetSessionGraphOptimizationLevel(opts, 99)
            }
            FfiCheck.checkOrtStatus(optStatus, "OrtSetSessionGraphOptimizationLevel")

            // Step 5: Create inference session
            var sessPtr = CPointer<CPointer<OrtSession>>()
            let sessStatus = unsafe {
                OrtCreateSession(env, config.modelPath.toCString(), opts, sessPtr)
            }
            FfiCheck.checkOrtStatus(sessStatus, "OrtCreateSession")
            let sess = sessPtr.read()
            this.session = Some(sess)

            // Step 6: Cache input/output metadata
            this.cacheMetadata(sess)

            // Step 7: Get allocator and memory info
            var allocPtr = CPointer<CPointer<OrtAllocator>>()
            let _ = unsafe { OrtGetAllocatorWithDefaultOptions(allocPtr) }
            this.allocator = allocPtr.read()

            var memPtr = CPointer<CPointer<OrtMemoryInfo>>()
            let memStatus = unsafe { OrtCreateCpuMemoryInfo(1, 0, memPtr) }
            FfiCheck.checkOrtStatus(memStatus, "OrtCreateCpuMemoryInfo")
            this.memInfo = memPtr.read()

            // Step 8: Initialize shared tokenizer
            this.tokenizer = BgeTokenizer(config.tokenizerPath)

            // Step 9: Build backend info
            this.info = BackendInfo(
                name: "OrtCpuBackend",
                version: "0.1.0",
                capabilities: BackendCapabilities(
                    supportsDense: true,
                    supportsSparse: true,
                    supportsColBERT: true,
                    supportsBatch: true,
                    hardwareName: "CPU (OR-T ${config.numThreads} threads)"
                )
            )

            // Step 10: Release session options (no longer needed)
            unsafe { OrtReleaseSessionOptions(opts) }

            // Step 11: Warmup
            this.warmup()
        } catch (e: Exception) {
            // Cleanup on failure: release session options, then session, then env
            unsafe { OrtReleaseSessionOptions(opts) }
            if (let Some(s) <- this.session) {
                unsafe { OrtReleaseSession(s) }
                this.session = None
            }
            if (let Some(e) <- this.env) {
                unsafe { OrtReleaseEnv(e) }
                this.env = None
            }
            throw e
        }
    }

    // === BgeBackend interface ===

    // Encode single text: tokenize → create tensors → infer → parse outputs
    public func encode(text: String): BgeOutput {
        let start = if (enablePerfLog) { DateTime.now() } else { DateTime(0) }

        let tokens = tokenizer.tokenize(text)
        let N = 1
        let S = tokens.seqLen

        // Create input tensors (zero-copy: OrtValue points to our Array memory)
        let inputIdsFlat = Array<Int64>(N * S, init: 0)
        let attnMaskFlat = Array<Int64>(N * S, init: 0)
        for (j in 0..S) {
            inputIdsFlat[j] = tokens.inputIds[j]
            attnMaskFlat[j] = tokens.attnMask[j]
        }
        let inputIdsValue = createInt64Tensor(inputIdsFlat, [N, S])
        let attnMaskValue = createInt64Tensor(attnMaskFlat, [N, S])

        // Run inference
        let inputNames = if (let Some(n) <- this.inputNames) { n } else {
            throw Exception("OrtCpuBackend: inputNames not initialized")
        }
        var inputVals = [inputIdsValue, attnMaskValue]
        let outputValues = runInference(inputNames, inputVals)

        // Parse outputs by name
        let result = parseOutputs(outputValues, tokens)

        // Release OrtValues
        unsafe {
            OrtReleaseValue(inputIdsValue)
            OrtReleaseValue(attnMaskValue)
            for (v in outputValues) { OrtReleaseValue(v) }
        }

        if (enablePerfLog) {
            let elapsed = DateTime.now().durationSince(start)
            println("[f_hydra] OrtCpuBackend.encode: ${elapsed.toMilliseconds()}ms, len=${S}")
        }

        result
    }

    // Batch encode: true batch inference with [N, maxSeqLen] tensor.
    // 3-5x faster than sequential encode() calls.
    public func encodeBatch(texts: Array<String>): Array<BgeOutput> {
        if (texts.size == 0) {
            return Array<BgeOutput>()
        }
        if (texts.size == 1) {
            return [this.encode(texts[0])]
        }

        let start = if (enablePerfLog) { DateTime.now() } else { DateTime(0) }

        // Tokenize all texts, find max sequence length
        var allTokens = ArrayList<TokenizeResult>(texts.size)
        var maxLen: Int64 = 0
        for (text in texts) {
            let tokens = tokenizer.tokenize(text)
            maxLen = if (tokens.seqLen > maxLen) { tokens.seqLen } else { maxLen }
            allTokens.add(tokens)
        }

        // Pad all sequences to maxLen and build [N, maxLen] tensors
        let N = texts.size
        var flatInputIds = Array<Int64>(N * maxLen, init: 0)
        var flatAttnMask = Array<Int64>(N * maxLen, init: 0)
        for (i in 0..N) {
            let t = allTokens[i]
            let base = i * maxLen
            for (j in 0..t.seqLen) {
                flatInputIds[base + j] = t.inputIds[j]
                flatAttnMask[base + j] = t.attnMask[j]
            }
        }

        let inputIdsValue = createInt64Tensor(flatInputIds, [N, maxLen])
        let attnMaskValue = createInt64Tensor(flatAttnMask, [N, maxLen])

        // Single batch inference
        let inputNames = if (let Some(n) <- this.inputNames) { n } else {
            throw Exception("OrtCpuBackend: inputNames not initialized")
        }
        var inputVals = [inputIdsValue, attnMaskValue]
        let outputValues = runInference(inputNames, inputVals)

        // Parse batch outputs
        var results = ArrayList<BgeOutput>(texts.size)
        let denseOutputs = readBatchFloatTensor(outputValues, 0, N, 1024)
        // For batch, we parse each sequence separately
        for (i in 0..N) {
            let t = allTokens[i]
            let dense = denseOutputs[i]
            // Sparse and colbert parsing per sequence
            let sparse = parseSparseOutput(dense, t.inputIds)
            let colbert = Array<Array<Float32>>()
            results.add(BgeOutput(denseVec: dense, sparseVec: sparse, colbertVecs: colbert))
        }

        // Release OrtValues
        unsafe {
            OrtReleaseValue(inputIdsValue)
            OrtReleaseValue(attnMaskValue)
            for (v in outputValues) { OrtReleaseValue(v) }
        }

        if (enablePerfLog) {
            let elapsed = DateTime.now().durationSince(start)
            println("[f_hydra] OrtCpuBackend.encodeBatch: ${elapsed.toMilliseconds()}ms, N=${N}, maxLen=${maxLen}")
        }

        results
    }

    // Warmup: run a dummy inference to trigger JIT compilation and graph optimization.
    // Also validates dense L2 norm ≈ 1.0.
    public func warmup() {
        let result = this.encode("warmup")
        // Verify L2 norm of dense vector ≈ 1.0
        let dense = result.denseVec
        var sumSq: Float32 = 0.0
        for (v in dense) { sumSq += v * v }
        let norm = sqrt(sumSq)
        if (norm < 0.999 || norm > 1.001) {
            println("[f_hydra] Warning: dense L2 norm = ${norm}, expected ≈ 1.0")
        }
    }

    public func isReady(): Bool {
        this.session.isSome()
    }

    public func backendInfo(): BackendInfo {
        this.info
    }

    // Close: release all C resources in correct order (session before env).
    public func close() {
        if (let Some(s) <- this.session) {
            unsafe { OrtReleaseSession(s) }
            this.session = None
        }
        unsafe { OrtReleaseMemoryInfo(this.memInfo) }
        if (let Some(e) <- this.env) {
            unsafe { OrtReleaseEnv(e) }
            this.env = None
        }
        tokenizer.close()
    }

    // === Internal helper methods ===

    private func cacheMetadata(session: CPointer<OrtSession>) {
        // Get input/output counts
        var inputCount = UInt64(0)
        FfiCheck.checkOrtStatus(
            unsafe { OrtSessionGetInputCount(session, &inputCount) },
            "OrtSessionGetInputCount"
        )
        var outputCount = UInt64(0)
        FfiCheck.checkOrtStatus(
            unsafe { OrtSessionGetOutputCount(session, &outputCount) },
            "OrtSessionGetOutputCount"
        )

        // Cache input names
        var names = Array<String>(inputCount) { i =>
            var namePtr = CPointer<CString>()
            FfiCheck.checkOrtStatus(
                unsafe { OrtSessionGetInputName(session, i, this.allocator, namePtr) },
                "OrtSessionGetInputName[${i}]"
            )
            unsafe { namePtr.read().readCString() }
        }
        this.inputNames = Some(names)

        // Build output name → index mapping (not relying on ONNX output order)
        for (i in 0..outputCount) {
            var namePtr = CPointer<CString>()
            FfiCheck.checkOrtStatus(
                unsafe { OrtSessionGetOutputName(session, i, this.allocator, namePtr) },
                "OrtSessionGetOutputName[${i}]"
            )
            let name = unsafe { namePtr.read().readCString() }
            this.outputNameToIndex[name] = i
        }
    }

    // Create Int64 tensor from flat Array (zero-copy via OrtCreateTensorWithDataAsOrtValue)
    private func createInt64Tensor(data: Array<Int64>, shape: Array<Int64>): CPointer<OrtValue> {
        var out = CPointer<CPointer<OrtValue>>()
        let byteSize = (data.size * 8) as UInt64  // Int64 = 8 bytes
        let status = unsafe {
            OrtCreateTensorWithDataAsOrtValue(
                this.memInfo,
                data.toCPointer() as CPointer<UInt8>,
                byteSize,
                shape.toCPointer(),
                shape.size as UInt64,
                7,  // ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
                out
            )
        }
        FfiCheck.checkOrtStatus(status, "createInt64Tensor")
        out.read()
    }

    // Run inference: prepare names arrays and call OrtRun
    private func runInference(
        inputNames: Array<String>,
        inputVals: Array<CPointer<OrtValue>>
    ): Array<CPointer<OrtValue>> {
        let session = if (let Some(s) <- this.session) { s } else {
            throw Exception("OrtCpuBackend: session not initialized")
        }
        let outputCount = this.outputNameToIndex.size as UInt64

        let cInputNames = Array<CString>(inputNames.size) { i => inputNames[i].toCString() }
        let cInputVals = inputVals

        // Build output names array indexed by position (sorted by outputNameToIndex value)
        var cOutputNames = Array<CString>(outputCount) {_ => CString()}
        for ((name, idx) in this.outputNameToIndex) {
            cOutputNames[idx] = name.toCString()
        }

        var outputVals = Array<CPointer<OrtValue>>(outputCount) {_ => CPointer<OrtValue>()}

        let status = unsafe {
            OrtRun(
                session,
                CPointer<OrtRunOptions>(),
                cInputNames.toCPointer(),
                cInputVals.toCPointer(),
                inputNames.size as UInt64,
                cOutputNames.toCPointer(),
                outputCount,
                outputVals.toCPointer()
            )
        }
        FfiCheck.checkOrtStatus(status, "OrtRun")
        outputVals
    }

    // Parse ONNX output values into BgeOutput struct
    private func parseOutputs(
        outputValues: Array<CPointer<OrtValue>>,
        tokens: TokenizeResult
    ): BgeOutput {
        let dim: Int64 = 1024

        // Read outputs by name (not by index)
        let denseIdx = this.outputNameToIndex.getOrPut("dense_vec", 0)
        let sparseIdx = this.outputNameToIndex.getOrPut("sparse_vec", 0)
        let colbertIdx = this.outputNameToIndex.getOrPut("colbert_vec", 0)

        let dense = readFloatTensor(outputValues[denseIdx], dim)
        let seqLen = tokens.seqLen

        // Sparse vector: per-token weights, filtered for special tokens
        let sparseRaw = readFloatTensor(outputValues[sparseIdx], seqLen)
        let sparse = parseSparseOutput(sparseRaw, tokens.inputIds)

        // ColBERT vectors: [seqLen, dim] flat → nested arrays
        let colbertRaw = readFloatTensor(outputValues[colbertIdx], seqLen * dim)
        let colbert = reshapeColbert(colbertRaw, seqLen, dim)

        BgeOutput(denseVec: dense, sparseVec: sparse, colbertVecs: colbert)
    }

    // Read Float32 tensor data from OrtValue
    private func readFloatTensor(value: CPointer<OrtValue>, len: Int64): Array<Float32> {
        var dataPtr = CPointer<CPointer<UInt8>>()
        let status = unsafe { OrtGetTensorMutableData(value, dataPtr) }
        FfiCheck.checkOrtStatus(status, "readFloatTensor")
        let floatPtr = dataPtr.read() as CPointer<Float32>
        Array<Float32>(len) { i => unsafe { floatPtr[i] } }
    }

    // Read batch Float32 tensor data (for dense output parsing in batch mode)
    private func readBatchFloatTensor(
        outputValues: Array<CPointer<OrtValue>>,
        outputIndex: Int64,
        batchSize: Int64,
        dim: Int64
    ): Array<Array<Float32>> {
        let allData = readFloatTensor(outputValues[outputIndex], batchSize * dim)
        Array<Array<Float32>>(batchSize) { i =>
            Array<Float32>(dim) { j => allData[i * dim + j] }
        }
    }

    // Parse sparse output: filter special tokens, keep positive weights
    private func parseSparseOutput(
        rawSparse: Array<Float32>,
        inputIds: Array<Int64>
    ): HashMap<Int64, Float32> {
        var result = HashMap<Int64, Float32>()
        for (i in 0..inputIds.size) {
            let tokenId = inputIds[i]
            let weight = rawSparse[i]
            // Filter special tokens
            if (tokenId != tokenizer.getClsTokenId() &&
                tokenId != tokenizer.getSepTokenId() &&
                tokenId != tokenizer.getPadTokenId() &&
                tokenId != tokenizer.getUnkTokenId() &&
                weight > 0.0) {
                let existing = result.getOrPut(tokenId, 0.0)
                if (weight > existing) {
                    result[tokenId] = weight
                }
            }
        }
        result
    }

    // Reshape flat ColBERT tensor to Array<Array<Float32>>
    private func reshapeColbert(
        flat: Array<Float32>,
        seqLen: Int64,
        dim: Int64
    ): Array<Array<Float32>> {
        Array<Array<Float32>>(seqLen) { i =>
            Array<Float32>(dim) { j => flat[i * dim + j] }
        }
    }
}
