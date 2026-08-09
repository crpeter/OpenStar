//
//  OpenStarKernels.metal
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

#include <metal_stdlib>
using namespace metal;

kernel void openStarBenchmark(
    device const float *input [[buffer(0)]],
    device float *output [[buffer(1)]],
    constant uint &iterationCount [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    float value = input[id];

    for (
        uint iteration = 0;
        iteration < iterationCount;
        ++iteration
    ) {
        value = fma(
            value,
            1.0000001f,
            0.0000002f
        );

        value = fma(
            value,
            0.9999999f,
            0.0000001f
        );
    }

    output[id] = value;
}
