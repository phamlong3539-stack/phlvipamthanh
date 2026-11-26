#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace phl {
namespace dsp {

struct DSPParams {
    float pitch_semitones = 0.0f;
    float formant_shift = 1.0f;
    float eq_low_db = 0.0f;
    float eq_mid_db = 0.0f;
    float eq_high_db = 0.0f;
    float noise_gate_db = -48.0f;
    float compressor_threshold_db = -18.0f;
    float compressor_ratio = 2.5f;
    float limiter_ceiling_db = -0.8f;
    float naturalness = 0.90f;
    float target_f0_hz = 0.0f;     // Detected F0 from admin source audio (0 = fixed semitones)
    bool adaptive_pitch = false;   // Auto-adapt pitch relative to speaker's natural resting F0
    bool enabled = false;
    bool locked_bypass = true;
};

struct TelemetrySnapshot {
    float input_db = -96.0f;
    float output_db = -96.0f;
    double sample_rate = 48000.0;
    float detected_speaker_f0_hz = 0.0f;
    float effective_pitch_semitones = 0.0f;
    bool gate_open = false;
    bool is_processing_active = false;
    uint64_t processed_frames = 0;
};

namespace detail {

constexpr float kPi = 3.14159265358979323846f;
constexpr float kTwoPi = 6.28318530717958647692f;
constexpr uint32_t kMaxChannels = 2;
constexpr uint32_t kRingSize = 16384; // Supports up to 192 kHz & deep WSOLA lookback
constexpr uint32_t kRingMask = kRingSize - 1;
constexpr uint32_t kStackChunkFrames = 256;
constexpr uint32_t kPitchBufSize = 1024;

inline float clampf(float v, float lo, float hi) noexcept {
    return (v < lo) ? lo : ((v > hi) ? hi : v);
}

inline float dbToLinear(float db) noexcept {
    return std::pow(10.0f, db * 0.05f);
}

inline float linearToDb(float lin) noexcept {
    return 20.0f * std::log10(std::max(lin, 1.0e-6f));
}

struct Biquad {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;
    float z1[kMaxChannels] = {0.0f, 0.0f};
    float z2[kMaxChannels] = {0.0f, 0.0f};

    void reset() noexcept {
        for (uint32_t c = 0; c < kMaxChannels; ++c) {
            z1[c] = 0.0f;
            z2[c] = 0.0f;
        }
    }

    inline float process(float x, uint32_t ch) noexcept {
        const float y = b0 * x + z1[ch];
        z1[ch] = b1 * x - a1 * y + z2[ch];
        z2[ch] = b2 * x - a2 * y;
        return y;
    }

    void setHighPass(double sr, float freqHz, float q = 0.70710678f) noexcept {
        const float f = clampf(freqHz, 20.0f, static_cast<float>(sr) * 0.45f);
        const float w0 = kTwoPi * f / static_cast<float>(sr);
        const float cosW = std::cos(w0);
        const float alpha = std::sin(w0) / (2.0f * q);
        const float a0Inv = 1.0f / (1.0f + alpha);

        b0 = ((1.0f + cosW) * 0.5f) * a0Inv;
        b1 = (-(1.0f + cosW)) * a0Inv;
        b2 = b0;
        a1 = (-2.0f * cosW) * a0Inv;
        a2 = (1.0f - alpha) * a0Inv;
    }

    void setPeaking(double sr, float freqHz, float q, float gainDb) noexcept {
        if (std::fabs(gainDb) < 0.02f) {
            b0 = 1.0f; b1 = 0.0f; b2 = 0.0f; a1 = 0.0f; a2 = 0.0f;
            return;
        }
        const float f = clampf(freqHz, 40.0f, static_cast<float>(sr) * 0.45f);
        const float A = std::pow(10.0f, gainDb / 40.0f);
        const float w0 = kTwoPi * f / static_cast<float>(sr);
        const float cosW = std::cos(w0);
        const float alpha = std::sin(w0) / (2.0f * std::max(q, 0.25f));
        const float a0Inv = 1.0f / (1.0f + alpha / A);

        b0 = (1.0f + alpha * A) * a0Inv;
        b1 = (-2.0f * cosW) * a0Inv;
        b2 = (1.0f - alpha * A) * a0Inv;
        a1 = (-2.0f * cosW) * a0Inv;
        a2 = (1.0f - alpha / A) * a0Inv;
    }

    void setLowShelf(double sr, float freqHz, float gainDb, float slope = 0.75f) noexcept {
        if (std::fabs(gainDb) < 0.02f) {
            b0 = 1.0f; b1 = 0.0f; b2 = 0.0f; a1 = 0.0f; a2 = 0.0f;
            return;
        }
        const float f = clampf(freqHz, 35.0f, static_cast<float>(sr) * 0.42f);
        const float A = std::pow(10.0f, gainDb / 40.0f);
        const float w0 = kTwoPi * f / static_cast<float>(sr);
        const float cosW = std::cos(w0);
        const float sinW = std::sin(w0);
        const float alpha = sinW * 0.5f * std::sqrt(std::max(0.05f, (A + 1.0f / A) * (1.0f / slope - 1.0f) + 2.0f));
        const float twoSqrtAAlpha = 2.0f * std::sqrt(A) * alpha;
        const float a0Inv = 1.0f / ((A + 1.0f) + (A - 1.0f) * cosW + twoSqrtAAlpha);

        b0 = (A * ((A + 1.0f) - (A - 1.0f) * cosW + twoSqrtAAlpha)) * a0Inv;
        b1 = (2.0f * A * ((A - 1.0f) - (A + 1.0f) * cosW)) * a0Inv;
        b2 = (A * ((A + 1.0f) - (A - 1.0f) * cosW - twoSqrtAAlpha)) * a0Inv;
        a1 = (-2.0f * ((A - 1.0f) + (A + 1.0f) * cosW)) * a0Inv;
        a2 = ((A + 1.0f) + (A - 1.0f) * cosW - twoSqrtAAlpha) * a0Inv;
    }

