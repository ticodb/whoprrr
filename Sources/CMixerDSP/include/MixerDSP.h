#ifndef WHOPRRR_MIXER_DSP_H
#define WHOPRRR_MIXER_DSP_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    float gain;
    float target;
    float step;
    uint32_t remaining;
} WhoprrrGainRamp;

void whoprrr_gain_target(WhoprrrGainRamp *ramp, float target, uint32_t frames);
float whoprrr_gain_next(WhoprrrGainRamp *ramp);
void whoprrr_mix_add(float *left, float *right, const float *sourceLeft, const float *sourceRight,
                     uint32_t stride, uint32_t frames, WhoprrrGainRamp *ramp);

typedef struct WhoprrrMixer WhoprrrMixer;

// Each stereo tap occupies either one interleaved buffer or two mono buffers in the input list.
typedef struct {
    uint32_t firstBuffer;
    bool planar;
    float gain;
} WhoprrrTapStream;

WhoprrrMixer *whoprrr_mixer_create(const WhoprrrTapStream *streams, uint32_t count, uint32_t inputBuffers,
                                  uint32_t rampFrames, bool fadeIn);
void whoprrr_mixer_destroy(WhoprrrMixer *mixer);
void whoprrr_mixer_set_gain(WhoprrrMixer *mixer, uint32_t index, float gain);
void whoprrr_mixer_fade_out(WhoprrrMixer *mixer);
bool whoprrr_mixer_is_faded_out(const WhoprrrMixer *mixer);
bool whoprrr_mixer_layout_failed(const WhoprrrMixer *mixer);
uint32_t whoprrr_mixer_sum(WhoprrrMixer *mixer, const AudioBufferList *input,
                           float *left, float *right, uint32_t capacity);
void whoprrr_mixer_finish(WhoprrrMixer *mixer, float *left, float *right, uint32_t frames);
bool whoprrr_mixer_measure(WhoprrrMixer *mixer, const float *left, const float *right, uint32_t frames);
float whoprrr_mixer_take_peak(WhoprrrMixer *mixer);
void whoprrr_mixer_measure_output(WhoprrrMixer *mixer, const float *left, const float *right, uint32_t frames);
float whoprrr_mixer_take_output_peak(WhoprrrMixer *mixer);

#endif
