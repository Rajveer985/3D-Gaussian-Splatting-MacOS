import Foundation
import simd

/// Errors that can occur during PLY file loading
enum PLYLoaderError: Error {
    case fileNotFound
    case invalidHeader
    case unsupportedFormat
    case parseError(String)
    case missingRequiredProperty(String)
}

/// PLY file format loader for Gaussian Splatting files
class PLYLoader {
    
    // MARK: - Types
    
    enum Format {
        case ascii
        case binaryLittleEndian
        case binaryBigEndian
    }
    
    struct Property {
        let name: String
        let type: String
    }
    
    struct Element {
        let name: String
        let count: Int
        let properties: [Property]
    }
    
    struct Header {
        let format: Format
        let elements: [Element]
    }
    
    // MARK: - Loading
    
    /// Load Gaussian splats from a PLY file
    static func load(from url: URL) throws -> [GaussianSplat] {
        print("Loading PLY file from: \(url.path)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PLYLoaderError.fileNotFound
        }
        
        let data = try Data(contentsOf: url)
        print("File size: \(data.count / 1024 / 1024) MB")
        
        return try load(from: data)
    }
    
    /// Load Gaussian splats from PLY data
    static func load(from data: Data) throws -> [GaussianSplat] {
        guard !data.isEmpty else {
            throw PLYLoaderError.parseError("File is empty")
        }
        
        // Parse header
        let (header, headerEnd) = try parseHeader(data)
        
        // Parse vertex data
        guard let vertexElement = header.elements.first(where: { $0.name == "vertex" }) else {
            throw PLYLoaderError.missingRequiredProperty("vertex element")
        }
        
        print("Found vertex element with \(vertexElement.count) vertices")
        
        guard vertexElement.count > 0 else {
            throw PLYLoaderError.parseError("No vertices found in PLY file")
        }
        
        let splats: [GaussianSplat]
        switch header.format {
        case .ascii:
            splats = try parseASCIIVertices(data, headerEnd: headerEnd, element: vertexElement)
        case .binaryLittleEndian:
            splats = try parseBinaryVertices(data, headerEnd: headerEnd, element: vertexElement, bigEndian: false)
        case .binaryBigEndian:
            splats = try parseBinaryVertices(data, headerEnd: headerEnd, element: vertexElement, bigEndian: true)
        }
        
        print("Successfully parsed \(splats.count) splats")
        
        return splats
    }
    
    // MARK: - Header Parsing
    
    private static func parseHeader(_ data: Data) throws -> (Header, Int) {
        guard let headerRange = data.range(of: Data("end_header".utf8)) else {
            throw PLYLoaderError.invalidHeader
        }
        
        var headerEndIndex = headerRange.upperBound
        while headerEndIndex < data.count &&
                (data[headerEndIndex] == 10 || data[headerEndIndex] == 13) {
            headerEndIndex += 1
        }
        
        let headerData = data.prefix(headerEndIndex)
        guard let headerString = String(data: headerData, encoding: .ascii) else {
            throw PLYLoaderError.invalidHeader
        }
        
        let lines = headerString.components(separatedBy: .newlines)
        
        guard lines.first?.hasPrefix("ply") == true else {
            throw PLYLoaderError.invalidHeader
        }
        
        var format: Format = .ascii
        var elements: [Element] = []
        var currentElement: Element?
        var currentProperties: [Property] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed == "end_header" {
                // Save last element
                if let element = currentElement {
                    elements.append(Element(name: element.name, 
                                          count: element.count, 
                                          properties: currentProperties))
                }
                
                break
            }
            
            let parts = trimmed.components(separatedBy: .whitespaces)
            guard parts.count > 0 else { continue }
            
            switch parts[0] {
            case "format":
                guard parts.count >= 2 else { throw PLYLoaderError.invalidHeader }
                switch parts[1] {
                case "ascii": format = .ascii
                case "binary_little_endian": format = .binaryLittleEndian
                case "binary_big_endian": format = .binaryBigEndian
                default: throw PLYLoaderError.unsupportedFormat
                }
                
            case "element":
                // Save previous element
                if let element = currentElement {
                    elements.append(Element(name: element.name, 
                                          count: element.count, 
                                          properties: currentProperties))
                    currentProperties = []
                }
                
                guard parts.count >= 3,
                      let count = Int(parts[2]) else {
                    throw PLYLoaderError.invalidHeader
                }
                currentElement = Element(name: parts[1], count: count, properties: [])
                
            case "property":
                guard parts.count >= 3 else { throw PLYLoaderError.invalidHeader }
                
                if parts[1] == "list" {
                    // List property - skip for now (not used in standard Gaussian Splatting)
                    continue
                } else {
                    let property = Property(name: parts[2], type: parts[1])
                    currentProperties.append(property)
                }
                
            default:
                break
            }
        }
        