    void setHighShelf(double sr, float freqHz, float gainDb, float slope = 0.75f) noexcept {
        if (std::fabs(gainDb) < 0.02f) {
            b0 = 1.0f; b1 = 0.0f; b2 = 0.0f; a1 = 0.0f; a2 = 0.0f;
            return;
        }
        const float f = clampf(freqHz, 300.0f, static_cast<float>(sr) * 0.45f);
        const float A = std::pow(10.0f, gainDb / 40.0f);
        const float w0 = kTwoPi * f / static_cast<float>(sr);
        const float cosW = std::cos(w0);
        const float sinW = std::sin(w0);
        const float alpha = sinW * 0.5f * std::sqrt(std::max(0.05f, (A + 1.0f / A) * (1.0f / slope - 1.0f) + 2.0f));
        const float twoSqrtAAlpha = 2.0f * std::sqrt(A) * alpha;
        const float a0Inv = 1.0f / ((A + 1.0f) - (A - 1.0f) * cosW + twoSqrtAAlpha);

        b0 = (A * ((A + 1.0f) + (A - 1.0f) * cosW + twoSqrtAAlpha)) * a0Inv;
        b1 = (-2.0f * A * ((A - 1.0f) + (A + 1.0f) * cosW)) * a0Inv;
        b2 = (A * ((A + 1.0f) + (A - 1.0f) * cosW - twoSqrtAAlpha)) * a0Inv;
        a1 = (2.0f * ((A - 1.0f) - (A + 1.0f) * cosW)) * a0Inv;
        a2 = ((A + 1.0f) - (A - 1.0f) * cosW - twoSqrtAAlpha) * a0Inv;
    }
};

struct PitchChannelState {
    float ring[kRingSize] = {0.0f};
    uint32_t writePos = 0;
    float phaseA = 0.0f;
    float prevPhaseA = 0.0f;
    float phaseOffsetA = 0.0f; // WSOLA phase-aligned delay offset for grain A
    float phaseOffsetB = 0.0f; // WSOLA phase-aligned delay offset for grain B
    float fricativeHpState = 0.0f;
    float prevIn = 0.0f;

    void reset() noexcept {
        std::memset(ring, 0, sizeof(ring));
        writePos = 0;
        phaseA = 0.0f;
        prevPhaseA = 0.0f;
        phaseOffsetA = 0.0f;
        phaseOffsetB = 0.0f;
        fricativeHpState = 0.0f;
        prevIn = 0.0f;
    }

    inline float readHermite(float delaySamples) const noexcept {
        const float safeDelay = clampf(delaySamples, 4.0f, static_cast<float>(kRingSize - 8));
        const float pos = static_cast<float>(writePos) - safeDelay;
        const float floored = std::floor(pos);
        const float t = pos - floored;
        const int32_t idx0 = static_cast<int32_t>(floored);

        const float ym1 = ring[(idx0 - 1) & kRingMask];
        const float y0  = ring[idx0 & kRingMask];
        const float y1  = ring[(idx0 + 1) & kRingMask];
        const float y2  = ring[(idx0 + 2) & kRingMask];

        const float c0 = y0;
        const float c1 = 0.5f * (y1 - ym1);
        const float c2 = ym1 - 2.5f * y0 + 2.0f * y1 - 0.5f * y2;
        const float c3 = 0.5f * (y2 - ym1) + 1.5f * (y0 - y1);
        return ((c3 * t + c2) * t + c1) * t + c0;
    }

    // WSOLA cross-correlation alignment: finds optimal delay offset matching reference grain phase
    float findBestWsolaOffset(float nominalDelay, float refDelay, float searchSpan, uint32_t corrWin) const noexcept {
        const int32_t refBase = static_cast<int32_t>(writePos) - static_cast<int32_t>(std::lrintf(refDelay));
        const int32_t nomBase = static_cast<int32_t>(writePos) - static_cast<int32_t>(std::lrintf(nominalDelay));
        const int32_t halfSpan = std::max<int32_t>(16, static_cast<int32_t>(searchSpan * 0.5f));

        float bestScore = -1.0e18f;
        int32_t bestDelta = 0;

        // Coarse search (step 4)
        for (int32_t delta = -halfSpan; delta <= halfSpan; delta += 4) {
            const float candDelay = nominalDelay + static_cast<float>(delta);
            if (candDelay < 16.0f || candDelay > static_cast<float>(kRingSize - 128)) continue;

            float dot = 0.0f;
            float normCand = 1.0e-9f;
            const int32_t candBase = nomBase - delta;
            for (uint32_t k = 0; k < corrWin; k += 2) {
                const float r = ring[(refBase - static_cast<int32_t>(k)) & kRingMask];
                const float c = ring[(candBase - static_cast<int32_t>(k)) & kRingMask];
                dot += r * c;
                normCand += c * c;
            }
            const float score = dot / std::sqrt(normCand);
            if (score > bestScore) {
                bestScore = score;
                bestDelta = delta;
            }
        }

        // Fine 1-sample refinement around bestDelta
        int32_t finalDelta = bestDelta;
        for (int32_t delta = bestDelta - 3; delta <= bestDelta + 3; ++delta) {
            const float candDelay = nominalDelay + static_cast<float>(delta);
            if (candDelay < 16.0f || candDelay > static_cast<float>(kRingSize - 128)) continue;

            float dot = 0.0f;
            float normCand = 1.0e-9f;
            const int32_t candBase = nomBase - delta;
            for (uint32_t k = 0; k < corrWin; k += 2) {
                const float r = ring[(refBase - static_cast<int32_t>(k)) & kRingMask];
                const float c = ring[(candBase - static_cast<int32_t>(k)) & kRingMask];
                dot += r * c;
                normCand += c * c;
            }
            const float score = dot / std::sqrt(normCand);
            if (score > bestScore) {
                bestScore = score;
                finalDelta = delta;
            }
        }

        return static_cast<float>(finalDelta);
    }
};

} // namespace detail

class VoiceDSPProcessor {
public:
    static VoiceDSPProcessor& shared() noexcept {
        static VoiceDSPProcessor instance;
        return instance;
    }

    VoiceDSPProcessor() noexcept {
        prepare(48000.0);
    }

