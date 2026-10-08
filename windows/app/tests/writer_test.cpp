// vidlark-writer-test <out> <seconds> [--crash-after <seconds>] [--audio-only]
// Writes a movie of a moving test picture and a pattern of noise bursts with capture::MovieWriter, the
// way the app writes camera.mov, so CI can check the files on a Windows machine that has no camera.
// --crash-after ends the process abruptly part way through, like a crash, to check the take survives.

#include "../capture/writer.h"

#include <mfapi.h>

#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: vidlark-writer-test <out> <seconds> [--crash-after <seconds>] [--audio-only]\n");
        return 2;
    }
    const std::filesystem::path out = argv[1];
    const double seconds = _wtof(argv[2]);
    double crashAfter = -1;
    bool audioOnly = false;
    for (int i = 3; i < argc; i++) {
        std::wstring arg = argv[i];
        if (arg == L"--crash-after" && i + 1 < argc) crashAfter = _wtof(argv[++i]);
        if (arg == L"--audio-only") audioOnly = true;
    }

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);
    try {
        capture::VideoFormat video{1280, 720, 30, 0};
        capture::AudioFormat audio{48000, 1, 192000};
        capture::MovieWriter writer(out, audioOnly ? std::nullopt : std::optional(video), audio);

        std::vector<BYTE> frame(video.width * video.height * 3 / 2);
        std::mt19937 pattern(7), noise(11);
        std::uniform_real_distribution<double> unit(0, 1);
        double burstStart = 0.2, burstEnd = 0.2 + 0.05 + unit(pattern) * 0.35;
        const UINT32 chunk = 480;  // 10 ms of sound
        std::vector<int16_t> sound(chunk);
        long long written = 0;  // sound frames so far
        const long long totalFrames = static_cast<long long>(seconds * video.fps);

        for (long long n = 0; n < totalFrames || audioOnly; n++) {
            const double t = double(n) / video.fps;
            if (t >= seconds) break;
            if (crashAfter >= 0 && t >= crashAfter) {
                std::fprintf(stderr, "crashing at %.2f s\n", t);
                TerminateProcess(GetCurrentProcess(), 3);
            }
            if (!audioOnly) {
                // Grey, with a white square moving across: plain to see and to compress.
                std::fill(frame.begin(), frame.begin() + video.width * video.height, BYTE(90));
                std::fill(frame.begin() + video.width * video.height, frame.end(), BYTE(128));
                const UINT32 x0 = static_cast<UINT32>(n * 8 % (video.width - 160));
                for (UINT32 y = 280; y < 440; y++)
                    for (UINT32 x = x0; x < x0 + 160; x++) frame[y * video.width + x] = 235;
                writer.writeVideo(frame.data(), static_cast<LONG>(video.width), static_cast<LONGLONG>(t * 10'000'000));
            }
            // Sound up to the end of this picture.
            const long long until = static_cast<long long>((t + 1.0 / video.fps) * audio.rate);
            while (written + chunk <= until) {
                for (UINT32 i = 0; i < chunk; i++) {
                    const double now = double(written + i) / audio.rate;
                    while (now > burstEnd) {
                        burstStart = burstEnd + 0.1 + unit(pattern) * 0.8;
                        burstEnd = burstStart + 0.05 + unit(pattern) * 0.35;
                    }
                    const double level = now >= burstStart ? 0.6 : 0.02;
                    sound[i] = static_cast<int16_t>((unit(noise) * 2 - 1) * level * 32000);
                }
                writer.writeAudio(sound.data(), chunk, written * 10'000'000 / audio.rate);
                written += chunk;
            }
        }
        writer.finish();
    } catch (const std::exception& error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
    MFShutdown();
    return 0;
}
