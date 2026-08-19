import Foundation

/// The Metal compute kernels, embedded as source and compiled at runtime.
///
/// ## Why embedded rather than a resource
///
/// SwiftPM does not reliably compile a `.metal` file listed under `resources:`
/// into a `default.metallib`; it copies the source verbatim, and
/// `makeDefaultLibrary()` then finds nothing. Embedding the source removes the
/// build-system dependency entirely, and it also means a `stressd` binary
/// copied to `/usr/local/bin` works without a resource bundle beside it.
///
/// Compilation costs roughly a tenth of a second, once, at first GPU use.
enum GPUShaderSource {
  static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    // Synthetic GPU load kernels.
    //
    // Three profiles with deliberately different bottlenecks, because "GPU load"
    // is not one thing: a shader that saturates the ALUs draws power very
    // differently from one that saturates the memory controller.
    //
    // Every kernel writes its result to a buffer the host reads back, so nothing
    // here can be optimised away.

    /// Fused multiply-add on registers. Almost no memory traffic.
    ///
    /// Same reasoning as the CPU kernel: a symplectic rotation has unit
    /// determinant, so the state orbits forever without overflowing, denormalising,
    /// or settling on a constant the compiler could fold.
    kernel void stressd_alu(device float *output [[buffer(0)]],
                            constant uint &iterations [[buffer(1)]],
                            uint gid [[thread_position_in_grid]]) {
      float x0 = 1.0f + (float)(gid % 97) * 1e-4f;
      float y0 = 0.5f + (float)(gid % 89) * 1e-4f;
      float x1 = 1.5f + (float)(gid % 83) * 1e-4f;
      float y1 = 0.25f + (float)(gid % 79) * 1e-4f;
      const float s = 1e-3f;

      for (uint i = 0; i < iterations; ++i) {
        x0 = fma(y0, -s, x0);
        y0 = fma(x0, s, y0);
        x1 = fma(y1, -s, x1);
        y1 = fma(x1, s, y1);
      }
      // Escaping store: without it the whole loop is dead.
      output[gid] = x0 + y0 + x1 + y1;
    }

    /// Streaming reads and writes. Bound by memory bandwidth rather than ALUs.
    ///
    /// On Apple silicon the GPU shares the memory controller with the CPU, so this
    /// profile is the one that contends with CPU load.
    kernel void stressd_bandwidth(device float *output [[buffer(0)]],
                                  device const float *input [[buffer(2)]],
                                  constant uint &iterations [[buffer(1)]],
                                  constant uint &elementCount [[buffer(3)]],
                                  uint gid [[thread_position_in_grid]]) {
      float accumulator = 0.0f;
      uint stride = max(1u, elementCount / 4096u);

      for (uint i = 0; i < iterations; ++i) {
        // Walk the buffer with a stride large enough to miss the cache.
        uint index = (gid * stride + i * 4099u) % elementCount;
        accumulator += input[index];
      }
      output[gid] = accumulator;
    }

    /// A mix of arithmetic and memory traffic, which is what most real workloads
    /// look like.
    kernel void stressd_mixed(device float *output [[buffer(0)]],
                              device const float *input [[buffer(2)]],
                              constant uint &iterations [[buffer(1)]],
                              constant uint &elementCount [[buffer(3)]],
                              uint gid [[thread_position_in_grid]]) {
      float x = 1.0f + (float)(gid % 97) * 1e-4f;
      float y = 0.5f;
      const float s = 1e-3f;

      for (uint i = 0; i < iterations; ++i) {
        x = fma(y, -s, x);
        y = fma(x, s, y);
        if ((i & 15u) == 0u) {
          uint index = (gid * 7u + i * 4099u) % elementCount;
          x += input[index] * 1e-6f;
        }
      }
      output[gid] = x + y;
    }

    """
}
