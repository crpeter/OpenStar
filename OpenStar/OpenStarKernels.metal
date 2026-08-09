//
//  OpenStarKernels.metal
//  OpenStar
//

#include <metal_stdlib>
using namespace metal;

kernel void openStarLombScargle(
    device const float *times [[buffer(0)]],
    device const float *flux [[buffer(1)]],
    device float *powers [[buffer(2)]],
    constant uint &sampleCount [[buffer(3)]],
    constant float &startFrequency [[buffer(4)]],
    constant float &frequencyStep [[buffer(5)]],
    uint id [[thread_position_in_grid]]
) {
    constexpr float twoPi = 6.28318530717958647692f;

    float frequency =
        startFrequency +
        float(id) * frequencyStep;

    float omega = twoPi * frequency;

    float sumSin2 = 0.0f;
    float sumCos2 = 0.0f;

    for (uint sample = 0; sample < sampleCount; ++sample) {
        float angle = 2.0f * omega * times[sample];

        sumSin2 += sin(angle);
        sumCos2 += cos(angle);
    }

    float tau = 0.0f;

    if (omega > 0.0f) {
        tau =
            atan2(sumSin2, sumCos2) /
            (2.0f * omega);
    }

    float sumYCos = 0.0f;
    float sumYSin = 0.0f;

    float sumCosSquared = 0.0f;
    float sumSinSquared = 0.0f;

    float totalFluxSquared = 0.0f;

    for (uint sample = 0; sample < sampleCount; ++sample) {
        float shiftedTime =
            times[sample] - tau;

        float angle =
            omega * shiftedTime;

        float cosine = cos(angle);
        float sine = sin(angle);
        float value = flux[sample];

        sumYCos += value * cosine;
        sumYSin += value * sine;

        sumCosSquared += cosine * cosine;
        sumSinSquared += sine * sine;

        totalFluxSquared += value * value;
    }

    if (
        sumCosSquared <= 0.0f ||
        sumSinSquared <= 0.0f ||
        totalFluxSquared <= 0.0f
    ) {
        powers[id] = 0.0f;
        return;
    }

    float cosinePower =
        (sumYCos * sumYCos) /
        sumCosSquared;

    float sinePower =
        (sumYSin * sumYSin) /
        sumSinSquared;

    powers[id] =
        (cosinePower + sinePower) /
        totalFluxSquared;
}
