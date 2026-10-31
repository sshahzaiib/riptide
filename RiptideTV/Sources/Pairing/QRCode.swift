import CoreImage

enum QRCode {
    static func image(for string: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        guard let out = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10), highQualityDownsample: false)
        else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
