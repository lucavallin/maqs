/// Terrarium encoding: metres = (R × 256 + G + B / 256) − 32768.
enum Terrarium {
    static func elevation(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        Double(red) * 256 + Double(green) + Double(blue) / 256 - 32768
    }
}
