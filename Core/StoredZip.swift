import Foundation

/// Minimal ZIP STORE writer for the fixed OOXML parts, including on iOS where
/// Process and /usr/bin/zip are unavailable. No extraction or user-supplied paths.
public enum StoredZip {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    public static func archive(_ files: [(String, Data)]) throws -> Data {
        guard files.count < 65535, Set(files.map { $0.0 }).count == files.count else { throw GlacierCoreError.message("Invalid Word package entries.") }
        var output = Data(), central = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
        }
        for (path, data) in files {
            let name = Data(path.utf8)
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), name.count < 65535,
                  data.count < 32_000_000, output.count < 128_000_000 else { throw GlacierCoreError.message("Word package exceeds its size limit.") }
            var crc = UInt32.max
            for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
            crc ^= UInt32.max
            let offset = UInt32(output.count), size = UInt32(data.count)
            append(UInt32(0x04034b50), to: &output)
            for n: UInt16 in [20, 0x0800, 0, 0, 0x21] { append(n, to: &output) }
            for n in [crc, size, size] { append(n, to: &output) }
            append(UInt16(name.count), to: &output); append(UInt16(0), to: &output)
            output.append(name); output.append(data)
            append(UInt32(0x02014b50), to: &central)
            for n: UInt16 in [20, 20, 0x0800, 0, 0, 0x21] { append(n, to: &central) }
            for n in [crc, size, size] { append(n, to: &central) }
            for n: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { append(n, to: &central) }
            append(UInt32(0), to: &central); append(offset, to: &central); central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        append(UInt32(0x06054b50), to: &output)
        for n: UInt16 in [0, 0, UInt16(files.count), UInt16(files.count)] { append(n, to: &output) }
        append(UInt32(central.count), to: &output); append(centralOffset, to: &output); append(UInt16(0), to: &output)
        return output
    }
}
