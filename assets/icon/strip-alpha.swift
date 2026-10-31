import AppKit
for p in CommandLine.arguments.dropFirst() {
  let url = URL(fileURLWithPath: p)
  guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
  let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.setFillColor(CGColor.white); ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
