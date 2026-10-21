#include "RealtimeDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// No atomics that may call into a lock-based runtime are allowed in the IOProc.
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit atomics must be lock-free");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");
_Static_assert(sizeof(float) == sizeof(uint32_t), "32-bit float is required");

struct MVRenderState {
    uint32_t inputChannelOffset;
    uint32_t outputChannelCount;
    double smoothingCoefficient;
    double smoothedGain; // Only touched by the serial device callback.
    _Atomic(uint32_t) targetGainBits;
    _Atomic(uint32_t) inputPeakBits;
    _Atomic(uint32_t) outputPeakBits;
    _Atomic(unsigned long long) limitedFrames;
    _Atomic(unsigned long long) callbackCount;
    _Atomic(unsigned long long) invalidBuffers;
};

enum { MVMaxBuffers = 64, MVMaxChannels = 4096 };

typedef struct {
    float *samples;
    uint32_t stride;
    uint32_t frames;
} MVChannel;

static uint32_t float_bits(float value) {
    uint32_t result;
    memcpy(&result, &value, sizeof(result));
    return result;
}

static float bits_float(uint32_t value) {
    float result;
    memcpy(&result, &value, sizeof(result));
    return result;
}

static float safe_gain(float gain) {
    if (!isfinite(gain) || gain < 0.0f) return 0.0f;
    return gain > 4.0f ? 4.0f : gain;
}

MVRenderState *MVRenderStateCreate(double sampleRate,
                                 uint32_t inputChannelOffset,
                                 uint32_t outputChannelCount,
                                 float initialGain) {
    if (!isfinite(sampleRate) || sampleRate < 1.0 ||
        inputChannelOffset > MVMaxChannels - 2 ||
        (outputChannelCount != 1 && outputChannelCount != 2)) return NULL;
    MVRenderState *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->inputChannelOffset = inputChannelOffset;
    state->outputChannelCount = outputChannelCount;
    state->smoothingCoefficient = 1.0 - exp(-1.0 / (0.005 * sampleRate));
    state->smoothedGain = safe_gain(initialGain);
    atomic_init(&state->targetGainBits, float_bits((float)state->smoothedGain));
    atomic_init(&state->inputPeakBits, float_bits(0));
    atomic_init(&state->outputPeakBits, float_bits(0));
    atomic_init(&state->limitedFrames, 0);
    atomic_init(&state->callbackCount, 0);
    atomic_init(&state->invalidBuffers, 0);
    return state;
}

void MVRenderStateDestroy(MVRenderState *state) { free(state); }

void MVRenderSetGain(MVRenderState *state, float gain) {
    if (state) atomic_store_explicit(&state->targetGainBits,
                                     float_bits(safe_gain(gain)), memory_order_relaxed);
}

MVRenderMetrics MVRenderReadMetrics(const MVRenderState *state) {
    MVRenderMetrics result = {0};
    if (!state) return result;
    result.inputPeak = bits_float(atomic_load_explicit(&state->inputPeakBits, memory_order_relaxed));
    result.outputPeak = bits_float(atomic_load_explicit(&state->outputPeakBits, memory_order_relaxed));
    result.limitedFrames = atomic_load_explicit(&state->limitedFrames, memory_order_relaxed);
    result.callbackCount = atomic_load_explicit(&state->callbackCount, memory_order_relaxed);
    result.invalidBuffers = atomic_load_explicit(&state->invalidBuffers, memory_order_relaxed);
    return result;
}

static bool find_channel(const AudioBufferList *list, uint32_t channel, MVChannel *result) {
    if (!list || list->mNumberBuffers == 0 || list->mNumberBuffers > MVMaxBuffers) return false;
    for (uint32_t b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        uint32_t channels = buffer->mNumberChannels;
        if (channels == 0 || channels > MVMaxChannels) return false;
        if (channel >= channels) {
            channel -= channels;
            continue;
        }
        uint32_t strideBytes = channels * (uint32_t)sizeof(float);
        if (buffer->mDataByteSize % strideBytes != 0 ||
            (buffer->mDataByteSize != 0 && !buffer->mData)) return false;
        result->samples = buffer->mData ? (float *)buffer->mData + channel : NULL;
        result->stride = channels;
        result->frames = buffer->mDataByteSize / strideBytes;
        return true;
    }
    return false;
}

