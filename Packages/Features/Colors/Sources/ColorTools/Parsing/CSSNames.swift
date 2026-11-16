nonisolated extension CSSNames {
    /// The color with this name, without regard to ASCII case, or nil. `transparent` is black with
    /// alpha 0, as in CSS.
    static func color(named bytes: some Collection<UInt8>) -> ColorValue? {
        // The longest name, lightgoldenrodyellow, has 20 letters.
        guard (3...20).contains(bytes.count) else { return nil }
        var name = ""
        name.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): name.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): name.unicodeScalars.append(Unicode.Scalar(byte + 32))
            default: return nil
            }
        }
        if name == "transparent" { return ColorValue(red: 0, green: 0, blue: 0, alpha: 0) }
        var low = 0
        var high = table.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let entry = table[middle]
            if entry.name == name {
                let rgb = entry.rgb
                return ColorValue(bytes: Int(rgb >> 16 & 0xFF), Int(rgb >> 8 & 0xFF), Int(rgb & 0xFF))
            }
            if entry.name < name { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// The name of a color that is exactly one of the named colors, such as "rebeccapurple" for
    /// #663399, or nil. Where two names share a color, as gray and grey do, the first in the table
    /// wins.
    static func name(of color: ColorValue) -> String? {
        guard !color.isOutsideSRGB, color.alpha >= 1 else { return nil }
        let bytes = color.bytes
        let rgb = UInt32(bytes.red) << 16 | UInt32(bytes.green) << 8 | UInt32(bytes.blue)
        let exact = ColorValue(bytes: bytes.red, bytes.green, bytes.blue)
        guard exact.matches(color) else { return nil }
        return table.first { $0.rgb == rgb }?.name
    }
}
