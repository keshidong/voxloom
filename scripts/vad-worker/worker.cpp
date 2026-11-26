#include "common-whisper.h"
#include "json.hpp"
#include "whisper.h"

#include <iostream>
#include <memory>
#include <string>
#include <vector>

static void reply(const char *message) {
    std::cout << message << std::endl;
}

int main(int argc, char **argv) {
    if (argc != 3 || std::string(argv[1]) != "--model") {
        return 1;
    }

    whisper_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    auto context_params = whisper_vad_default_context_params();
    context_params.n_threads = 1;
    context_params.use_gpu = false;
    std::unique_ptr<whisper_vad_context, decltype(&whisper_vad_free)> context(
        whisper_vad_init_from_file_with_params(argv[2], context_params), whisper_vad_free);
    if (!context) {
        reply(R"({"ready":false})");
        return 2;
    }

    auto params = whisper_vad_default_params();
    params.threshold = 0.5f;
    params.min_speech_duration_ms = 100;
    reply(R"({"ready":true})");

    char line[65538];
    while (std::cin.getline(line, sizeof(line))) {
        const auto request = nlohmann::json::parse(line, nullptr, false);
        if (!request.is_object() || !request.contains("audio") || !request["audio"].is_string()) {
            reply(R"({"error":"invalid_request"})");
            continue;
        }
        const auto &path = request["audio"].get_ref<const std::string &>();
        std::vector<float> samples;
        std::vector<std::vector<float>> channels;
        if (path.empty() || path == "-" || !read_audio_data(path, samples, channels, false) ||
            samples.empty() || samples.size() > 60 * WHISPER_SAMPLE_RATE ||
            !whisper_vad_detect_speech(context.get(), samples.data(), static_cast<int>(samples.size()))) {
            reply(R"({"error":"detection_failed"})");
            continue;
        }
        std::unique_ptr<whisper_vad_segments, decltype(&whisper_vad_free_segments)> segments(
            whisper_vad_segments_from_probs(context.get(), params), whisper_vad_free_segments);
        if (!segments) {
            reply(R"({"error":"detection_failed"})");
            continue;
        }
        reply(whisper_vad_segments_n_segments(segments.get()) > 0 ? R"({"speech":true})" : R"({"speech":false})");
    }
}
