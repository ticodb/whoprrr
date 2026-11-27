#include "MixerDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(__atomic_always_lock_free(sizeof(float), 0), "Gain targets must be lock-free");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "Mixer flags must be lock-free");

void whoprrr_gain_target(WhoprrrGainRamp *ramp, float target, uint32_t frames) {
    if (ramp->target == target) return;
    ramp->target = target;
    ramp->remaining = frames;
    ramp->step = frames ? (target - ramp->gain) / (float)frames : 0;
    if (!frames) ramp->gain = target;
}

float whoprrr_gain_next(WhoprrrGainRamp *ramp) {
    if (ramp->remaining && --ramp->remaining) ramp->gain += ramp->step;
    else ramp->gain = ramp->target;
    return ramp->gain;
}

void whoprrr_mix_add(float *left, float *right, const float *sourceLeft, const float *sourceRight,
                     uint32_t stride, uint32_t frames, WhoprrrGainRamp *ramp) {
    for (uint32_t i = 0; i < frames; i++) {
        float gain = whoprrr_gain_next(ramp);
        if (gain != 0) {
            left[i] += sourceLeft[i * stride] * gain;
            right[i] += sourceRight[i * stride] * gain;
        }
    }
}

typedef struct {
    WhoprrrTapStream stream;
    _Atomic(float) target;
    WhoprrrGainRamp ramp;
} MixerChannel;

struct WhoprrrMixer {
    uint32_t count;
    uint32_t inputBuffers;
    uint32_t rampFrames;
    _Atomic(float) masterTarget;
    _Atomic(float) peak;
    atomic_bool faded;
    atomic_bool badLayout;
    WhoprrrGainRamp master;
    MixerChannel channels[];
};

WhoprrrMixer *whoprrr_mixer_create(const WhoprrrTapStream *streams, uint32_t count, uint32_t inputBuffers,
                                  uint32_t rampFrames, bool fadeIn) {
    WhoprrrMixer *mixer = calloc(1, sizeof(*mixer) + count * sizeof(MixerChannel));
    if (!mixer) return NULL;
    mixer->count = count;
    mixer->inputBuffers = inputBuffers;
    mixer->rampFrames = rampFrames;
    atomic_init(&mixer->masterTarget, 1);
    atomic_init(&mixer->peak, 0);
    atomic_init(&mixer->faded, false);
    atomic_init(&mixer->badLayout, false);
    float start = fadeIn ? 0 : 1;
    mixer->master = (WhoprrrGainRamp){.gain = start, .target = start};
    for (uint32_t i = 0; i < count; i++) {
        MixerChannel *channel = &mixer->channels[i];
        channel->stream = streams[i];
        channel->ramp = (WhoprrrGainRamp){.gain = streams[i].gain, .target = streams[i].gain};
        atomic_init(&channel->target, streams[i].gain);
    }
    return mixer;
}

void whoprrr_mixer_destroy(WhoprrrMixer *mixer) { free(mixer); }

void whoprrr_mixer_set_gain(WhoprrrMixer *mixer, uint32_t index, float gain) {
    if (index < mixer->count) atomic_store_explicit(&mixer->channels[index].target, gain, memory_order_relaxed);
}

void whoprrr_mixer_fade_out(WhoprrrMixer *mixer) {
    atomic_store_explicit(&mixer->masterTarget, 0, memory_order_relaxed);
}

bool whoprrr_mixer_is_faded_out(const WhoprrrMixer *mixer) {
    return atomic_load_explicit(&mixer->faded, memory_order_relaxed);
}

bool whoprrr_mixer_layout_failed(const WhoprrrMixer *mixer) {
    return atomic_load_explicit(&mixer->badLayout, memory_order_relaxed);
}

static uint32_t buffer_frames(const AudioBuffer *left, const AudioBuffer *right,
                              uint32_t stride, uint32_t capacity) {
    uint32_t bytes = left->mDataByteSize < right->mDataByteSize ? left->mDataByteSize : right->mDataByteSize;
    uint32_t frames = bytes / (stride * sizeof(float));
    return frames < capacity ? frames : capacity;
}

