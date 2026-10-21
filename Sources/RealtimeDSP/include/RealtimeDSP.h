#ifndef REALTIME_DSP_H
#define REALTIME_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MVRenderState MVRenderState;

typedef struct {
    float inputPeak;
    float outputPeak;
    uint64_t limitedFrames;
    uint64_t callbackCount;
    uint64_t invalidBuffers;
} MVRenderMetrics;

/// Create off the audio thread. The tap supplies two Float32 channels beginning
/// at inputChannelOffset; outputChannelCount must be 1 (stereo average) or 2.
/// The initial gain is clamped to 0...4. Non-finite gain means silence.
MVRenderState * _Nullable MVRenderStateCreate(double sampleRate,
                                 uint32_t inputChannelOffset,
                                 uint32_t outputChannelCount,
                                 float initialGain);

/// Call only after the IOProc has stopped and has been destroyed.
void MVRenderStateDestroy(MVRenderState * _Nullable state);

/// Lock-free; gain changes are smoothed with a 5 ms time constant.
void MVRenderSetGain(MVRenderState * _Nullable state, float gain);

/// Lock-free snapshot. Peaks belong to the latest callback; counters are cumulative.
/// Fields are independently atomic, so this is not a transactional snapshot.
MVRenderMetrics MVRenderReadMetrics(const MVRenderState * _Nullable state);

/// Allocation-free Float32 IOProc, suitable for AudioDeviceCreateIOProcID.
/// Each ABL may be interleaved, planar, or a combination of both. Other output
/// channels are cleared. Malformed buffers or non-finite tap samples silence the
/// whole callback and increment invalidBuffers. The caller validates ASBDs first.
OSStatus MVAudioIOProc(AudioObjectID device,
                      const AudioTimeStamp * _Nonnull now,
                      const AudioBufferList * _Nonnull input,
                      const AudioTimeStamp * _Nonnull inputTime,
                      AudioBufferList * _Nonnull output,
                      const AudioTimeStamp * _Nonnull outputTime,
                      void * _Nullable clientData);

#ifdef __cplusplus
}
#endif
#endif
