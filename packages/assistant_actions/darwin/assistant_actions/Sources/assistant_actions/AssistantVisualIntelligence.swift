import Foundation

// VisualIntelligence isn't in every SDK (the iOS simulator's lacks it), so
// this compiles only where it is, and only with Xcode 27 (Swift 6.4), whose
// SDKs the generated search query is written for.
#if canImport(VisualIntelligence) && compiler(>=6.4)
  import CoreImage
  import UniformTypeIdentifiers
  import VisualIntelligence

  /// What Visual Intelligence saw crosses to Dart as
  /// `AssistantSemanticContent`: `{labels, image}`, with the image written as
  /// a PNG file (an `AssistantFile` map), like the files Siri passes.
  extension AssistantValues {
    @available(iOS 26.0, macOS 27.0, *)
    public static func encode(_ content: SemanticContentDescriptor?) -> Any {
      guard let content else { return NSNull() }
      var map: [String: Any] = ["labels": content.labels]
      if let png = content.pixelBuffer?.withUnsafeBuffer({ pngData($0) }) {
        let file = saveFile(named: "image.png", type: .png) { try png.write(to: $0) }
        if !(file is NSNull) { map["image"] = file }
      }
      return map
    }

    /// [buffer] as PNG data, in sRGB.
    static func pngData(_ buffer: CVPixelBuffer) -> Data? {
      let image = CIImage(cvPixelBuffer: buffer)
      guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
      return CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: space)
    }
  }
#endif
