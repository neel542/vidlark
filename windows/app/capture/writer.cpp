#include "writer.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <strmif.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace capture {

void check(HRESULT result, const char* what) {
    if (FAILED(result)) {
        char text[160];
        std::snprintf(text, sizeof text, "%s failed (0x%08lX)", what, static_cast<unsigned long>(result));
        throw std::runtime_error(text);
    }
}

namespace {

ComPtr<IMFMediaType> videoType(const GUID& subtype, const VideoFormat& f, UINT32 bitrate) {
    ComPtr<IMFMediaType> type;
    check(MFCreateMediaType(&type), "making a video type");
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    type->SetGUID(MF_MT_SUBTYPE, subtype);
    type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, f.width, f.height);
    MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, f.fps, 1);
    MFSetAttributeRatio(type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (bitrate) {
        type->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
        type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
    } else {
        type->SetUINT32(MF_MT_DEFAULT_STRIDE, f.width);
        type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    }
    return type;
}

ComPtr<IMFMediaType> audioType(const GUID& subtype, const AudioFormat& f) {
    ComPtr<IMFMediaType> type;
    check(MFCreateMediaType(&type), "making a sound type");
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    type->SetGUID(MF_MT_SUBTYPE, subtype);
    type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, f.rate);
    type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, f.channels);
    type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (subtype == MFAudioFormat_AAC) {
        type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, f.bitrate / 8);
    } else {
        type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, f.channels * 2);
        type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, f.rate * f.channels * 2);
        type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    }
    return type;
}

ComPtr<IMFSample> sampleWith(const BYTE* data, DWORD size, LONGLONG time, LONGLONG duration) {
    ComPtr<IMFMediaBuffer> buffer;
    check(MFCreateMemoryBuffer(size, &buffer), "making a buffer");
    BYTE* target = nullptr;
    check(buffer->Lock(&target, nullptr, nullptr), "filling a buffer");
    if (data) {
        std::memcpy(target, data, size);
    } else {
        std::memset(target, 0, size);
    }
    buffer->Unlock();
    buffer->SetCurrentLength(size);
    ComPtr<IMFSample> sample;
    check(MFCreateSample(&sample), "making a sample");
    sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(time);
    sample->SetSampleDuration(duration);
    return sample;
}

}  // namespace

MovieWriter::MovieWriter(const std::filesystem::path& path, std::optional<VideoFormat> video, std::optional<AudioFormat> audio)
    : MovieWriter(path, video, audio ? std::vector<AudioFormat>{*audio} : std::vector<AudioFormat>{}) {}

MovieWriter::MovieWriter(const std::filesystem::path& path, std::optional<VideoFormat> video, const std::vector<AudioFormat>& audio) {
    ComPtr<IMFMediaType> videoOut;
    std::vector<ComPtr<IMFMediaType>> audioOut;
    UINT32 bitrate = 0;
    if (video) {
        videoFormat_ = *video;
        frameDuration_ = 10'000'000LL / std::max<UINT32>(1, videoFormat_.fps);
        bitrate = videoFormat_.bitrate ? videoFormat_.bitrate
                                       : static_cast<UINT32>(0.12 * videoFormat_.width * videoFormat_.height * videoFormat_.fps);
        videoOut = videoType(MFVideoFormat_H264, videoFormat_, bitrate);
    }
    audioFormats_ = audio;
    for (const auto& format : audioFormats_) audioOut.push_back(audioType(MFAudioFormat_AAC, format));

    // Fragmented MP4: each piece is complete on disk once written, so a crash loses at most the last one.
    // The sink is made here, not by the sink writer, so it can be told to cut a piece at every key frame.
    ComPtr<IMFByteStream> file;
    check(MFCreateFile(MF_ACCESSMODE_READWRITE, MF_OPENMODE_DELETE_IF_EXIST, MF_FILEFLAGS_NONE, path.c_str(), &file), "making the file");
    ComPtr<IMFMediaSink> sink;
    check(MFCreateFMPEG4MediaSink(file.Get(), videoOut.Get(), audioOut.empty() ? nullptr : audioOut[0].Get(), &sink), "starting the file");
    // Further sound tracks are added to the sink after the first.
    for (size_t i = 1; i < audioOut.size(); i++) {
        DWORD count = 0;
        sink->GetStreamSinkCount(&count);
        ComPtr<IMFStreamSink> added;
        check(sink->AddStreamSink(count, audioOut[i].Get(), &added), "adding a second sound track");
    }
    ComPtr<IMFAttributes> sinkSettings;
    if (SUCCEEDED(sink.As(&sinkSettings))) {
        sinkSettings->SetUINT64(MF_MPEG4SINK_MAX_CODED_SEQUENCES_PER_FRAGMENT, 1);
    }

    ComPtr<IMFAttributes> attributes;
    check(MFCreateAttributes(&attributes, 2), "making the writer's settings");
    attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    check(MFCreateSinkWriterFromMediaSink(sink.Get(), attributes.Get(), &writer_), "starting the writer");

    // The sink's streams are in the order given: the picture first, when there is one, then each sound track.
    DWORD next = 0;
    if (video) {
        videoStream_ = next++;
        check(writer_->SetInputMediaType(videoStream_, videoType(MFVideoFormat_NV12, videoFormat_, 0).Get(), nullptr),
              "setting the picture's format");
        // A key frame every 2 seconds: the pieces are cut at key frames.
        ComPtr<ICodecAPI> codec;
        if (SUCCEEDED(writer_->GetServiceForStream(videoStream_, GUID_NULL, IID_PPV_ARGS(&codec)))) {
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_UI4;
            value.ulVal = videoFormat_.fps * 2;
            codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &value);
        }
    }
    for (const auto& format : audioFormats_) {
        const DWORD stream = next++;
        check(writer_->SetInputMediaType(stream, audioType(MFAudioFormat_PCM, format).Get(), nullptr), "setting the sound's format");
        audioStreams_.push_back(stream);
    }
    check(writer_->BeginWriting(), "starting to write");
}

