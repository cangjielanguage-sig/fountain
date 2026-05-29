package fountain::f_hydra

import std.ffi.{CPointer, CString}
import fountain.f_hydra.ffi.faiss_types.FaissIndex

// Faiss v1.9.0 C API foreign function declarations.

// Index creation

@C foreign
func faiss_IndexHNSWFlat_new(dim: UInt64, M: Int64): CPointer<FaissIndex>

@C foreign
func faiss_IndexFlatL2_new(dim: UInt64): CPointer<FaissIndex>

// Index operations

@C foreign
func faiss_Index_add(idx: CPointer<FaissIndex>, n: Int64, x: CPointer<Float32>): Int32

@C foreign
func faiss_Index_search(
    idx: CPointer<FaissIndex>,
    n: Int64,
    x: CPointer<Float32>,
    k: Int64,
    distances: CPointer<Float32>,
    labels: CPointer<Int64>
): Int32

@C foreign
func faiss_Index_train(idx: CPointer<FaissIndex>, n: Int64, x: CPointer<Float32>): Int32

// Persistence

@C foreign
func faiss_write_index_fname(idx: CPointer<FaissIndex>, path: CString): Int32

@C foreign
func faiss_read_index_fname(path: CString, p_out: CPointer<CPointer<FaissIndex>>): Int32

// Lifecycle

@C foreign
func faiss_Index_free(idx: CPointer<FaissIndex>): ()
