import XCTest
import FluidAudio

final class FluidAudioAPISmokeTests: XCTestCase {
    func testPinnedFluidAudioAPIsCompile() {
        let processVAD: (VadManager, [Float]) async throws -> [VadResult] = {
            try await $0.process($1)
        }
        _ = processVAD
        _ = VadManager.chunkSize
        _ = VadManager.sampleRate

        let diarizer = DiarizerManager()
        XCTAssertFalse(diarizer.isAvailable)
        _ = DiarizerModels.defaultModelsDirectory()
        _ = try? diarizer.extractSpeakerEmbedding(from: [Float](repeating: 0, count: 24_000))

        let diarize: (DiarizerManager, [Float]) throws -> DiarizationResult = {
            try $0.performCompleteDiarization($1, sampleRate: VadManager.sampleRate)
        }
        _ = diarize
    }
}
