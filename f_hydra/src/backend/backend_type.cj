package fountain::f_hydra

public enum BackendType {
    | ORT_CPU
    | ORT_CUDA
    | ORT_ROCM
    | ORT_OPENVINO
    | ORT_TENSORRT
    | MINDSPORE_LITE
    | COREML
    | HTTP_TEI
    | HTTP_VLLM
}
