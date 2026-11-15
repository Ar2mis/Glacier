import Foundation
import WhisperKit

/// Use a complete local model directly, without a network model-list request.
/// New downloads live outside macOS's protected Documents folder.
public enum WhisperModelStorage {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glacier/Models")
    }
    public static var legacyRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
    }
    public static func cachedFolder(_ model: WhisperModel, root: URL) -> URL? {
        let folder = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/" + model.rawValue)
        let required = ["MelSpectrogram.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/coremldata.bin",
                        "AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/coremldata.bin",
                        "TextDecoder.mlmodelc/weights/weight.bin"]
        return required.allSatisfy { FileManager.default.isReadableFile(atPath: folder.appendingPathComponent($0).path) } ? folder : nil
    }
    public static func configuration(_ model: WhisperModel) -> WhisperKitConfig {
        let cachedRoot = cachedFolder(model, root: root) != nil ? root : legacyRoot
        let local = cachedFolder(model, root: cachedRoot)
        return WhisperKitConfig(model: model.rawValue, downloadBase: root,
                                modelFolder: local?.path, tokenizerFolder: local == nil ? root : cachedRoot,
                                verbose: false, prewarm: true, load: true,
                                download: local == nil)
    }
}
