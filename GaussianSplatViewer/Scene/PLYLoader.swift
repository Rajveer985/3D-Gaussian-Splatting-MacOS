import Foundation
import simd

// MARK: - Errors

enum PLYLoaderError: Error {
    case fileNotFound
    case invalidHeader
    case unsupportedFormat
    case parseError(String)
    case missingRequiredProperty(String)
}

// MARK: - PLY Loader

/// High-performance binary PLY loader for Gaussian Splatting files.
/// Parses the header once to build a byte-offset table, then reads
/// all vertices in a single pass with no string conversions.
class PLYLoader {

    // MARK: - Header types

    enum Format { case ascii, binaryLittleEndian, binaryBigEndian }

    struct Property {
        let name: String
        let type: String
        let byteOffset: Int   // byte offset within one vertex record
        let byteSize: Int
    }

    struct Element {
        let name: String
        let count: Int
        let properties: [Property]
        let stride: Int       // total bytes per vertex
    }

    struct Header {
        let format: Format
        let elements: [Element]
    }

    // MARK: - Public API

    static func load(from url: URL) throws -> [GaussianSplat] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PLYLoaderError.fileNotFound
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        print("File size: \(data.count / 1024 / 1024) MB")
        return try load(from: data)
    }

    static func load(from data: Data) throws -> [GaussianSplat] {
        guard !data.isEmpty else { throw PLYLoaderError.parseError("File is empty") }

        let (header, dataStart) = try parseHeader(data)

        guard let vertexElement = header.elements.first(where: { $0.name == "vertex" }),
              vertexElement.count > 0 else {
            throw PLYLoaderError.missingRequiredProperty("vertex element")
        }

        print("Found vertex element with \(vertexElement.count) vertices")

        switch header.format {
        case .ascii:
            return try parseASCII(data, dataStart: dataStart, element: vertexElement)
        case .binaryLittleEndian:
            return try parseBinaryFast(data, dataStart: dataStart, element: vertexElement, bigEndian: false)
        case .binaryBigEndian:
            return try parseBinaryFast(data, dataStart: dataStart, element: vertexElement, bigEndian: true)
        }
    }

    // MARK: - Header parsing

    private static func parseHeader(_ data: Data) throws -> (Header, Int) {
        guard let headerRange = data.range(of: Data("end_header".utf8)) else {
            throw PLYLoaderError.invalidHeader
        }

        var dataStart = headerRange.upperBound
        while dataStart < data.count && (data[dataStart] == 10 || data[dataStart] == 13) {
            dataStart += 1
        }

        guard let headerString = String(data: data.prefix(dataStart), encoding: .ascii) else {
            throw PLYLoaderError.invalidHeader
        }

        let lines = headerString.components(separatedBy: .newlines)
        guard lines.first?.hasPrefix("ply") == true else { throw PLYLoaderError.invalidHeader }

        var format: Format = .ascii
        var elements: [Element] = []
        var currentName: String?
        var currentCount = 0
        var currentProps: [(name: String, type: String)] = []

        func flushElement() {
            guard let name = currentName else { return }
            var offset = 0
            let props = currentProps.map { p -> Property in
                let sz = sizeOf(p.type)
                let prop = Property(name: p.name, type: p.type, byteOffset: offset, byteSize: sz)
                offset += sz
                return prop
            }
            elements.append(Element(name: name, count: currentCount, properties: props, stride: offset))
        }

        for line in lines {
            let parts = line.trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: .whitespaces)
                            .filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }

            switch parts[0] {
            case "format":
                guard parts.count >= 2 else { throw PLYLoaderError.invalidHeader }
                switch parts[1] {
                case "ascii":                format = .ascii
                case "binary_little_endian": format = .binaryLittleEndian
                case "binary_big_endian":    format = .binaryBigEndian
                default: throw PLYLoaderError.unsupportedFormat
                }
            case "element":
                flushElement()
                currentName  = parts.count >= 2 ? parts[1] : nil
                currentCount = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
                currentProps = []
            case "property":
                guard parts.count >= 3, parts[1] != "list" else { continue }
                currentProps.append((name: parts[2], type: parts[1]))
            case "end_header":
                flushElement()
            default: break
            }
        }

        return (Header(format: format, elements: elements), dataStart)
    }

    // MARK: - Fast binary parser

    private static func parseBinaryFast(_ data: Data,
                                        dataStart: Int,
                                        element: Element,
                                        bigEndian: Bool) throws -> [GaussianSplat] {
        let count  = element.count
        let stride = element.stride
        let props  = element.properties

        // Build lookup table: property name → Property
        var propMap = [String: Property]()
        propMap.reserveCapacity(props.count)
        for p in props { propMap[p.name] = p }

        // Pre-resolve offsets for all fields we care about
        let offX    = propMap["x"]?.byteOffset
        let offY    = propMap["y"]?.byteOffset
        let offZ    = propMap["z"]?.byteOffset
        let offS0   = propMap["scale_0"]?.byteOffset
        let offS1   = propMap["scale_1"]?.byteOffset
        let offS2   = propMap["scale_2"]?.byteOffset
        let offR0   = propMap["rot_0"]?.byteOffset   // w
        let offR1   = propMap["rot_1"]?.byteOffset   // x
        let offR2   = propMap["rot_2"]?.byteOffset   // y
        let offR3   = propMap["rot_3"]?.byteOffset   // z
        let offOp   = propMap["opacity"]?.byteOffset
        let offDC0  = propMap["f_dc_0"]?.byteOffset
        let offDC1  = propMap["f_dc_1"]?.byteOffset
        let offDC2  = propMap["f_dc_2"]?.byteOffset

        // f_rest_0 … f_rest_44  (3 channels × 15 higher-order coefficients)
        var offRest = [Int?](repeating: nil, count: 45)
        for i in 0..<45 { offRest[i] = propMap["f_rest_\(i)"]?.byteOffset }

        guard dataStart + stride * count <= data.count else {
            throw PLYLoaderError.parseError("File truncated")
        }

        var splats = [GaussianSplat]()
        splats.reserveCapacity(count)

        // Work directly on raw bytes — zero allocations per vertex
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }

            for i in 0..<count {
                let vBase = base.advanced(by: dataStart + i * stride)

                func f32(_ off: Int?) -> Float {
                    guard let o = off else { return 0 }
                    var v: Float = 0
                    memcpy(&v, vBase.advanced(by: o), 4)
                    return bigEndian ? Float(bitPattern: v.bitPattern.byteSwapped) : v
                }

                // Position
                guard let ox = offX, let oy = offY, let oz = offZ else {
                    throw PLYLoaderError.missingRequiredProperty("x/y/z")
                }
                let pos = float3(f32(ox), f32(oy), f32(oz))

                // Scale (stored as log-scale in 3DGS files)
                let scale = float3(
                    exp(offS0 != nil ? f32(offS0) : log(Float(0.01))),
                    exp(offS1 != nil ? f32(offS1) : log(Float(0.01))),
                    exp(offS2 != nil ? f32(offS2) : log(Float(0.01)))
                )

                // Rotation quaternion — 3DGS stores (w, x, y, z) as rot_0…rot_3
                let qw = offR0 != nil ? f32(offR0) : Float(1)
                let qx = offR1 != nil ? f32(offR1) : Float(0)
                let qy = offR2 != nil ? f32(offR2) : Float(0)
                let qz = offR3 != nil ? f32(offR3) : Float(0)
                // Our quaternion convention: (x, y, z, w)
                let qLen = sqrt(qx*qx + qy*qy + qz*qz + qw*qw)
                let rotation = qLen > 0
                    ? float4(qx/qLen, qy/qLen, qz/qLen, qw/qLen)
                    : float4(0, 0, 0, 1)

                // Opacity (sigmoid-activated in 3DGS files)
                let opacity: Float
                if let o = offOp {
                    let raw = f32(o)
                    opacity = 1.0 / (1.0 + exp(-raw))
                } else {
                    opacity = 1.0
                }

                // Spherical harmonics
                var sh = [Float](repeating: 0, count: 48)
                let shC0: Float = 0.28209479177387814

                if offDC0 != nil {
                    // DC band (degree 0) — stored as raw SH coefficients
                    sh[0]  = f32(offDC0)
                    sh[16] = f32(offDC1)
                    sh[32] = f32(offDC2)

                    // Higher-order bands: f_rest_0…f_rest_14 = R degree1-3
                    //                     f_rest_15…f_rest_29 = G degree1-3
                    //                     f_rest_30…f_rest_44 = B degree1-3
                    for ch in 0..<3 {
                        for coeff in 0..<15 {
                            let restIdx = ch * 15 + coeff
                            if let v = offRest[restIdx] {
                                sh[ch * 16 + coeff + 1] = f32(v)
                            }
                        }
                    }
                }

                // Base color from DC SH term
                let color = simd_clamp(
                    float3(shC0 * sh[0] + 0.5,
                           shC0 * sh[16] + 0.5,
                           shC0 * sh[32] + 0.5),
                    float3(repeating: 0), float3(repeating: 1)
                )

                splats.append(GaussianSplat(
                    position: pos,
                    scale: scale,
                    rotation: rotation,
                    color: color,
                    opacity: opacity,
                    shCoefficients: sh
                ))
            }
        }

        print("Successfully parsed \(splats.count) splats")
        return splats
    }

    // MARK: - ASCII fallback (unchanged logic, kept for compatibility)

    private static func parseASCII(_ data: Data,
                                   dataStart: Int,
                                   element: Element) throws -> [GaussianSplat] {
        guard let content = String(data: data, encoding: .ascii) else {
            throw PLYLoaderError.parseError("Failed to decode ASCII data")
        }
        let lines = content.components(separatedBy: .newlines)
        let propMap = Dictionary(uniqueKeysWithValues:
            element.properties.enumerated().map { ($1.name, $0) })

        // Find first data line
        var byteCount = 0
        var dataLine  = 0
        for (i, line) in lines.enumerated() {
            if byteCount >= dataStart { dataLine = i; break }
            byteCount += line.utf8.count + 1
        }

        var splats = [GaussianSplat]()
        splats.reserveCapacity(element.count)
        for i in 0..<element.count {
            let idx = dataLine + i
            guard idx < lines.count else { break }
            let vals = lines[idx].trimmingCharacters(in: .whitespaces)
                                 .components(separatedBy: .whitespaces)
            if let s = try? parseVertexASCII(vals, propMap: propMap) { splats.append(s) }
        }
        return splats
    }

    private static func parseVertexASCII(_ values: [String],
                                         propMap: [String: Int]) throws -> GaussianSplat {
        func f(_ name: String) -> Float? {
            guard let i = propMap[name], i < values.count else { return nil }
            return Float(values[i])
        }
        guard let x = f("x"), let y = f("y"), let z = f("z") else {
            throw PLYLoaderError.missingRequiredProperty("x/y/z")
        }
        let scale = float3(exp(f("scale_0") ?? log(0.01)),
                           exp(f("scale_1") ?? log(0.01)),
                           exp(f("scale_2") ?? log(0.01)))
        let qw = f("rot_0") ?? 1; let qx = f("rot_1") ?? 0
        let qy = f("rot_2") ?? 0; let qz = f("rot_3") ?? 0
        let rotation = float4(qx, qy, qz, qw).normalized
        let opacity  = f("opacity").map { 1/(1+exp(-$0)) } ?? 1.0
        var sh = [Float](repeating: 0, count: 48)
        let shC0: Float = 0.28209479177387814
        if let r = f("f_dc_0"), let g = f("f_dc_1"), let b = f("f_dc_2") {
            sh[0] = r; sh[16] = g; sh[32] = b
            for ch in 0..<3 {
                for c in 0..<15 {
                    if let v = f("f_rest_\(ch*15+c)") { sh[ch*16+c+1] = v }
                }
            }
        }
        let color = simd_clamp(float3(shC0*sh[0]+0.5, shC0*sh[16]+0.5, shC0*sh[32]+0.5),
                               float3(repeating:0), float3(repeating:1))
        return GaussianSplat(position: float3(x,y,z), scale: scale, rotation: rotation,
                             color: color, opacity: opacity, shCoefficients: sh)
    }

    // MARK: - Helpers

    private static func sizeOf(_ type: String) -> Int {
        switch type {
        case "char","int8","uchar","uint8":           return 1
        case "short","int16","ushort","uint16":       return 2
        case "int","int32","uint","uint32","float":   return 4
        case "long","int64","ulong","uint64","double":return 8
        default: return 4
        }
    }
}
