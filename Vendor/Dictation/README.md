# Local speech runtime

Unmodified macOS universal static frameworks copied from the ticket-12 spike.
They are build inputs, included so a clean archive builds without downloading
libraries. No model or audio is included. App linking selects the host slice.

- sherpa-onnx 1.13.8: https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip
- ONNX Runtime 1.28.2: https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip

The app calls the C API directly. Licences are beside these frameworks and
bundled in Resources/DictationLicenses.txt. GIGAAM-LICENSE covers the separate
model download. Model file SHA-256 values are pinned in DictationModelFiles.
