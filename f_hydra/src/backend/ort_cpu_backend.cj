package fountain::f_hydra

import std.collection.HashMap
import fountain.f_hydra.backend.bge_backend.{
    BgeBackend, BgeOutput, BackendCapabilities, BackendInfo
}
import fountain.f_hydra.backend.backend_config.BackendConfig

// Placeholder stub for OrtCpuBackend.
// Full implementation will be built in Phase 3.
public class OrtCpuBackend <: BgeBackend {
    private let config: BackendConfig
    private var ready: Bool

    public init(config: BackendConfig) {
        this.config = config
        this.ready = false
    }

    public func encode(text: String): BgeOutput {
        throw Exception("OrtCpuBackend not implemented (Phase 3)")
    }

    public func encodeBatch(texts: Array<String>): Array<BgeOutput> {
        throw Exception("OrtCpuBackend.encodeBatch not implemented (Phase 3)")
    }

    public func warmup() {
        this.ready = true
    }

    public func isReady(): Bool {
        this.ready
    }

    public func backendInfo(): BackendInfo {
        BackendInfo(
            name: "OrtCpuBackend",
            version: "0.1.0",
            capabilities: BackendCapabilities(
                supportsDense: true,
                supportsSparse: true,
                supportsColBERT: true,
                supportsBatch: true,
                hardwareName: "CPU (stub)"
            )
        )
    }

    public func close() {
        this.ready = false
    }
}
