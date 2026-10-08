#include "picture.h"

#include <wincodec.h>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

namespace app {

std::string base64(const BYTE* data, size_t size) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((size + 2) / 3 * 4);
    for (size_t i = 0; i < size; i += 3) {
        const UINT32 n = (UINT32(data[i]) << 16) | (i + 1 < size ? UINT32(data[i + 1]) << 8 : 0) | (i + 2 < size ? data[i + 2] : 0);
        out += table[(n >> 18) & 63];
        out += table[(n >> 12) & 63];
        out += i + 1 < size ? table[(n >> 6) & 63] : '=';
        out += i + 2 < size ? table[n & 63] : '=';
    }
    return out;
}

std::string jpegBase64(const std::vector<BYTE>& bgra, UINT32 w, UINT32 h) {
    static thread_local ComPtr<IWICImagingFactory> factory;
    if (!factory && FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return {};
    ComPtr<IWICBitmap> bitmap;
    if (FAILED(factory->CreateBitmapFromMemory(w, h, GUID_WICPixelFormat32bppBGRA, w * 4, static_cast<UINT>(bgra.size()),
                                               const_cast<BYTE*>(bgra.data()), &bitmap))) return {};
    ComPtr<IStream> stream;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return {};
    ComPtr<IWICBitmapEncoder> encoder;
    if (FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder))) return {};
    encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> options;
    if (FAILED(encoder->CreateNewFrame(&frame, &options))) return {};
    PROPBAG2 quality{};
    quality.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = 0.72f;
    options->Write(1, &quality, &value);
    frame->Initialize(options.Get());
    frame->SetSize(w, h);
    WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
    frame->SetPixelFormat(&format);
    if (FAILED(frame->WriteSource(bitmap.Get(), nullptr)) || FAILED(frame->Commit()) || FAILED(encoder->Commit())) return {};
    STATSTG stat{};
    stream->Stat(&stat, STATFLAG_NONAME);
    HGLOBAL memory = nullptr;
    GetHGlobalFromStream(stream.Get(), &memory);
    const BYTE* bytes = static_cast<const BYTE*>(GlobalLock(memory));
    std::string out = base64(bytes, static_cast<size_t>(stat.cbSize.QuadPart));
    GlobalUnlock(memory);
    return out;
}

}  // namespace app
