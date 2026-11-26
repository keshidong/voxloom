# The pinned Whisper project defines its libraries after project().
include_guard(GLOBAL)

function(add_voxloom_vad_worker)
    add_executable(voxloom-vad "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/worker.cpp")
    target_compile_features(voxloom-vad PRIVATE cxx_std_17)
    target_link_libraries(voxloom-vad PRIVATE common whisper json_cpp)
endfunction()

cmake_language(DEFER CALL add_voxloom_vad_worker)
