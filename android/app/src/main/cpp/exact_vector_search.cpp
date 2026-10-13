#include <jni.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <thread>
#include <vector>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace {
std::atomic<int64_t> active_request{0};

int64_t exact_dot(const int8_t* left, const int8_t* right, int dimensions) {
    int64_t total = 0;
    int index = 0;
#if defined(__ARM_NEON)
    int32x4_t accumulator = vdupq_n_s32(0);
    for (; index + 16 <= dimensions; index += 16) {
        const int8x16_t x = vld1q_s8(left + index);
        const int8x16_t y = vld1q_s8(right + index);
        const int16x8_t low = vmull_s8(vget_low_s8(x), vget_low_s8(y));
        const int16x8_t high = vmull_s8(vget_high_s8(x), vget_high_s8(y));
        accumulator = vaddq_s32(accumulator, vpaddlq_s16(low));
        accumulator = vaddq_s32(accumulator, vpaddlq_s16(high));
    }
    int32_t lanes[4];
    vst1q_s32(lanes, accumulator);
    total = static_cast<int64_t>(lanes[0]) + lanes[1] + lanes[2] + lanes[3];
#endif
    for (; index < dimensions; ++index) {
        total += static_cast<int32_t>(left[index]) * static_cast<int32_t>(right[index]);
    }
    return total;
}

double magnitude(const int8_t* vector, int dimensions) {
    int64_t squared = exact_dot(vector, vector, dimensions);
    return squared > 0 ? std::sqrt(static_cast<double>(squared)) : 0.0;
}
}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_com_example_smart_1search_1app_ExactVectorSearch_nativeActivateRequest(
    JNIEnv*, jobject, jlong request_id) {
    active_request.store(static_cast<int64_t>(request_id), std::memory_order_release);
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_example_smart_1search_1app_ExactVectorSearch_nativeScoreExact(
    JNIEnv* env,
    jobject,
    jlong request_id,
    jbyteArray query_array,
    jbyteArray chunk_array,
    jbyteArray file_array,
    jdoubleArray chunk_magnitude_array,
    jdoubleArray file_magnitude_array,
    jint dimensions) {
    const jsize row_count = env->GetArrayLength(chunk_magnitude_array);
    jdoubleArray output_array = env->NewDoubleArray(row_count);
    if (row_count == 0 || dimensions <= 0) return output_array;

    auto* query = reinterpret_cast<int8_t*>(env->GetByteArrayElements(query_array, nullptr));
    auto* chunks = reinterpret_cast<int8_t*>(env->GetByteArrayElements(chunk_array, nullptr));
    auto* files = reinterpret_cast<int8_t*>(env->GetByteArrayElements(file_array, nullptr));
    auto* chunk_magnitudes = env->GetDoubleArrayElements(chunk_magnitude_array, nullptr);
    auto* file_magnitudes = env->GetDoubleArrayElements(file_magnitude_array, nullptr);
    std::vector<double> scores(static_cast<size_t>(row_count), -1.0);
    const double query_magnitude = magnitude(query, dimensions);
    const int64_t expected_request = static_cast<int64_t>(request_id);

    if (query_magnitude > 0.0 &&
        active_request.load(std::memory_order_acquire) == expected_request) {
        const unsigned available = std::max(1u, std::thread::hardware_concurrency());
        const int thread_count = std::min<int>({4, static_cast<int>(available), row_count});
        const int rows_per_thread = (row_count + thread_count - 1) / thread_count;
        std::vector<std::thread> workers;
        workers.reserve(static_cast<size_t>(thread_count));
        for (int worker = 0; worker < thread_count; ++worker) {
            const int start = worker * rows_per_thread;
            const int end = std::min<int>(row_count, start + rows_per_thread);
            if (start >= end) break;
            workers.emplace_back([=, &scores]() {
                for (int row = start; row < end; ++row) {
                    if (active_request.load(std::memory_order_relaxed) != expected_request) return;
                    const auto offset = static_cast<size_t>(row) * dimensions;
                    double best = -1.0;
                    if (chunk_magnitudes[row] > 0.0) {
                        best = static_cast<double>(exact_dot(query, chunks + offset, dimensions)) /
                            (query_magnitude * chunk_magnitudes[row]);
                    }
                    if (file_magnitudes[row] > 0.0) {
                        const double file_score =
                            static_cast<double>(exact_dot(query, files + offset, dimensions)) /
                            (query_magnitude * file_magnitudes[row]);
                        best = std::max(best, file_score);
                    }
                    scores[static_cast<size_t>(row)] = best;
                }
            });
        }
        for (auto& worker : workers) worker.join();
    }

    env->SetDoubleArrayRegion(output_array, 0, row_count, scores.data());
    env->ReleaseByteArrayElements(query_array, reinterpret_cast<jbyte*>(query), JNI_ABORT);
    env->ReleaseByteArrayElements(chunk_array, reinterpret_cast<jbyte*>(chunks), JNI_ABORT);
    env->ReleaseByteArrayElements(file_array, reinterpret_cast<jbyte*>(files), JNI_ABORT);
    env->ReleaseDoubleArrayElements(chunk_magnitude_array, chunk_magnitudes, JNI_ABORT);
    env->ReleaseDoubleArrayElements(file_magnitude_array, file_magnitudes, JNI_ABORT);
    return output_array;
}
