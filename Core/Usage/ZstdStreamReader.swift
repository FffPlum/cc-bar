import Foundation
import libzstd

/// 按块流式解压一个 zstd 文件，交付解压后的字节。
///
/// Codex 会把 7 天未写入的会话压成同目录的 `.jsonl.zst`（单帧、帧头带 content size），
/// resume 时再解压回 `.jsonl`。扫描器以解压后的字节偏移续扫，与原 `.jsonl` 的 watermark 一一对应。
/// 多帧拼接与 skippable 帧由 libzstd 连续解码，checksum 由 libzstd 校验。
nonisolated final class ZstdStreamReader {
    enum ReadError: Error, Equatable {
        /// libzstd 报告解码失败：损坏、checksum 不匹配等。
        case corrupted(name: String)
        /// 输入在帧结束前耗尽（含空文件）。
        case truncated
    }

    private static let inputChunkCapacity = 256 * 1024
    private static let outputChunkCapacity = 256 * 1024

    private let handle: FileHandle
    private let context: OpaquePointer
    private let inputBuffer: UnsafeMutableRawPointer
    private let outputBuffer: UnsafeMutableRawPointer
    private var inputSize = 0
    private var inputPos = 0
    private var inputExhausted = false
    /// 还在等帧数据：开头尚未读到任何帧，或最近一次解码停在帧中间（libzstd 返回非 0 提示）。
    /// 输入耗尽时仍为 true 即截断。
    private var frameOpen = true

    init(url: URL) throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        guard let context = ZSTD_createDCtx() else {
            try? fileHandle.close()
            throw ReadError.corrupted(name: "ZSTD_createDCtx")
        }
        handle = fileHandle
        self.context = context
        inputBuffer = UnsafeMutableRawPointer.allocate(byteCount: Self.inputChunkCapacity, alignment: 1)
        outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: Self.outputChunkCapacity, alignment: 1)
    }

    deinit {
        ZSTD_freeDCtx(context)
        inputBuffer.deallocate()
        outputBuffer.deallocate()
        try? handle.close()
    }

    /// 读取至多 `count` 字节解压内容；返回 nil 表示已到结尾。
    func read(upToCount count: Int) throws -> Data? {
        var output = Data()
        while output.count < count {
            if inputPos == inputSize, !inputExhausted {
                try refill()
            }
            // 上一帧已完整解出且没有更多输入：到头。不能再拿空输入调用解码，
            // 那会返回「等待下一帧」的非 0 提示，被误判为截断。
            if inputPos == inputSize, inputExhausted, !frameOpen { break }
            let consumedBefore = inputPos
            var out = ZSTD_outBuffer(
                dst: outputBuffer,
                size: min(Self.outputChunkCapacity, count - output.count),
                pos: 0
            )
            var input = ZSTD_inBuffer(src: inputBuffer, size: inputSize, pos: inputPos)
            let remaining = ZSTD_decompressStream(context, &out, &input)
            if ZSTD_isError(remaining) != 0 {
                throw ReadError.corrupted(name: String(cString: ZSTD_getErrorName(remaining)))
            }
            inputPos = input.pos
            frameOpen = remaining != 0
            if out.pos > 0 {
                output.append(outputBuffer.assumingMemoryBound(to: UInt8.self), count: out.pos)
                continue
            }
            guard inputPos == consumedBefore else { continue }
            // 本轮既没产出也没消费：输入已读完就到头，否则下一轮补读输入。
            if inputPos == inputSize, inputExhausted {
                if frameOpen { throw ReadError.truncated }
                break
            }
            if inputPos < inputSize {
                throw ReadError.corrupted(name: "no progress")
            }
        }
        return output.isEmpty ? nil : output
    }

    /// 跳过开头 `count` 字节解压内容，返回实际跳过的字节数（内容不足时小于 `count`）。
    func skip(_ count: UInt64) throws -> UInt64 {
        var skipped: UInt64 = 0
        while skipped < count {
            let chunk = try autoreleasepool {
                try read(upToCount: Int(min(count - skipped, UInt64(4 << 20))))
            }
            guard let chunk else { break }
            skipped += UInt64(chunk.count)
        }
        return skipped
    }

    private func refill() throws {
        guard let chunk = try handle.read(upToCount: Self.inputChunkCapacity), !chunk.isEmpty else {
            inputExhausted = true
            inputSize = 0
            inputPos = 0
            return
        }
        chunk.withUnsafeBytes { source in
            if let base = source.baseAddress {
                inputBuffer.copyMemory(from: base, byteCount: chunk.count)
            }
        }
        inputSize = chunk.count
        inputPos = 0
    }

    /// 解压后的总字节数。优先取首帧帧头里的 content size（Codex 写入时声明了原文件大小），
    /// 帧头未声明时完整解压一遍计数。文件打不开或损坏返回 nil。
    static func decompressedSize(of url: URL) -> UInt64? {
        if let declared = declaredContentSize(of: url) { return declared }
        guard let reader = try? ZstdStreamReader(url: url) else { return nil }
        return try? reader.skip(.max)
    }

    private static func declaredContentSize(of url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // ZSTD_FRAMEHEADERSIZE_MAX = 18
        guard let header = try? handle.read(upToCount: 18), !header.isEmpty else { return nil }
        let size = header.withUnsafeBytes { raw in
            ZSTD_getFrameContentSize(raw.baseAddress, raw.count)
        }
        // ZSTD_CONTENTSIZE_UNKNOWN = 0ULL - 1，ZSTD_CONTENTSIZE_ERROR = 0ULL - 2；
        // 首帧是 skippable 帧时返回 0，同样交给完整解压计数。
        guard size > 0, size < UInt64.max - 1 else { return nil }
        return size
    }
}
