import Accelerate
import Foundation

/// FFT engine used by the analysis pipeline. Buffers are reused across hops so
/// long songs don't cause constant reallocation. Not thread-safe — the analysis
/// pipeline is single-threaded by design.
final class SpectralAnalyzer {
    let fftSize: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var inputReal: [Float]
    private var inputImag: [Float]
    private var outputReal: [Float]
    private var outputImag: [Float]
    private var magnitudes: [Float]

    init?(fftSize: Int) {
        guard fftSize > 1, fftSize & (fftSize - 1) == 0 else { return nil }
        self.fftSize = fftSize
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fft = fft
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        self.inputReal = [Float](repeating: 0, count: fftSize)
        self.inputImag = [Float](repeating: 0, count: fftSize)
        self.outputReal = [Float](repeating: 0, count: fftSize)
        self.outputImag = [Float](repeating: 0, count: fftSize)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
    }

    /// Magnitude spectrum (fftSize/2 bins) of one windowed frame.
    func magnitudeSpectrum(of frame: [Float]) -> [Float] {
        precondition(frame.count == fftSize)
        return frame.withUnsafeBufferPointer { src in
            magnitudeSpectrum(of: src)
        }
    }

    /// Magnitude spectrum (fftSize/2 bins) of one windowed frame, read
    /// straight from a caller-owned buffer — no intermediate array copy per
    /// hop (the analysis hot loop calls this ~46k× on a 10-minute song).
    func magnitudeSpectrum(of buffer: UnsafeBufferPointer<Float>) -> [Float] {
        precondition(buffer.count == fftSize)
        vDSP_vmul(buffer.baseAddress!, 1, window, 1, &inputReal, 1, vDSP_Length(fftSize))
        vDSP_vclr(&inputImag, 1, vDSP_Length(fftSize))
        // DSPSplitComplex stores raw pointers, so keep them scoped to the
        // buffers' lifetimes (nested withUnsafe calls on distinct arrays).
        inputReal.withUnsafeMutableBufferPointer { realIn in
            inputImag.withUnsafeMutableBufferPointer { imagIn in
                outputReal.withUnsafeMutableBufferPointer { realOut in
                    outputImag.withUnsafeMutableBufferPointer { imagOut in
                        let input = DSPSplitComplex(realp: realIn.baseAddress!, imagp: imagIn.baseAddress!)
                        var output = DSPSplitComplex(realp: realOut.baseAddress!, imagp: imagOut.baseAddress!)
                        fft.transform(input: input, output: &output, direction: .forward)
                    }
                }
            }
        }
        vDSP_vdist(outputReal, 1, outputImag, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
        return magnitudes
    }

    /// Mean magnitude within a frequency band (Hz). Used for approximate
    /// kick/snare/melodic classification from spectral shape.
    func bandEnergy(_ magnitudes: [Float], lowHz: Double, highHz: Double, sampleRate: Double) -> Float {
        let binsPerHz = Double(magnitudes.count) / (sampleRate / 2.0)
        let start = max(0, Int((lowHz * binsPerHz).rounded(.down)))
        let end = min(magnitudes.count - 1, Int((highHz * binsPerHz).rounded(.up)))
        guard end > start else { return 0 }
        var sum: Float = 0
        for i in start...end { sum += magnitudes[i] }
        return sum / Float(end - start + 1)
    }
}