static bool clear_output(AudioBufferList *output, uint32_t *frames) {
    if (!output || output->mNumberBuffers == 0 || output->mNumberBuffers > MVMaxBuffers) return false;
    bool valid = true;
    *frames = 0;
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (buffer->mData && buffer->mDataByteSize) memset(buffer->mData, 0, buffer->mDataByteSize);
        uint32_t channels = buffer->mNumberChannels;
        if (channels == 0 || channels > MVMaxChannels ||
            (buffer->mDataByteSize && !buffer->mData)) {
            valid = false;
            continue;
        }
        uint32_t strideBytes = channels * (uint32_t)sizeof(float);
        uint32_t currentFrames = buffer->mDataByteSize / strideBytes;
        if (buffer->mDataByteSize % strideBytes != 0) valid = false;
        if (b == 0) *frames = currentFrames;
        else if (currentFrames != *frames) valid = false;
    }
    return valid;
}

static OSStatus invalid_callback(MVRenderState *state) {
    if (state) {
        atomic_fetch_add_explicit(&state->invalidBuffers, 1, memory_order_relaxed);
        atomic_store_explicit(&state->inputPeakBits, float_bits(0), memory_order_relaxed);
        atomic_store_explicit(&state->outputPeakBits, float_bits(0), memory_order_relaxed);
    }
    return noErr;
}

OSStatus MVAudioIOProc(AudioObjectID device,
                      const AudioTimeStamp *now,
                      const AudioBufferList *input,
                      const AudioTimeStamp *inputTime,
                      AudioBufferList *output,
                      const AudioTimeStamp *outputTime,
                      void *clientData) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    MVRenderState *state = clientData;
    if (state) atomic_fetch_add_explicit(&state->callbackCount, 1, memory_order_relaxed);
    uint32_t frames;
    bool outputValid = clear_output(output, &frames);
    if (!state || !outputValid) return invalid_callback(state);

    MVChannel left, right, outLeft, outRight;
    if (!find_channel(input, state->inputChannelOffset, &left) ||
        !find_channel(input, state->inputChannelOffset + 1, &right) ||
        !find_channel(output, 0, &outLeft) ||
        (state->outputChannelCount == 2 && !find_channel(output, 1, &outRight)) ||
        left.frames != frames || right.frames != frames) return invalid_callback(state);

    // Validate before writing so a late NaN cannot leave a partially rendered block.
    float inputPeak = 0;
    for (uint32_t f = 0; f < frames; ++f) {
        float l = left.samples[(size_t)f * left.stride];
        float r = right.samples[(size_t)f * right.stride];
        if (!isfinite(l) || !isfinite(r)) return invalid_callback(state);
        inputPeak = fmaxf(inputPeak, fmaxf(fabsf(l), fabsf(r)));
    }

    double gain = state->smoothedGain;
    double target = bits_float(atomic_load_explicit(&state->targetGainBits, memory_order_relaxed));
    float outputPeak = 0;
    uint64_t limited = 0;
    for (uint32_t f = 0; f < frames; ++f) {
        gain += (target - gain) * state->smoothingCoefficient;
        if (fabs(target - gain) < 1e-8) gain = target;
        double l = (double)left.samples[(size_t)f * left.stride] * gain;
        double r = (double)right.samples[(size_t)f * right.stride] * gain;
        if (state->outputChannelCount == 1) l = r = (l + r) * 0.5;
        double peak = fmax(fabs(l), fabs(r));
        if (peak > 0.9) {
            // Smoothly approach 0.98 without a hard corner. One scale factor for
            // both channels preserves the stereo image and relative polarity.
            double ceiling = 0.9 + 0.08 * tanh((peak - 0.9) / 0.08);
            double scale = ceiling / peak;
            l *= scale;
            r *= scale;
            ++limited;
        }
        outLeft.samples[(size_t)f * outLeft.stride] = (float)l;
        if (state->outputChannelCount == 2) outRight.samples[(size_t)f * outRight.stride] = (float)r;
        outputPeak = fmaxf(outputPeak, (float)fmax(fabs(l), fabs(r)));
    }
    state->smoothedGain = gain;
    atomic_store_explicit(&state->inputPeakBits, float_bits(inputPeak), memory_order_relaxed);
    atomic_store_explicit(&state->outputPeakBits, float_bits(outputPeak), memory_order_relaxed);
    atomic_fetch_add_explicit(&state->limitedFrames, limited, memory_order_relaxed);
    return noErr;
}