        return (Header(format: format, elements: elements), headerEndIndex)
    }
    
    // MARK: - ASCII Parsing
    
    private static func parseASCIIVertices(_ data: Data, headerEnd: Int, element: Element) throws -> [GaussianSplat] {
        guard let content = String(data: data, encoding: .ascii) else {
            throw PLYLoaderError.parseError("Failed to decode ASCII data")
        }
        
        let lines = content.components(separatedBy: .newlines)
        
        // Find where data starts (after header)
        var dataStartLine = 0
        var byteCount = 0
        for (index, line) in lines.enumerated() {
            if byteCount >= headerEnd {
                dataStartLine = index
                break
            }
            byteCount += line.utf8.count + 1
        }
        
        var splats: [GaussianSplat] = []
        splats.reserveCapacity(element.count)
        
        // Create property name to index mapping
        let propertyMap = Dictionary(uniqueKeysWithValues: element.properties.enumerated().map { ($1.name, $0) })
        
        for i in 0..<element.count {
            let lineIndex = dataStartLine + i
            guard lineIndex < lines.count else { break }
            
            let line = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            
            let values = line.components(separatedBy: .whitespaces)
            
            do {
                let splat = try parseVertex(values: values, propertyMap: propertyMap)
                splats.append(splat)
            } catch {
                print("Warning: Failed to parse vertex at line \(lineIndex + 1): \(error)")
            }
        }
        
        return splats
    }
    
    // MARK: - Binary Parsing
    
    private static func parseBinaryVertices(_ data: Data, headerEnd: Int, element: Element, bigEndian: Bool) throws -> [GaussianSplat] {
        var splats: [GaussianSplat] = []
        splats.reserveCapacity(element.count)
        
        // Create property name to index mapping
        let propertyMap = Dictionary(uniqueKeysWithValues: element.properties.enumerated().map { ($1.name, $0) })
        
        // Calculate stride (bytes per vertex)
        let stride = element.properties.reduce(0) { sum, prop in
            sum + sizeOfType(prop.type)
        }
        
        var offset = headerEnd
        
        for _ in 0..<element.count {
            guard offset + stride <= data.count else { break }
            
            var values: [Float] = []
            var currentOffset = offset
            
            for property in element.properties {
                let size = sizeOfType(property.type)
                guard currentOffset + size <= data.count else { break }
                
                let value: Float
                switch property.type {
                case "float":
                    var floatValue: Float = 0
                    withUnsafeMutableBytes(of: &floatValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    if bigEndian {
                        var bitPattern = floatValue.bitPattern.bigEndian
                        floatValue = Float(bitPattern: UInt32(bigEndian: bitPattern))
                    }
                    value = floatValue
                    
                case "double":
                    var doubleValue: Double = 0
                    withUnsafeMutableBytes(of: &doubleValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    if bigEndian {
                        var bitPattern = doubleValue.bitPattern.bigEndian
                        doubleValue = Double(bitPattern: UInt64(bigEndian: bitPattern))
                    }
                    value = Float(doubleValue)
                    
                case "uchar", "uint8":
                    var intValue: UInt8 = 0
                    withUnsafeMutableBytes(of: &intValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    value = Float(intValue)
                    
                case "char", "int8":
                    var intValue: Int8 = 0
                    withUnsafeMutableBytes(of: &intValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    value = Float(intValue)
                    
                case "ushort", "uint16":
                    var intValue: UInt16 = 0
                    withUnsafeMutableBytes(of: &intValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    value = Float(bigEndian ? intValue.byteSwapped : intValue)
                    
                case "short", "int16":
                    var intValue: Int16 = 0
                    withUnsafeMutableBytes(of: &intValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    value = Float(bigEndian ? intValue.byteSwapped : intValue)
                    
                case "uint", "uint32":
                    var intValue: UInt32 = 0
                    withUnsafeMutableBytes(of: &intValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    value = Float(bigEndian ? intValue.byteSwapped : intValue)
                    
                case "int", "int32":
                    var intValue: Int32 = 0
                    withUnsafeMutableBytes(of: &intValue) { ptr in
                        data.copyBytes(to: ptr, from: currentOffset..<currentOffset+size)
                    }
                    value = Float(bigEndian ? intValue.byteSwapped : intValue)
                    
                default:
                    value = 0
                }
                
                values.append(value)
                currentOffset += size
            }
            
            do {
                let splat = try parseVertex(values: values.map { String($0) }, propertyMap: propertyMap)
                splats.append(splat)
            } catch {
                // Skip invalid vertices
            }
            
            offset += stride
        }
        
        return splats
    }
    
    // MARK: - Vertex Parsing
    
    private static func parseVertex(values: [String], propertyMap: [String: Int]) throws -> GaussianSplat {
        // Helper to get float value
        func getFloat(_ name: String) -> Float? {
            guard let index = propertyMap[name], index < values.count else { return nil }
            return Float(values[index])
        }
        
        // Required: position
        guard let x = getFloat("x"),
              let y = getFloat("y"),
              let z = getFloat("z") else {
            throw PLYLoaderError.missingRequiredProperty("position (x, y, z)")
        }
        
        let position = float3(x, y, z)
        
        // Optional: scale (default to 0.01 if not present)
        let scale = float3(
            exp(getFloat("scale_0") ?? log(0.01)),
            exp(getFloat("scale_1") ?? log(0.01)),
            exp(getFloat("scale_2") ?? log(0.01))
        )
        
        // Optional: rotation quaternion (default to identity)
        let rotation = float4(
            getFloat("rot_1") ?? 0,
            getFloat("rot_2") ?? 0,
            getFloat("rot_3") ?? 0,
            getFloat("rot_0") ?? 1
        ).normalized
        
        // Optional: color from spherical harmonics DC component
        var color = float3(1, 1, 1)
        var shCoefficients = Array(repeating: Float(0), count: 48)
        if let r = getFloat("f_dc_0"),
           let g = getFloat("f_dc_1"),
           let b = getFloat("f_dc_2") {
            // Graphdeco stores the DC SH term; convert it back to base RGB.
            let shC0: Float = 0.2820948
            color = simd_clamp(
                float3(
                    shC0 * r + 0.5,
                    shC0 * g + 0.5,
                    shC0 * b + 0.5
                ),
                float3(repeating: 0.0),
                float3(repeating: 1.0)
            )
            shCoefficients[0] = r
            shCoefficients[16] = g
            shCoefficients[32] = b
            for channel in 0..<3 {
                for coefficient in 0..<15 {
                    let propertyName = "f_rest_\(channel * 15 + coefficient)"
                    if let value = getFloat(propertyName) {
                        shCoefficients[channel * 16 + coefficient + 1] = value
                    }
                }
            }
        } else if let r = getFloat("red"),
                  let g = getFloat("green"),
                  let b = getFloat("blue") {
            // Direct RGB values (0-255 range)
            color = float3(r / 255.0, g / 255.0, b / 255.0)
            let shC0: Float = 0.2820948
            let dc = (color - float3(repeating: 0.5)) / shC0
            shCoefficients[0] = dc.x
            shCoefficients[16] = dc.y
            shCoefficients[32] = dc.z
        }
        
        // Optional: opacity
        let opacity: Float
        if let op = getFloat("opacity") {
            opacity = sigmoid(op)
        } else {
            opacity = 1.0
        }
        
        return GaussianSplat(
            position: position,
            scale: scale,
            rotation: rotation,
            color: color,
            opacity: opacity,
            shCoefficients: shCoefficients
        )
    }
    
    // MARK: - Helpers
    
    private static func sizeOfType(_ type: String) -> Int {
        switch type {
        case "char", "int8", "uchar", "uint8": return 1
        case "short", "int16", "ushort", "uint16": return 2
        case "int", "int32", "uint", "uint32", "float": return 4
        case "long", "int64", "ulong", "uint64", "double": return 8
        default: return 4
        }
    }
    
    private static func sigmoid(_ x: Float) -> Float {
        return 1.0 / (1.0 + exp(-x))
    }
}