    void updateParams(const DSPParams& nextParams) noexcept {
        DSPParams sanitized = nextParams;
        sanitized.pitch_semitones = detail::clampf(sanitized.pitch_semitones, -12.0f, 12.0f);
        sanitized.formant_shift = detail::clampf(sanitized.formant_shift, 0.72f, 1.38f);
        sanitized.eq_low_db = detail::clampf(sanitized.eq_low_db, -9.0f, 9.0f);
        sanitized.eq_mid_db = detail::clampf(sanitized.eq_mid_db, -9.0f, 9.0f);
        sanitized.eq_high_db = detail::clampf(sanitized.eq_high_db, -9.0f, 9.0f);
        sanitized.noise_gate_db = detail::clampf(sanitized.noise_gate_db, -60.0f, -18.0f);
        sanitized.compressor_threshold_db = detail::clampf(sanitized.compressor_threshold_db, -36.0f, -4.0f);
        sanitized.compressor_ratio = detail::clampf(sanitized.compressor_ratio, 1.2f, 8.0f);
        sanitized.limiter_ceiling_db = detail::clampf(sanitized.limiter_ceiling_db, -3.0f, -0.2f);
        sanitized.naturalness = detail::clampf(sanitized.naturalness, 0.1f, 1.0f);
        if (sanitized.target_f0_hz < 65.0f || sanitized.target_f0_hz > 420.0f) {
            sanitized.adaptive_pitch = false;
        }

        const uint64_t seq = paramSeq_.load(std::memory_order_relaxed);
        paramSeq_.store(seq + 1, std::memory_order_release);
        stagingParams_ = sanitized;
        paramSeq_.store(seq + 2, std::memory_order_release);

        atomicEnabled_.store(sanitized.enabled, std::memory_order_release);
        atomicLockedBypass_.store(sanitized.locked_bypass, std::memory_order_release);
    }

    void setEnabled(bool enabled) noexcept {
        atomicEnabled_.store(enabled, std::memory_order_release);
    }

    void setLockedBypass(bool locked) noexcept {
        atomicLockedBypass_.store(locked, std::memory_order_release);
    }

    void prepare(double sampleRate) noexcept {
        const double safeRate = (sampleRate >= 8000.0 && sampleRate <= 192000.0) ? sampleRate : 48000.0;
        sampleRate_ = safeRate;

        hpfFilter_.setHighPass(safeRate, 80.0f, 0.7071f);
        updateFilterCoefficients(true);
        reset();
    }

    void reset() noexcept {
        hpfFilter_.reset();
        formantCompLow_.reset();
        formantCompF1_.reset();
        formantCompF2_.reset();
        formantCompF3_.reset();
        formantCompAir_.reset();
        eqLow_.reset();
        eqMid_.reset();
        eqHigh_.reset();
        for (uint32_t c = 0; c < detail::kMaxChannels; ++c) {
            pitchState_[c].reset();
        }
        std::memset(f0Buf_, 0, sizeof(f0Buf_));
        f0WritePos_ = 0;
        f0DecimCounter_ = 0;
        f0EvalCounter_ = 0;
        speakerF0Hz_ = 145.0f;
        hasDetectedSpeakerF0_ = false;
        adaptiveTargetSemitones_ = 0.0f;
        unvoicedRatio_ = 0.0f;
        lowBandEnv_ = 0.0f;
        highBandEnv_ = 0.0f;

        gateEnvelope_ = 0.0f;
        gateGain_ = 1.0f;
        gateOpenState_ = false;
        compEnvelope_ = 0.0f;
        limiterGain_ = 1.0f;
        wetMix_ = 0.0f;
    }

    TelemetrySnapshot telemetry() const noexcept {
        TelemetrySnapshot snap;
        snap.input_db = telInputDb_.load(std::memory_order_relaxed);
        snap.output_db = telOutputDb_.load(std::memory_order_relaxed);
        snap.sample_rate = telSampleRate_.load(std::memory_order_relaxed);
        snap.detected_speaker_f0_hz = telSpeakerF0_.load(std::memory_order_relaxed);
        snap.effective_pitch_semitones = telEffPitch_.load(std::memory_order_relaxed);
        snap.gate_open = telGateOpen_.load(std::memory_order_relaxed);
        snap.is_processing_active = telProcessingActive_.load(std::memory_order_relaxed);
        snap.processed_frames = telProcessedFrames_.load(std::memory_order_relaxed);
        return snap;
    }

