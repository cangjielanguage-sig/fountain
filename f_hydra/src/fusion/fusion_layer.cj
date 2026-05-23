package fountain::f_hydra

import std.collection.HashMap
import std.collection.ArrayList
import fountain.f_hydra.fusion.scored_document.ScoredDocument

// Fusion layer: combines results from dense, sparse, and ColBERT retrievers.
// Supports RRF (default) and weighted fusion strategies.

public class FusionLayer {

    public init() {}

    // Fuse three result sets and return top-k ScoredDocuments.
    // strategy: "rrf" (default) or "weighted"
    // weights: optional [α, β, γ] for weighted fusion
    public func fuse(
        sparse: Array<ScoredDocument>,
        dense: Array<ScoredDocument>,
        colbert: Array<ScoredDocument>,
        strategy: String,
        weights: ?Array<Float64>,
        topK: Int64
    ): Array<ScoredDocument> {
        let rrfK: Float64 = 60.0  // RRF smoothing constant

        // Map docId → summed RRF score or weighted score
        var scoreMap = HashMap<Int64, Float64>()
        var docSources = HashMap<Int64, Array<String>>()

        let addDoc = { doc: ScoredDocument =>
            let id = doc.docId
            let rank = doc.rank + 1  // 1-based rank for RRF formula
            if (strategy == "weighted" && let Some(w) <- weights) {
                // Use rank position as score proxy (higher rank = lower score)
                let sourceIdx = match (doc.source) {
                    case "dense" => 0
                    case "sparse" => 1
                    case "colbert" => 2
                    case _ => 0
                }
                let weightedScore = w[sourceIdx] * (1.0 / (1.0 + Float64(doc.rank)))
                scoreMap[id] = scoreMap.getOrPut(id, 0.0) + weightedScore
            } else {
                // RRF: score = 1 / (k + rank)
                scoreMap[id] = scoreMap.getOrPut(id, 0.0) + (1.0 / (rrfK + Float64(rank)))
            }
        }

        // Collect all documents
        for (doc in sparse) { addDoc(doc) }
        for (doc in dense) { addDoc(doc) }
        for (doc in colbert) { addDoc(doc) }

        if (scoreMap.size == 0) {
            return Array<ScoredDocument>()
        }

        // Sort by score descending
        var results = ArrayList<(Int64, Float64)>(scoreMap.size)
        for ((docId, score) in scoreMap) {
            results.add((docId, score))
        }
        results.sort({ a, b =>
            if (a[1] > b[1]) { -1 }
            else if (a[1] < b[1]) { 1 }
            else { 0 }
        })

        // Take top-k
        let count = if (results.size < topK) { results.size } else { topK }
        Array<ScoredDocument>(count) { i =>
            ScoredDocument(
                docId: results[i][0],
                score: results[i][1] as Float32,
                source: "fusion",
                rank: i as Int64
            )
        }
    }
}
