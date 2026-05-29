package fountain::f_hydra

import fountain.f_hydra.backend.bge_backend.BgeBackend
import fountain.f_hydra.backend.backend_config.BackendConfig
import fountain.f_hydra.config.hydra_config.HydraConfig

// Factory function: creates BgeBackend instance based on environment config.
// v1 only supports ORT_CPU; unknown types gracefully fallback to CPU.

public func createBgeBackend(): BgeBackend {
    let backendType = HydraConfig.backendType()
    let modelPath = HydraConfig.modelPath()
    let tokenizerPath = HydraConfig.tokenizerPath()
    let numThreads = HydraConfig.numThreads()
    let enablePerfLog = HydraConfig.enablePerfLog()
    let onnxLibPath = HydraConfig.libPath()

    let config = BackendConfig(
        tokenizerPath: tokenizerPath,
        modelPath: modelPath,
        numThreads: numThreads,
        enablePerfLog: enablePerfLog,
        onnxLibPath: onnxLibPath
    )

    match (backendType) {
        case "ort_cpu" => OrtCpuBackend(config)
        case _ => OrtCpuBackend(config)
    }
}
