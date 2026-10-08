#pragma once
// Direct3D 11 for the screen recording and the camera windows: a device (the graphics chip, or
// Windows' software one when there is none), shaders compiled from text, and the step that turns a
// captured screen into the NV12 pictures the H.264 encoder takes, scaled and fitted on the graphics chip.

#include <windows.h>
#include <d3d11.h>
#include <wrl/client.h>

#include <cstdint>
#include <vector>

namespace capture {

// A device with BGRA support, as Windows.Graphics.Capture needs, safe to use from more than one thread.
// `software` is set when only Windows' software renderer was available.
Microsoft::WRL::ComPtr<ID3D11Device> makeDevice(bool* software = nullptr);

// Compiles HLSL text. Throws std::runtime_error with the compiler's words when it does not compile.
Microsoft::WRL::ComPtr<ID3DBlob> compileShader(const char* source, const char* entry, const char* target);

// BGRA pictures in, NV12 out at a fixed size: the part of the picture in `from` is scaled to fit, keeping
// its shape, with black bars if its shape differs. BT.709 colours, video range.
class Nv12Converter {
public:
    Nv12Converter(ID3D11Device* device, UINT width, UINT height);
    // `source` must be a BGRA texture the device can read in a shader. `nv12` gets width * height * 3 / 2 bytes.
    void convert(ID3D11Texture2D* source, const RECT& from, std::vector<BYTE>& nv12);
    UINT width() const { return width_; }
    UINT height() const { return height_; }

private:
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    UINT width_, height_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> luma_, chroma_, lumaRead_, chromaRead_;
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> lumaTarget_, chromaTarget_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> lumaShader_, chromaShader_;
    Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> params_;
};

// The fitted rectangle of a `w` x `h` picture inside `outW` x `outH`, centred.
RECT fitInside(LONG w, LONG h, UINT outW, UINT outH);

// The recording size for a picture of `w` x `h`: at most 1920 on the long side, even numbers.
void recordingSize(LONG w, LONG h, UINT& outW, UINT& outH);

}  // namespace capture