MovieWriter::~MovieWriter() {
    try {
        finish();
    } catch (...) {
    }
}

void MovieWriter::writeVideo(const BYTE* nv12, LONG stride, LONGLONG time) {
    if (videoStream_ == kNone) return;
    const UINT32 w = videoFormat_.width, h = videoFormat_.height;
    std::vector<BYTE> packed;
    const BYTE* data = nv12;
    if (stride != static_cast<LONG>(w)) {
        // Pack the rows tightly: luma rows, then the interleaved chroma rows at half height.
        packed.resize(static_cast<size_t>(w) * h * 3 / 2);
        for (UINT32 row = 0; row < h * 3 / 2; row++) std::memcpy(&packed[row * w], nv12 + row * stride, w);
        data = packed.data();
    }
    auto sample = sampleWith(data, w * h * 3 / 2, time, frameDuration_);
    check(writer_->WriteSample(videoStream_, sample.Get()), "writing a picture");
}

void MovieWriter::writeVideo(IMFSample* sample) {
    if (videoStream_ == kNone || !sample) return;
    check(writer_->WriteSample(videoStream_, sample), "writing a picture");
}

void MovieWriter::writeAudio(const int16_t* samples, UINT32 frames, LONGLONG time, size_t track) {
    if (track >= audioStreams_.size() || frames == 0) return;
    const AudioFormat& format = audioFormats_[track];
    const DWORD size = frames * format.channels * 2;
    const LONGLONG duration = 10'000'000LL * frames / format.rate;
    auto sample = sampleWith(reinterpret_cast<const BYTE*>(samples), size, time, duration);
    check(writer_->WriteSample(audioStreams_[track], sample.Get()), "writing sound");
}

void MovieWriter::writeSilence(UINT32 frames, LONGLONG time, size_t track) {
    if (track >= audioStreams_.size() || frames == 0) return;
    const AudioFormat& format = audioFormats_[track];
    const DWORD size = frames * format.channels * 2;
    const LONGLONG duration = 10'000'000LL * frames / format.rate;
    auto sample = sampleWith(nullptr, size, time, duration);
    check(writer_->WriteSample(audioStreams_[track], sample.Get()), "writing silence");
}

void placeSound(MovieWriter& writer, size_t track, long long& written, const int16_t* samples, UINT32 frames,
                UINT32 channels, LONGLONG time, LONGLONG t0, UINT32 rate) {
    constexpr LONGLONG second = 10'000'000;
    const long long at = (time - t0) * rate / second;  // where these samples belong, in samples
    if (at + frames <= 0) return;                       // all before the start
    UINT32 skip = 0;
    if (at < 0) skip = static_cast<UINT32>(-at);
    const long long start = std::max<long long>(at, 0);
    // A gap of more than 10 ms: fill it with silence.
    if (start > written + rate / 100) padSound(writer, track, written, start, rate);
    writer.writeAudio(samples + static_cast<size_t>(skip) * channels, frames - skip, written * second / rate, track);
    written += frames - skip;
}

void padSound(MovieWriter& writer, size_t track, long long& written, long long until, UINT32 rate) {
    constexpr LONGLONG second = 10'000'000;
    while (written < until) {
        const UINT32 chunk = static_cast<UINT32>(std::min<long long>(until - written, rate / 2));
        writer.writeSilence(chunk, written * second / rate, track);
        written += chunk;
    }
}

void MovieWriter::finish() {
    if (finished_ || !writer_) return;
    finished_ = true;
    check(writer_->Finalize(), "finishing the file");
}

}  // namespace capture