static void skip_frames(WhoprrrGainRamp *ramp, uint32_t frames) {
    if (frames >= ramp->remaining) {
        ramp->gain = ramp->target;
        ramp->remaining = 0;
    } else {
        ramp->gain += ramp->step * (float)frames;
        ramp->remaining -= frames;
    }
}

uint32_t whoprrr_mixer_sum(WhoprrrMixer *mixer, const AudioBufferList *input,
                           float *left, float *right, uint32_t capacity) {
    if (input->mNumberBuffers != mixer->inputBuffers) {
        atomic_store_explicit(&mixer->badLayout, true, memory_order_relaxed);
        return 0;
    }
    uint32_t frames = 0;
    for (uint32_t i = 0; i < mixer->count; i++) {
        WhoprrrTapStream stream = mixer->channels[i].stream;
        const AudioBuffer *l = &input->mBuffers[stream.firstBuffer];
        const AudioBuffer *r = stream.planar ? l + 1 : l;
        uint32_t stride = stream.planar ? 1 : 2;
        if (l->mNumberChannels != stride || r->mNumberChannels != stride) {
            atomic_store_explicit(&mixer->badLayout, true, memory_order_relaxed);
            return 0;
        }
        uint32_t available = buffer_frames(l, r, stride, capacity);
        if (available > frames) frames = available;
    }

    memset(left, 0, frames * sizeof(float));
    memset(right, 0, frames * sizeof(float));
    for (uint32_t i = 0; i < mixer->count; i++) {
        MixerChannel *channel = &mixer->channels[i];
        WhoprrrTapStream stream = channel->stream;
        const AudioBuffer *l = &input->mBuffers[stream.firstBuffer];
        const AudioBuffer *r = stream.planar ? l + 1 : l;
        uint32_t stride = stream.planar ? 1 : 2;
        uint32_t available = (l->mData && r->mData) ? buffer_frames(l, r, stride, frames) : 0;
        whoprrr_gain_target(&channel->ramp, atomic_load_explicit(&channel->target, memory_order_relaxed),
                            mixer->rampFrames);
        if (available) {
            const float *sourceRight = (const float *)r->mData + (stream.planar ? 0 : 1);
            whoprrr_mix_add(left, right, l->mData, sourceRight, stride, available, &channel->ramp);
        }
        skip_frames(&channel->ramp, frames - available);
    }
    return frames;
}

void whoprrr_mixer_finish(WhoprrrMixer *mixer, float *left, float *right, uint32_t frames) {
    float target = atomic_load_explicit(&mixer->masterTarget, memory_order_relaxed);
    whoprrr_gain_target(&mixer->master, target, mixer->rampFrames);
    if (mixer->master.remaining || target != 1) {
        for (uint32_t i = 0; i < frames; i++) {
            float gain = whoprrr_gain_next(&mixer->master);
            left[i] *= gain;
            right[i] *= gain;
        }
    }
    if (!mixer->master.remaining && target == 0) atomic_store_explicit(&mixer->faded, true, memory_order_relaxed);
}

void whoprrr_mixer_measure(WhoprrrMixer *mixer, const float *left, const float *right, uint32_t frames) {
    float peak = 0;
    for (uint32_t i = 0; i < frames; i++) peak = fmaxf(peak, fmaxf(fabsf(left[i]), fabsf(right[i])));
    float previous = atomic_load_explicit(&mixer->peak, memory_order_relaxed);
    if (peak > previous) {
        // The meter can only reset this value to zero. There is just one audio writer.
        atomic_store_explicit(&mixer->peak, peak, memory_order_relaxed);
    }
}

float whoprrr_mixer_take_peak(WhoprrrMixer *mixer) {
    return atomic_exchange_explicit(&mixer->peak, 0, memory_order_relaxed);
}