    void processAudioBufferList(
        AudioBufferList* ioData,
        UInt32 inNumberFrames,
        const AudioStreamBasicDescription& asbd
    ) noexcept {
        if (!ioData || inNumberFrames == 0 || ioData->mNumberBuffers == 0) {
            return;
        }
        const double sr = (asbd.mSampleRate >= 8000.0 && asbd.mSampleRate <= 192000.0)
            ? asbd.mSampleRate
            : sampleRate_;

        const bool isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        const bool isSignedInt16 = (!isFloat) &&
                                   ((asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0) &&
                                   (asbd.mBitsPerChannel == 16);
        const bool isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

        if (!isFloat && !isSignedInt16) {
            return;
        }

        if (isNonInterleaved || ioData->mNumberBuffers > 1) {
            const uint32_t numCh = std::min<uint32_t>(ioData->mNumberBuffers, detail::kMaxChannels);
            if (isFloat) {
                float* chPtrs[detail::kMaxChannels] = {nullptr, nullptr};
                for (uint32_t c = 0; c < numCh; ++c) {
                    if (ioData->mBuffers[c].mDataByteSize < inNumberFrames * sizeof(float)) return;
                    chPtrs[c] = static_cast<float*>(ioData->mBuffers[c].mData);
                }
                processFloatChannels(chPtrs, numCh, inNumberFrames, sr);
            } else {
                int16_t* chPtrs[detail::kMaxChannels] = {nullptr, nullptr};
                for (uint32_t c = 0; c < numCh; ++c) {
                    if (ioData->mBuffers[c].mDataByteSize < inNumberFrames * sizeof(int16_t)) return;
                    chPtrs[c] = static_cast<int16_t*>(ioData->mBuffers[c].mData);
                }
                processInt16Channels(chPtrs, numCh, inNumberFrames, sr);
            }
            return;
        }

        AudioBuffer& buf = ioData->mBuffers[0];
        const uint32_t numCh = std::min<uint32_t>(std::max<uint32_t>(1, buf.mNumberChannels), detail::kMaxChannels);

        if (isFloat) {
            if (buf.mDataByteSize < inNumberFrames * numCh * sizeof(float)) return;
            float* data = static_cast<float*>(buf.mData);
            if (numCh == 1) {
                float* chPtrs[1] = {data};
                processFloatChannels(chPtrs, 1, inNumberFrames, sr);
            } else {
                processInterleavedFloat(data, numCh, inNumberFrames, sr);
            }
        } else {
            if (buf.mDataByteSize < inNumberFrames * numCh * sizeof(int16_t)) return;
            int16_t* data = static_cast<int16_t*>(buf.mData);
            if (numCh == 1) {
                int16_t* chPtrs[1] = {data};
                processInt16Channels(chPtrs, 1, inNumberFrames, sr);
            } else {
                processInterleavedInt16(data, numCh, inNumberFrames, sr);
            }
        }
    }

    void processFloatChannels(
        float* const* channels,
        uint32_t numChannels,
        uint32_t numFrames,
        double sampleRate
    ) noexcept {
        if (!channels || numChannels == 0 || numFrames == 0) return;
        const uint32_t activeCh = std::min(numChannels, detail::kMaxChannels);
        for (uint32_t c = 0; c < activeCh; ++c) {
            if (!channels[c]) return;
        }

        syncRateAndParams(sampleRate);

        const bool wantActive = atomicEnabled_.load(std::memory_order_acquire) &&
                                !atomicLockedBypass_.load(std::memory_order_acquire);
        const float targetWet = wantActive ? 1.0f : 0.0f;

        if (!wantActive && wetMix_ < 1.0e-5f) {
            updatePassthroughTelemetry(channels[0], numFrames, sampleRate);
            return;
        }

        processChannelsCore(channels, activeCh, numFrames, targetWet);
    }

    void processInt16Channels(
        int16_t* const* channels,
        uint32_t numChannels,
        uint32_t numFrames,
        double sampleRate
    ) noexcept {
        if (!channels || numChannels == 0 || numFrames == 0) return;
        const uint32_t activeCh = std::min(numChannels, detail::kMaxChannels);
        for (uint32_t c = 0; c < activeCh; ++c) {
            if (!channels[c]) return;
        }

        syncRateAndParams(sampleRate);
        const bool wantActive = atomicEnabled_.load(std::memory_order_acquire) &&
                                !atomicLockedBypass_.load(std::memory_order_acquire);
        const float targetWet = wantActive ? 1.0f : 0.0f;

        float scratch[detail::kMaxChannels][detail::kStackChunkFrames];
        uint32_t offset = 0;
        while (offset < numFrames) {
            const uint32_t chunk = std::min(numFrames - offset, detail::kStackChunkFrames);
            float* ptrs[detail::kMaxChannels] = {scratch[0], scratch[1]};
            for (uint32_t c = 0; c < activeCh; ++c) {
                for (uint32_t i = 0; i < chunk; ++i) {
                    scratch[c][i] = static_cast<float>(channels[c][offset + i]) * (1.0f / 32768.0f);
                }
            }
            if (!wantActive && wetMix_ < 1.0e-5f) {
                updatePassthroughTelemetry(scratch[0], chunk, sampleRate);
            } else {
                processChannelsCore(ptrs, activeCh, chunk, targetWet);
                for (uint32_t c = 0; c < activeCh; ++c) {
                    for (uint32_t i = 0; i < chunk; ++i) {
                        const float clamped = detail::clampf(scratch[c][i], -1.0f, 1.0f);
                        channels[c][offset + i] = static_cast<int16_t>(std::lrintf(clamped * 32767.0f));
                    }
                }
            }
            offset += chunk;
        }
    }

private:
    void processInterleavedFloat(float* data, uint32_t numCh, uint32_t numFrames, double sampleRate) noexcept {
        syncRateAndParams(sampleRate);
        const bool wantActive = atomicEnabled_.load(std::memory_order_acquire) &&
                                !atomicLockedBypass_.load(std::memory_order_acquire);
        const float targetWet = wantActive ? 1.0f : 0.0f;

        float scratch[detail::kMaxChannels][detail::kStackChunkFrames];
        uint32_t offset = 0;
        while (offset < numFrames) {
            const uint32_t chunk = std::min(numFrames - offset, detail::kStackChunkFrames);
            float* ptrs[detail::kMaxChannels] = {scratch[0], scratch[1]};
            for (uint32_t i = 0; i < chunk; ++i) {
                for (uint32_t c = 0; c < numCh; ++c) {
                    scratch[c][i] = data[(offset + i) * numCh + c];
                }
            }
            if (!wantActive && wetMix_ < 1.0e-5f) {
                updatePassthroughTelemetry(scratch[0], chunk, sampleRate);
            } else {
                processChannelsCore(ptrs, numCh, chunk, targetWet);
                for (uint32_t i = 0; i < chunk; ++i) {
                    for (uint32_t c = 0; c < numCh; ++c) {
                        data[(offset + i) * numCh + c] = scratch[c][i];
                    }
                }
            }
            offset += chunk;
        }
    }

    void processInterleavedInt16(int16_t* data, uint32_t numCh, uint32_t numFrames, double sampleRate) noexcept {
        syncRateAndParams(sampleRate);
        const bool wantActive = atomicEnabled_.load(std::memory_order_acquire) &&
                                !atomicLockedBypass_.load(std::memory_order_acquire);
        const float targetWet = wantActive ? 1.0f : 0.0f;

        float scratch[detail::kMaxChannels][detail::kStackChunkFrames];
        uint32_t offset = 0;
        while (offset < numFrames) {
            const uint32_t chunk = std::min(numFrames - offset, detail::kStackChunkFrames);
            float* ptrs[detail::kMaxChannels] = {scratch[0], scratch[1]};
            for (uint32_t i = 0; i < chunk; ++i) {
                for (uint32_t c = 0; c < numCh; ++c) {
                    scratch[c][i] = static_cast<float>(data[(offset + i) * numCh + c]) * (1.0f / 32768.0f);
                }
            }
            if (!wantActive && wetMix_ < 1.0e-5f) {
                updatePassthroughTelemetry(scratch[0], chunk, sampleRate);
            } else {
                processChannelsCore(ptrs, numCh, chunk, targetWet);
                for (uint32_t i = 0; i < chunk; ++i) {
                    for (uint32_t c = 0; c < numCh; ++c) {
                        const float clamped = detail::clampf(scratch[c][i], -1.0f, 1.0f);
                        data[(offset + i) * numCh + c] = static_cast<int16_t>(std::lrintf(clamped * 32767.0f));
                    }
                }
            }
            offset += chunk;
        }
    }

    void syncRateAndParams(double sampleRate) noexcept {
        const double safeRate = (sampleRate >= 8000.0 && sampleRate <= 192000.0) ? sampleRate : sampleRate_;
        if (std::fabs(safeRate - sampleRate_) > 1.0) {
            prepare(safeRate);
        }

        const uint64_t s1 = paramSeq_.load(std::memory_order_acquire);
        if ((s1 & 1ULL) == 0ULL && s1 != lastParamSeq_) {
            const DSPParams candidate = stagingParams_;
            const uint64_t s2 = paramSeq_.load(std::memory_order_acquire);
            if (s1 == s2) {
                activeParams_ = candidate;
                lastParamSeq_ = s2;
                adaptiveTargetSemitones_ = activeParams_.pitch_semitones;
                updateFilterCoefficients(false);
            }
        }
    }

    // Estimates speaker's slow resting F0 on downsampled ~16 kHz ring without allocating memory.
    void trackSpeakerF0Sample(float sample, bool voicedGateOpen) noexcept {
        const uint32_t decimStep = std::max<uint32_t>(1, static_cast<uint32_t>(std::lrint(sampleRate_ / 16000.0)));
        if (++f0DecimCounter_ < decimStep) return;
        f0DecimCounter_ = 0;

        f0Buf_[f0WritePos_] = sample;
        f0WritePos_ = (f0WritePos_ + 1) & (detail::kPitchBufSize - 1);

        if (!voicedGateOpen || unvoicedRatio_ > 0.45f) return;
        if (++f0EvalCounter_ < 512) return; // Evaluate every ~32 ms
        f0EvalCounter_ = 0;

        const double effSr = sampleRate_ / static_cast<double>(decimStep);
        const uint32_t win = 320;
        const uint32_t minLag = std::max<uint32_t>(20, static_cast<uint32_t>(effSr / 320.0));
        const uint32_t maxLag = std::min<uint32_t>(380, static_cast<uint32_t>(effSr / 75.0));
        if (maxLag <= minLag + 4) return;

        // Normalized autocorrelation on most recent 320 downsampled samples
        float energy0 = 1.0e-9f;
        const int32_t base = static_cast<int32_t>(f0WritePos_);
        for (uint32_t k = 0; k < win; ++k) {
            const float x = f0Buf_[(base - 1 - static_cast<int32_t>(k)) & (detail::kPitchBufSize - 1)];
            energy0 += x * x;
        }
        if (energy0 < 0.002f) return;

        float bestCorr = 0.0f;
        uint32_t bestLag = 0;
        for (uint32_t lag = minLag; lag <= maxLag; lag += 2) {
            float num = 0.0f;
            float energyLag = 1.0e-9f;
            for (uint32_t k = 0; k < win; k += 2) {
                const float x = f0Buf_[(base - 1 - static_cast<int32_t>(k)) & (detail::kPitchBufSize - 1)];
                const float y = f0Buf_[(base - 1 - static_cast<int32_t>(k + lag)) & (detail::kPitchBufSize - 1)];
                num += x * y;
                energyLag += y * y;
            }
            const float corr = num / std::sqrt(energy0 * energyLag);
            if (corr > bestCorr) {
                bestCorr = corr;
                bestLag = lag;
            }
        }

        if (bestCorr < 0.68f || bestLag == 0) return;

        // Refine +-1 lag
        for (int32_t d = -1; d <= 1; ++d) {
            const uint32_t lag = static_cast<uint32_t>(static_cast<int32_t>(bestLag) + d);
            if (lag < minLag || lag > maxLag) continue;
            float num = 0.0f;
            float energyLag = 1.0e-9f;
            for (uint32_t k = 0; k < win; k += 2) {
                const float x = f0Buf_[(base - 1 - static_cast<int32_t>(k)) & (detail::kPitchBufSize - 1)];
                const float y = f0Buf_[(base - 1 - static_cast<int32_t>(k + lag)) & (detail::kPitchBufSize - 1)];
                num += x * y;
                energyLag += y * y;
            }
            const float corr = num / std::sqrt(energy0 * energyLag);
            if (corr > bestCorr) {
                bestCorr = corr;
                bestLag = lag;
            }
        }

        const float detectedHz = static_cast<float>(effSr / static_cast<double>(bestLag));
        if (detectedHz >= 75.0f && detectedHz <= 320.0f) {
            if (!hasDetectedSpeakerF0_) {
                speakerF0Hz_ = detectedHz;
                hasDetectedSpeakerF0_ = true;
            } else {
                // Reject sudden octave jumps (>1.65x or <0.6x) on single frames
                const float ratio = detectedHz / speakerF0Hz_;
                if (ratio > 0.62f && ratio < 1.62f) {
                    speakerF0Hz_ = speakerF0Hz_ * 0.90f + detectedHz * 0.10f;
                }
            }

            if (activeParams_.adaptive_pitch && activeParams_.target_f0_hz >= 65.0f) {
                const float rawSemis = 12.0f * std::log2(activeParams_.target_f0_hz / speakerF0Hz_);
                adaptiveTargetSemitones_ = detail::clampf(rawSemis, -11.5f, 11.5f);
            }
        }
    }

    void updateFilterCoefficients(bool force) noexcept {
        const float effPitch = activeParams_.adaptive_pitch ? adaptiveTargetSemitones_ : activeParams_.pitch_semitones;
        const float fShift = activeParams_.formant_shift;
        const float nat = activeParams_.naturalness;
        const float eqL = activeParams_.eq_low_db;
        const float eqM = activeParams_.eq_mid_db;
        const float eqH = activeParams_.eq_high_db;

        if (force ||
            std::fabs(effPitch - coeffPitch_) > 0.25f ||
            std::fabs(fShift - coeffFormant_) > 0.005f ||
            std::fabs(nat - coeffNat_) > 0.01f ||
            std::fabs(eqL - coeffEqLow_) > 0.02f ||
            std::fabs(eqM - coeffEqMid_) > 0.02f ||
            std::fabs(eqH - coeffEqHigh_) > 0.02f) {

            // True Vocal-Tract Formant Decoupling:
            // WSOLA time-domain pitch shifting scales formants by P = 2^(effPitch/12).
            // Compensate excess spectral warp E = log2(P / targetFormant) across 5 vocal bands
            // so pitching UP doesn't sound like a chipmunk and pitching DOWN stays clear.
            const float pitchScale = std::pow(2.0f, effPitch / 12.0f);
            const float targetFormant = detail::clampf(fShift, 0.72f, 1.38f);
            const float excessOctaves = std::log2(std::max(0.4f, pitchScale / targetFormant));
            const float formOctaves = std::log2(targetFormant);

            const float compLowDb  = detail::clampf(excessOctaves * 7.5f * nat - formOctaves * 3.0f, -7.5f, 7.5f);
            const float compF1Db   = detail::clampf(excessOctaves * 4.5f * nat - formOctaves * 2.5f, -6.5f, 6.5f);
            const float compF2Db   = detail::clampf(-excessOctaves * 3.2f * nat + formOctaves * 3.2f, -6.0f, 6.0f);
            const float compF3Db   = detail::clampf(-excessOctaves * 6.5f * nat + formOctaves * 3.8f, -7.5f, 7.5f);
            const float compAirDb  = detail::clampf(-excessOctaves * 3.5f * nat + formOctaves * 2.0f, -5.5f, 5.5f);

            formantCompLow_.setLowShelf(sampleRate_, 210.0f, compLowDb, 0.72f);
            formantCompF1_.setPeaking(sampleRate_, 520.0f * targetFormant, 0.95f, compF1Db);
            formantCompF2_.setPeaking(sampleRate_, 1550.0f * targetFormant, 0.95f, compF2Db);
            formantCompF3_.setPeaking(sampleRate_, 2950.0f * targetFormant, 1.05f, compF3Db);
            formantCompAir_.setHighShelf(sampleRate_, 5200.0f, compAirDb, 0.75f);

            eqLow_.setLowShelf(sampleRate_, 190.0f, eqL, 0.75f);
            eqMid_.setPeaking(sampleRate_, 1200.0f, 0.85f, eqM);
            eqHigh_.setHighShelf(sampleRate_, 4200.0f, eqH, 0.75f);

            coeffPitch_ = effPitch;
            coeffFormant_ = fShift;
            coeffNat_ = nat;
            coeffEqLow_ = eqL;
            coeffEqMid_ = eqM;
            coeffEqHigh_ = eqH;
        }
    }

    void updatePassthroughTelemetry(const float* ch0, uint32_t numFrames, double sampleRate) noexcept {
        float peak = 0.0f;
        for (uint32_t i = 0; i < numFrames; ++i) {
            peak = std::max(peak, std::fabs(ch0[i]));
        }
        const float db = detail::linearToDb(peak);
        telInputDb_.store(db, std::memory_order_relaxed);
        telOutputDb_.store(db, std::memory_order_relaxed);
        telSampleRate_.store(sampleRate, std::memory_order_relaxed);
        telGateOpen_.store(false, std::memory_order_relaxed);
        telProcessingActive_.store(false, std::memory_order_relaxed);
        telProcessedFrames_.fetch_add(numFrames, std::memory_order_relaxed);
    }

    void processChannelsCore(
        float* const* channels,
        uint32_t numChannels,
        uint32_t numFrames,
        float targetWet
    ) noexcept {
        const float sr = static_cast<float>(sampleRate_);
        const float wetCoeff = 1.0f - std::exp(-1.0f / (0.014f * sr));
        const float paramSmoothCoeff = 1.0f - std::exp(-1.0f / (0.045f * sr));

        // Gate envelope coefficients
        const float gateAtt = 1.0f - std::exp(-1.0f / (0.0025f * sr));
        const float gateRel = 1.0f - std::exp(-1.0f / (0.125f * sr));
        const float gateGainSmooth = 1.0f - std::exp(-1.0f / (0.008f * sr));
        const float gateOpenThresh = detail::dbToLinear(activeParams_.noise_gate_db);
        const float gateCloseThresh = gateOpenThresh * 0.631f;

        // Compressor constants
        const float compAtt = 1.0f - std::exp(-1.0f / (0.006f * sr));
        const float compRel = 1.0f - std::exp(-1.0f / (0.095f * sr));
        const float compThreshDb = activeParams_.compressor_threshold_db;
        const float compRatio = activeParams_.compressor_ratio;
        const float compSlope = 1.0f - (1.0f / compRatio);
        const float compMakeupDb = std::min(4.0f, std::max(0.0f, (-compThreshDb - 14.0f) * compSlope * 0.25f));
        const float compMakeupLin = detail::dbToLinear(compMakeupDb);

        // Limiter constants
        const float limCeiling = detail::dbToLinear(activeParams_.limiter_ceiling_db);
        const float limRel = 1.0f - std::exp(-1.0f / (0.045f * sr));

        // WSOLA grain window (~32 ms) & cross-correlation span (~12 ms)
        const float windowLen = detail::clampf(0.032f * sr, 512.0f, 2048.0f);
        const float searchSpan = detail::clampf(0.012f * sr, 128.0f, 640.0f);
        const uint32_t corrWin = static_cast<uint32_t>(detail::clampf(0.006f * sr, 64.0f, 256.0f));
        const float fricativeCoeff = std::exp(-detail::kTwoPi * 4400.0f / sr);
        const float envBandCoeff = 1.0f - std::exp(-1.0f / (0.008f * sr));

        float inPeak = 0.0f;
        float outPeak = 0.0f;

        const float goalPitch = activeParams_.adaptive_pitch ? adaptiveTargetSemitones_ : activeParams_.pitch_semitones;
        updateFilterCoefficients(false);

        for (uint32_t i = 0; i < numFrames; ++i) {
            wetMix_ += (targetWet - wetMix_) * wetCoeff;
            smoothPitch_ += (goalPitch - smoothPitch_) * paramSmoothCoeff;

            const float pitchRatio = std::pow(2.0f, smoothPitch_ / 12.0f);
            const float delayStep = (1.0f - pitchRatio) / windowLen;
            const bool bypassPitch = std::fabs(smoothPitch_) < 0.05f;
            const float nat = activeParams_.naturalness;

            float monoEnvSample = 0.0f;
            float dryInputs[detail::kMaxChannels] = {0.0f, 0.0f};
            float hpfSamples[detail::kMaxChannels] = {0.0f, 0.0f};

            for (uint32_t c = 0; c < numChannels; ++c) {
                const float dry = channels[c][i];
                dryInputs[c] = dry;
                inPeak = std::max(inPeak, std::fabs(dry));

                const float clean = hpfFilter_.process(dry, c);
                hpfSamples[c] = clean;
                monoEnvSample = std::max(monoEnvSample, std::fabs(clean));
            }

            // Noise Gate (hysteresis + soft floor)
            const float gCoeff = (monoEnvSample > gateEnvelope_) ? gateAtt : gateRel;
            gateEnvelope_ += (monoEnvSample - gateEnvelope_) * gCoeff;
            if (gateOpenState_) {
                if (gateEnvelope_ < gateCloseThresh) gateOpenState_ = false;
            } else {
                if (gateEnvelope_ >= gateOpenThresh) gateOpenState_ = true;
            }
            const float targetGateGain = gateOpenState_ ? 1.0f : 0.01f;
            gateGain_ += (targetGateGain - gateGain_) * gateGainSmooth;

            // Track adaptive speaker pitch slowly on clean channel 0
            trackSpeakerF0Sample(hpfSamples[0] * gateGain_, gateOpenState_);

            float stageSignals[detail::kMaxChannels] = {0.0f, 0.0f};
            float postEqPeak = 0.0f;

            for (uint32_t c = 0; c < numChannels; ++c) {
                detail::PitchChannelState& ps = pitchState_[c];
                const float gated = hpfSamples[c] * gateGain_;

                // High-band sibilance extraction (> 4.4 kHz)
                const float hi = fricativeCoeff * (ps.fricativeHpState + gated - ps.prevIn);
                ps.fricativeHpState = hi;
                ps.prevIn = gated;

                if (c == 0) {
                    const float lo = gated - hi;
                    lowBandEnv_ += (std::fabs(lo) - lowBandEnv_) * envBandCoeff;
                    highBandEnv_ += (std::fabs(hi) - highBandEnv_) * envBandCoeff;
                    const float hfRatio = highBandEnv_ / std::max(1.0e-5f, lowBandEnv_ + highBandEnv_);
                    unvoicedRatio_ = detail::clampf((hfRatio - 0.28f) * 2.8f, 0.0f, 1.0f);
                }

                ps.ring[ps.writePos] = gated;
                ps.writePos = (ps.writePos + 1) & detail::kRingMask;

                float pitched = gated;
                if (!bypassPitch) {
                    if (c == 0) {
                        ps.prevPhaseA = ps.phaseA;
                        ps.phaseA += delayStep;
                        if (ps.phaseA >= 1.0f || ps.phaseA < 0.0f) {
                            ps.phaseA -= std::floor(ps.phaseA);
                        }
                    } else {
                        ps.prevPhaseA = pitchState_[0].prevPhaseA;
                        ps.phaseA = pitchState_[0].phaseA;
                    }

                    const float pA = ps.phaseA;
                    const float pB = (pA + 0.5f >= 1.0f) ? (pA - 0.5f) : (pA + 0.5f);
                    const float prevPA = ps.prevPhaseA;
                    const float prevPB = (prevPA + 0.5f >= 1.0f) ? (prevPA - 0.5f) : (prevPA + 0.5f);

                    // Trigger WSOLA phase-alignment ONLY when a tap crosses 0 (where its Hann weight is 0 -> click-free!)
                    const bool wrappedA = (delayStep >= 0.0f) ? (pA < prevPA) : (pA > prevPA);
                    const bool wrappedB = (delayStep >= 0.0f) ? (pB < prevPB) : (pB > prevPB);

                    const float baseDelay = 24.0f + searchSpan * 0.5f;
                    if (wrappedA) {
                        if (c == 0) {
                            const float nomA = baseDelay + pA * windowLen;
                            const float curB = baseDelay + pB * windowLen + ps.phaseOffsetB;
                            ps.phaseOffsetA = ps.findBestWsolaOffset(nomA, curB, searchSpan, corrWin);
                        } else {
                            ps.phaseOffsetA = pitchState_[0].phaseOffsetA;
                        }
                    }
                    if (wrappedB) {
                        if (c == 0) {
                            const float nomB = baseDelay + pB * windowLen;
                            const float curA = baseDelay + pA * windowLen + ps.phaseOffsetA;
                            ps.phaseOffsetB = ps.findBestWsolaOffset(nomB, curA, searchSpan, corrWin);
                        } else {
                            ps.phaseOffsetB = pitchState_[0].phaseOffsetB;
                        }
                    }

                    const float dA = baseDelay + pA * windowLen + ps.phaseOffsetA;
                    const float dB = baseDelay + pB * windowLen + ps.phaseOffsetB;

                    const float wA = 0.5f * (1.0f - std::cos(detail::kTwoPi * pA));
                    const float wB = 0.5f * (1.0f - std::cos(detail::kTwoPi * pB));

                    const float sA = ps.readHermite(dA);
                    const float sB = ps.readHermite(dB);
                    // Preserve crisp unvoiced sibilance ('s', 'x', 'ch', 't') without metallic vowel bleed
                    const float unvoicedAir = hi * (nat * 0.42f * unvoicedRatio_);
                    pitched = (sA * wA + sB * wB) + unvoicedAir;
                }

                // 5-band vocal-tract formant decoupling + 3-band EQ
                float shaped = formantCompLow_.process(pitched, c);
                shaped = formantCompF1_.process(shaped, c);
                shaped = formantCompF2_.process(shaped, c);
                shaped = formantCompF3_.process(shaped, c);
                shaped = formantCompAir_.process(shaped, c);

                shaped = eqLow_.process(shaped, c);
                shaped = eqMid_.process(shaped, c);
                shaped = eqHigh_.process(shaped, c);

                stageSignals[c] = shaped;
                postEqPeak = std::max(postEqPeak, std::fabs(shaped));
            }

            // Soft-Knee Dynamic Compressor
            const float cCoeff = (postEqPeak > compEnvelope_) ? compAtt : compRel;
            compEnvelope_ += (postEqPeak - compEnvelope_) * cCoeff;
            const float envDb = detail::linearToDb(compEnvelope_);
            constexpr float kKnee = 6.0f;
            float compGainDb = 0.0f;
            if (2.0f * (envDb - compThreshDb) < -kKnee) {
                compGainDb = 0.0f;
            } else if (2.0f * std::fabs(envDb - compThreshDb) <= kKnee) {
                const float x = envDb - compThreshDb + kKnee * 0.5f;
                compGainDb = -compSlope * (x * x) / (2.0f * kKnee);
            } else {
                compGainDb = -compSlope * (envDb - compThreshDb);
            }
            const float compLin = detail::dbToLinear(compGainDb) * compMakeupLin;

            float compPeak = 0.0f;
            for (uint32_t c = 0; c < numChannels; ++c) {
                stageSignals[c] *= compLin;
                const float x = stageSignals[c];
                stageSignals[c] = (std::fabs(x) > 0.72f)
                    ? (0.72f * (x >= 0.0f ? 1.0f : -1.0f) + 0.28f * std::tanh((x - (x >= 0.0f ? 0.72f : -0.72f)) / 0.28f))
                    : x;
                compPeak = std::max(compPeak, std::fabs(stageSignals[c]));
            }

            const float reqLimGain = (compPeak > limCeiling) ? (limCeiling / compPeak) : 1.0f;
            if (reqLimGain < limiterGain_) {
                limiterGain_ = reqLimGain;
            } else {
                limiterGain_ += (1.0f - limiterGain_) * limRel;
            }

            for (uint32_t c = 0; c < numChannels; ++c) {
                const float wetOut = detail::clampf(stageSignals[c] * limiterGain_, -limCeiling, limCeiling);
                const float finalOut = dryInputs[c] * (1.0f - wetMix_) + wetOut * wetMix_;
                channels[c][i] = finalOut;
                outPeak = std::max(outPeak, std::fabs(finalOut));
            }
        }

        telInputDb_.store(detail::linearToDb(inPeak), std::memory_order_relaxed);
        telOutputDb_.store(detail::linearToDb(outPeak), std::memory_order_relaxed);
        telSampleRate_.store(sampleRate_, std::memory_order_relaxed);
        telSpeakerF0_.store(hasDetectedSpeakerF0_ ? speakerF0Hz_ : 0.0f, std::memory_order_relaxed);
        telEffPitch_.store(smoothPitch_, std::memory_order_relaxed);
        telGateOpen_.store(gateOpenState_, std::memory_order_relaxed);
        telProcessingActive_.store(targetWet > 0.5f, std::memory_order_relaxed);
        telProcessedFrames_.fetch_add(numFrames, std::memory_order_relaxed);
    }

    double sampleRate_ = 48000.0;

    std::atomic<uint64_t> paramSeq_{0};
    uint64_t lastParamSeq_ = 0;
    DSPParams stagingParams_{};
    DSPParams activeParams_{};

    std::atomic<bool> atomicEnabled_{false};
    std::atomic<bool> atomicLockedBypass_{true};

    detail::Biquad hpfFilter_;
    detail::Biquad formantCompLow_;
    detail::Biquad formantCompF1_;
    detail::Biquad formantCompF2_;
    detail::Biquad formantCompF3_;
    detail::Biquad formantCompAir_;
    detail::Biquad eqLow_;
    detail::Biquad eqMid_;
    detail::Biquad eqHigh_;
    detail::PitchChannelState pitchState_[detail::kMaxChannels];

    float f0Buf_[detail::kPitchBufSize] = {0.0f};
    uint32_t f0WritePos_ = 0;
    uint32_t f0DecimCounter_ = 0;
    uint32_t f0EvalCounter_ = 0;
    float speakerF0Hz_ = 145.0f;
    bool hasDetectedSpeakerF0_ = false;
    float adaptiveTargetSemitones_ = 0.0f;
    float unvoicedRatio_ = 0.0f;
    float lowBandEnv_ = 0.0f;
    float highBandEnv_ = 0.0f;

    float coeffPitch_ = -999.0f;
    float coeffFormant_ = -999.0f;
    float coeffNat_ = -999.0f;
    float coeffEqLow_ = -999.0f;
    float coeffEqMid_ = -999.0f;
    float coeffEqHigh_ = -999.0f;

    float gateEnvelope_ = 0.0f;
    float gateGain_ = 1.0f;
    bool gateOpenState_ = false;
    float compEnvelope_ = 0.0f;
    float limiterGain_ = 1.0f;
    float wetMix_ = 0.0f;
    float smoothPitch_ = 0.0f;

    std::atomic<float> telInputDb_{-96.0f};
    std::atomic<float> telOutputDb_{-96.0f};
    std::atomic<double> telSampleRate_{48000.0};
    std::atomic<float> telSpeakerF0_{0.0f};
    std::atomic<float> telEffPitch_{0.0f};
    std::atomic<bool> telGateOpen_{false};
    std::atomic<bool> telProcessingActive_{false};
    std::atomic<uint64_t> telProcessedFrames_{0};
};

} // namespace dsp
} // namespace phl
