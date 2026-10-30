// Keeps every GPU core busy with arithmetic for the given number of seconds.
import Foundation
import Metal

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "25") ?? 25
let source = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float4 *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float4 a = float4(id) * 1e-6, b = float4(1.0001), c = float4(0.9999);
    for (int i = 0; i < 4096; i++) { a = fma(a, b, c); b = fma(b, c, a); c = fma(c, a, b); }
    out[id] = a + b + c;
}
"""
let device = MTLCreateSystemDefaultDevice()!
let library = try! device.makeLibrary(source: source, options: nil)
let pipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "burn")!)
let queue = device.makeCommandQueue()!
let threads = 1 << 20
let buffer = device.makeBuffer(length: threads * 16, options: .storageModePrivate)!
print("device \(device.name), start \(ISO8601DateFormatter().string(from: Date()))")
let end = Date().addingTimeInterval(seconds)
var last: MTLCommandBuffer?
var count = 0
while Date() < end {
    // Several buffers in flight so the GPU never waits for the CPU.
    for _ in 0..<4 {
        let commands = queue.makeCommandBuffer()!
        let encoder = commands.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        last = commands
        count += 1
    }
    last?.waitUntilCompleted()
}
last?.waitUntilCompleted()
print("end \(ISO8601DateFormatter().string(from: Date())), \(count) dispatches")
