import Foundation

enum TargetSpeakerSegmentFiltering {
    static func apply(
        _ segment: CompletedAudioSegment,
        result: TargetSpeakerFilterResult
    ) -> CompletedAudioSegment {
        CompletedAudioSegment(
            samples: result.samples,
            overlapSampleCount: segment.overlapSampleCount
        )
    }
}
