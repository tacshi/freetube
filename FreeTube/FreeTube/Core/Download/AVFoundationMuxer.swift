#if targetEnvironment(macCatalyst)
import AudioToolbox
import AVFoundation
import Foundation

/// Mac Catalyst's stand-in for ffmpeg in the download pipeline (CLAUDE.md §10): joins the
/// downloaded video and audio tracks into one MP4 without re-encoding, like `ffmpeg -c copy`.
///
/// **Why the platforms differ:** the ffmpeg packages (`kewlbear/FFmpeg-iOS-*`) ship only iOS
/// device and simulator slices, so they can't link into the Catalyst build. macOS's AVFoundation,
/// unlike iOS's, reads MPEG-TS and ADTS files, so the system can do the join itself.
///
/// **Two traps, both checked against real YouTube segments:**
/// - AVFoundation picks a file's format by its extension, not its content, so each input is
///   first renamed to match what it holds (`typed(_:)`).
/// - ADTS has no index, so AVFoundation *estimates* its duration — about 0.6% short. An export
///   copies only that range, which cut the end off the audio (0.65s on a 108s video, growing
///   with length). So the audio is first rewrapped into M4A packet by packet with AudioToolbox
///   (`rewrapAudio(_:)`), which gives it an exact duration. The TS video's duration is exact.
///   Result on a 108s video: same frames and same audio length as ffmpeg's copy.
///
/// Everything here blocks on file I/O: call it from `Task.detached` (CLAUDE.md §15.12).
@available(iOS 17.0, *)
nonisolated enum AVFoundationMuxer {
    /// Writes `video` (plus `audio`, when the stream keeps audio separate) to `output` as MP4,
    /// with the index at the front so other apps can start playing at once.
    static func mux(video: URL, audio: URL?, to output: URL) async throws {
        let videoAsset = AVURLAsset(url: try typed(video))
        let composition = AVMutableComposition()
        try await insert(.video, of: videoAsset, into: composition, required: true)
        if let audio {
            let audioAsset = AVURLAsset(url: try rewrapAudio(try typed(audio)))
            try await insert(.audio, of: audioAsset, into: composition, required: true)
        } else {
            // Muxed variant: the audio, if any, is in the video file.
            try await insert(.audio, of: videoAsset, into: composition, required: false)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError.conversionFailed
        }
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)
        if #available(iOS 18.0, macCatalyst 18.0, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? DownloadError.conversionFailed
            }
        }
    }

    // MARK: - Private

    /// Copies the first track of `mediaType` into `composition`, moved to start at zero.
    private static func insert(
        _ mediaType: AVMediaType,
        of asset: AVURLAsset,
        into composition: AVMutableComposition,
        required: Bool
    ) async throws {
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
            if required { throw DownloadError.conversionFailed }
            return
        }
        let range = try await track.load(.timeRange)
        guard let target = composition.addMutableTrack(
            withMediaType: mediaType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw DownloadError.conversionFailed
        }
        try target.insertTimeRange(range, of: track, at: .zero)
    }

    /// Copies every audio packet of the ADTS file at `url` into an M4A next to it, unchanged, and
    /// returns the M4A. Unlike the ADTS source, the M4A records its exact length (see the type's
    /// doc comment).
    ///
    /// AudioToolbox rather than `AVAssetReader` / `AVAssetWriter`: the reader hands out AAC with
    /// no magic cookie, which the writer refuses (-12735). `AudioFile` reads the ADTS packets
    /// (skipping the ID3 tags) and supplies the cookie.
    private static func rewrapAudio(_ url: URL) throws -> URL {
        var sourceID: AudioFileID?
        try check(AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileAAC_ADTSType, &sourceID))
        guard let source = sourceID else { throw DownloadError.conversionFailed }
        defer { AudioFileClose(source) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFileGetProperty(source, kAudioFilePropertyDataFormat, &formatSize, &format))
        var maxPacketSize: UInt32 = 0
        var maxPacketSizeSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioFileGetProperty(source, kAudioFilePropertyPacketSizeUpperBound, &maxPacketSizeSize, &maxPacketSize))

        let destination = url.deletingPathExtension().appendingPathExtension("m4a")
        var targetID: AudioFileID?
        try check(AudioFileCreateWithURL(destination as CFURL, kAudioFileM4AType, &format, .eraseFile, &targetID))
        guard let target = targetID else { throw DownloadError.conversionFailed }
        defer { AudioFileClose(target) }

        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(source, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            try check(AudioFileGetProperty(source, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie))
            try check(AudioFileSetProperty(target, kAudioFilePropertyMagicCookieData, cookieSize, cookie))
        }

        let packetsPerChunk: UInt32 = 1024
        var buffer = [UInt8](repeating: 0, count: Int(packetsPerChunk * max(maxPacketSize, 1)))
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: Int(packetsPerChunk))
        var nextPacket: Int64 = 0
        while true {
            var byteCount = UInt32(buffer.count)
            var packetCount = packetsPerChunk
            let status = AudioFileReadPacketData(source, false, &byteCount, &descriptions, nextPacket, &packetCount, &buffer)
            guard status == noErr || status == kAudioFileEndOfFileError else { try check(status); break }
            if packetCount == 0 { break }
            try check(AudioFileWritePackets(target, false, byteCount, descriptions, nextPacket, &packetCount, buffer))
            nextPacket += Int64(packetCount)
        }
        guard nextPacket > 0 else { throw DownloadError.conversionFailed }

        // The M4A writer otherwise assumes the usual 2112-sample encoder delay and trims it,
        // starting the audio 46ms early against the picture. ADTS carries no delay: every frame
        // plays, as with ffmpeg's copy.
        var packetTable = AudioFilePacketTableInfo(
            mNumberValidFrames: nextPacket * Int64(max(format.mFramesPerPacket, 1)),
            mPrimingFrames: 0,
            mRemainderFrames: 0
        )
        try check(AudioFileSetProperty(
            target,
            kAudioFilePropertyPacketTableInfo,
            UInt32(MemoryLayout<AudioFilePacketTableInfo>.size),
            &packetTable
        ))
        return destination
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Renames `url` so its extension matches its content: `.ts` for an MPEG transport stream
    /// (sync byte `0x47` every 188 bytes), `.aac` for anything else — YouTube's separate audio is
    /// ADTS, each segment led by an ID3 timestamp tag. Returns the file's new URL.
    private static func typed(_ url: URL) throws -> URL {
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 189) ?? Data()
        try? handle.close()
        let isTransportStream = head.count == 189
            && head[head.startIndex] == 0x47
            && head[head.startIndex + 188] == 0x47
        let pathExtension = isTransportStream ? "ts" : "aac"
        guard url.pathExtension != pathExtension else { return url }
        let renamed = url.deletingPathExtension().appendingPathExtension(pathExtension)
        try? FileManager.default.removeItem(at: renamed)
        try FileManager.default.moveItem(at: url, to: renamed)
        return renamed
    }
}
#endif
