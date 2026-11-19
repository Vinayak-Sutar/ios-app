import Foundation

/// Vector maths, ported from `mnemo/vecs.py`.
///
/// Everything stored is L2-normalised, so cosine similarity is a plain dot
/// product. Search is brute force on purpose: at a few hundred notes it is
/// microseconds, and an approximate index would be a second thing to keep
/// correct for no measurable gain.
public enum Vectors {

    /// Cosine similarity of two already-normalised vectors.
    ///
    /// Returns 0 for a dimension mismatch rather than trapping, because a
    /// stale vector from a previous embedder revision is a thing that happens
    /// and must not crash capture.
    ///
    /// The result is only accurate to about 1e-7: the vectors are stored as
    /// Float32, so identical vectors score 0.9999999 rather than exactly 1.0,
    /// and a similarity can land a hair *above* 1.0. Never compare these to a
    /// threshold more tightly than that, and never assume the range is closed.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum: Double = 0
        for i in 0..<a.count { sum += Double(a[i]) * Double(b[i]) }
        return sum
    }

    public static func l2Normalise(_ v: [Float]) -> [Float] {
        var sumSquares: Double = 0
        for x in v { sumSquares += Double(x) * Double(x) }
        let norm = sumSquares.squareRoot()
        guard norm > 1e-12 else { return v }
        return v.map { Float(Double($0) / norm) }
    }

    /// Mean of several vectors, normalised. Used to turn a token-vector stream
    /// into one note vector, and a set of note vectors into a collection
    /// centroid.
    public static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let dim = first.count
        var acc = [Double](repeating: 0, count: dim)
        var counted = 0
        for v in vectors where v.count == dim {
            for i in 0..<dim { acc[i] += Double(v[i]) }
            counted += 1
        }
        guard counted > 0 else { return [] }
        return l2Normalise(acc.map { Float($0 / Double(counted)) })
    }

    /// Weighted mean, for the title-weighted window pooling. Weights are
    /// renormalised, so passing fewer weights than vectors is fine.
    public static func weightedMean(_ vectors: [[Float]], weights: [Double]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let dim = first.count
        var acc = [Double](repeating: 0, count: dim)
        var total: Double = 0
        for (index, v) in vectors.enumerated() where v.count == dim {
            let w = index < weights.count ? weights[index] : weights.last ?? 1
            for i in 0..<dim { acc[i] += Double(v[i]) * w }
            total += w
        }
        guard total > 0 else { return [] }
        return l2Normalise(acc.map { Float($0 / total) })
    }

    /// Fold one new member into a running centroid without keeping history.
    /// O(dim), which is why collections can hold any number of notes.
    public static func foldIntoCentroid(_ centroid: [Float], count: Int, adding v: [Float]) -> [Float] {
        guard !centroid.isEmpty, centroid.count == v.count, count > 0 else {
            return l2Normalise(v)
        }
        let n = Double(count)
        var acc = [Double](repeating: 0, count: centroid.count)
        for i in 0..<centroid.count {
            acc[i] = (Double(centroid[i]) * n + Double(v[i])) / (n + 1)
        }
        return l2Normalise(acc.map { Float($0) })
    }

    /// Top-k by cosine, highest first. Skips any candidate whose dimension
    /// differs from the query's.
    public static func topK<ID: Hashable>(
        query: [Float],
        candidates: [(id: ID, vector: [Float])],
        k: Int
    ) -> [(id: ID, similarity: Double)] {
        guard !query.isEmpty, k > 0 else { return [] }
        var scored: [(id: ID, similarity: Double)] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates where candidate.vector.count == query.count {
            scored.append((candidate.id, cosine(query, candidate.vector)))
        }
        scored.sort { $0.similarity > $1.similarity }
        return Array(scored.prefix(k))
    }

    // MARK: - Storage

    /// Little-endian float32, the same layout the Python index uses, so a
    /// vector file could be moved between the two if that ever mattered.
    public static func pack(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 4)
        for x in v {
            var le = x.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// `Data` from a decoded blob is not guaranteed 4-byte aligned, so this
    /// reads unaligned on purpose. Binding memory to `Float` here would be
    /// undefined behaviour that happens to work until it doesn't.
    public static func unpack(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(count)
        let bytes = [UInt8](data)
        for i in 0..<count {
            var raw: UInt32 = 0
            raw |= UInt32(bytes[i * 4 + 0])
            raw |= UInt32(bytes[i * 4 + 1]) << 8
            raw |= UInt32(bytes[i * 4 + 2]) << 16
            raw |= UInt32(bytes[i * 4 + 3]) << 24
            out.append(Float(bitPattern: UInt32(littleEndian: raw)))
        }
        return out
    }

    public static func encodeBase64(_ v: [Float]) -> String {
        pack(v).base64EncodedString()
    }

    public static func decodeBase64(_ text: String) -> [Float] {
        guard let data = Data(base64Encoded: text) else { return [] }
        return unpack(data)
    }
}
