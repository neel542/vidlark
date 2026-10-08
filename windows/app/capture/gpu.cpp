#include "gpu.h"

#include "writer.h"

#include <d3d11_4.h>
#include <d3dcompiler.h>

#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <string>

using Microsoft::WRL::ComPtr;

namespace capture {

ComPtr<ID3D11Device> makeDevice(bool* software) {
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    ComPtr<ID3D11Device> device;
    HRESULT result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, ARRAYSIZE(levels),
                                       D3D11_SDK_VERSION, &device, nullptr, nullptr);
    bool warp = false;
    if (FAILED(result)) {
        // No graphics chip Direct3D can use: Windows' own software renderer does the same work, slower.
        result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                                   &device, nullptr, nullptr);
        warp = true;
    }
    check(result, "starting Direct3D");
    // The capture's own thread and ours both use it.
    ComPtr<ID3D11Multithread> multithread;
    if (SUCCEEDED(device.As(&multithread))) multithread->SetMultithreadProtected(TRUE);
    if (software) *software = warp;
    return device;
}

ComPtr<ID3DBlob> compileShader(const char* source, const char* entry, const char* target) {
    ComPtr<ID3DBlob> code, errors;
    HRESULT result = D3DCompile(source, std::strlen(source), nullptr, nullptr, nullptr, entry, target,
                                D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
    if (FAILED(result)) {
        std::string words = "a shader did not compile";
        if (errors) words += ": " + std::string(static_cast<const char*>(errors->GetBufferPointer()), errors->GetBufferSize());
        throw std::runtime_error(words);
    }
    return code;
}

RECT fitInside(LONG w, LONG h, UINT outW, UINT outH) {
    if (w <= 0 || h <= 0) return RECT{0, 0, static_cast<LONG>(outW), static_cast<LONG>(outH)};
    const double scale = std::min(double(outW) / w, double(outH) / h);
    const LONG fw = std::min<LONG>(static_cast<LONG>(outW), static_cast<LONG>(w * scale + 0.5));
    const LONG fh = std::min<LONG>(static_cast<LONG>(outH), static_cast<LONG>(h * scale + 0.5));
    const LONG x = (static_cast<LONG>(outW) - fw) / 2, y = (static_cast<LONG>(outH) - fh) / 2;
    return RECT{x, y, x + fw, y + fh};
}

void recordingSize(LONG w, LONG h, UINT& outW, UINT& outH) {
    w = std::max<LONG>(w, 64);
    h = std::max<LONG>(h, 64);
    const double k = std::min(1.0, 1920.0 / std::max(w, h));
    outW = static_cast<UINT>(w * k) & ~1u;
    outH = static_cast<UINT>(h * k) & ~1u;
}

namespace {

// One triangle that covers the whole target; each pixel shader works out its own colour.
// rgbAt takes four samples inside each output pixel, so a big screen shrinks without shimmer.
const char* converterShaders = R"(
Texture2D source : register(t0);
SamplerState smooth : register(s0);
cbuffer Params : register(b0) {
    float4 dest;   // where the picture goes, in output pixels: left, top, right, bottom
    float4 from;   // the part of the source shown, in texture coordinates: left, top, right, bottom
};

float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}

float3 rgbAt(float2 pixel) {
    if (pixel.x < dest.x || pixel.y < dest.y || pixel.x >= dest.z || pixel.y >= dest.w) return float3(0, 0, 0);
    float2 span = (from.zw - from.xy) / (dest.zw - dest.xy);
    float2 uv = from.xy + (pixel - dest.xy) * span;
    float2 q = span * 0.25;
    float3 c = source.SampleLevel(smooth, uv + float2(-q.x, -q.y), 0).rgb
             + source.SampleLevel(smooth, uv + float2( q.x, -q.y), 0).rgb
             + source.SampleLevel(smooth, uv + float2(-q.x,  q.y), 0).rgb
             + source.SampleLevel(smooth, uv + float2( q.x,  q.y), 0).rgb;
    return c * 0.25;
}

float psLuma(float4 pos : SV_Position) : SV_Target {
    float3 c = rgbAt(pos.xy);
    return (16.0 + 219.0 * dot(c, float3(0.2126, 0.7152, 0.0722))) / 255.0;
}

float2 psChroma(float4 pos : SV_Position) : SV_Target {
    float2 luma = pos.xy * 2.0;
    float3 c = (rgbAt(luma + float2(-0.5, -0.5)) + rgbAt(luma + float2(0.5, -0.5))
              + rgbAt(luma + float2(-0.5, 0.5)) + rgbAt(luma + float2(0.5, 0.5))) * 0.25;
    float u = 128.0 + 224.0 * dot(c, float3(-0.1146, -0.3854, 0.5));
    float v = 128.0 + 224.0 * dot(c, float3(0.5, -0.4542, -0.0458));
    return float2(u, v) / 255.0;
}
)";

struct Params {
    float dest[4];
    float from[4];
};

ComPtr<ID3D11Texture2D> texture(ID3D11Device* device, UINT w, UINT h, DXGI_FORMAT format, bool readable) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = w;
    desc.Height = h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.Usage = readable ? D3D11_USAGE_STAGING : D3D11_USAGE_DEFAULT;
    desc.BindFlags = readable ? 0 : D3D11_BIND_RENDER_TARGET;
    desc.CPUAccessFlags = readable ? D3D11_CPU_ACCESS_READ : 0;
    ComPtr<ID3D11Texture2D> made;
    check(device->CreateTexture2D(&desc, nullptr, &made), "making a picture on the graphics chip");
    return made;
}

}  // namespace

Nv12Converter::Nv12Converter(ID3D11Device* device, UINT width, UINT height) : device_(device), width_(width), height_(height) {
    device_->GetImmediateContext(&context_);
    luma_ = texture(device, width, height, DXGI_FORMAT_R8_UNORM, false);
    chroma_ = texture(device, width / 2, height / 2, DXGI_FORMAT_R8G8_UNORM, false);
    lumaRead_ = texture(device, width, height, DXGI_FORMAT_R8_UNORM, true);
    chromaRead_ = texture(device, width / 2, height / 2, DXGI_FORMAT_R8G8_UNORM, true);
    check(device->CreateRenderTargetView(luma_.Get(), nullptr, &lumaTarget_), "preparing the picture");
    check(device->CreateRenderTargetView(chroma_.Get(), nullptr, &chromaTarget_), "preparing the picture");

    auto vs = compileShader(converterShaders, "vs", "vs_4_0");
    auto luma = compileShader(converterShaders, "psLuma", "ps_4_0");
    auto chroma = compileShader(converterShaders, "psChroma", "ps_4_0");
    check(device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &vertex_), "loading a shader");
    check(device->CreatePixelShader(luma->GetBufferPointer(), luma->GetBufferSize(), nullptr, &lumaShader_), "loading a shader");
    check(device->CreatePixelShader(chroma->GetBufferPointer(), chroma->GetBufferSize(), nullptr, &chromaShader_), "loading a shader");

    D3D11_SAMPLER_DESC sampler{};
    sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampler.MaxLOD = D3D11_FLOAT32_MAX;
    check(device->CreateSamplerState(&sampler, &sampler_), "making a sampler");

    D3D11_BUFFER_DESC buffer{};
    buffer.ByteWidth = sizeof(Params);
    buffer.Usage = D3D11_USAGE_DEFAULT;
    buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    check(device->CreateBuffer(&buffer, nullptr, &params_), "making the shader's settings");
}

void Nv12Converter::convert(ID3D11Texture2D* source, const RECT& from, std::vector<BYTE>& nv12) {
    D3D11_TEXTURE2D_DESC desc{};
    source->GetDesc(&desc);
    ComPtr<ID3D11ShaderResourceView> view;
    check(device_->CreateShaderResourceView(source, nullptr, &view), "reading the screen picture");

    const RECT dest = fitInside(from.right - from.left, from.bottom - from.top, width_, height_);
    Params params{};
    params.dest[0] = float(dest.left);
    params.dest[1] = float(dest.top);
    params.dest[2] = float(dest.right);
    params.dest[3] = float(dest.bottom);
    params.from[0] = float(from.left) / desc.Width;
    params.from[1] = float(from.top) / desc.Height;
    params.from[2] = float(from.right) / desc.Width;
    params.from[3] = float(from.bottom) / desc.Height;
    context_->UpdateSubresource(params_.Get(), 0, nullptr, &params, 0, 0);

    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->IASetInputLayout(nullptr);
    context_->VSSetShader(vertex_.Get(), nullptr, 0);
    context_->PSSetShaderResources(0, 1, view.GetAddressOf());
    context_->PSSetSamplers(0, 1, sampler_.GetAddressOf());
    context_->PSSetConstantBuffers(0, 1, params_.GetAddressOf());

    auto pass = [&](ID3D11RenderTargetView* target, ID3D11PixelShader* shader, UINT w, UINT h) {
        D3D11_VIEWPORT viewport{0, 0, float(w), float(h), 0, 1};
        context_->RSSetViewports(1, &viewport);
        context_->OMSetRenderTargets(1, &target, nullptr);
        context_->PSSetShader(shader, nullptr, 0);
        context_->Draw(3, 0);
    };
    pass(lumaTarget_.Get(), lumaShader_.Get(), width_, height_);
    pass(chromaTarget_.Get(), chromaShader_.Get(), width_ / 2, height_ / 2);
    ID3D11RenderTargetView* none = nullptr;
    context_->OMSetRenderTargets(1, &none, nullptr);
    ID3D11ShaderResourceView* noView = nullptr;
    context_->PSSetShaderResources(0, 1, &noView);

    context_->CopyResource(lumaRead_.Get(), luma_.Get());
    context_->CopyResource(chromaRead_.Get(), chroma_.Get());

    nv12.resize(static_cast<size_t>(width_) * height_ * 3 / 2);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    check(context_->Map(lumaRead_.Get(), 0, D3D11_MAP_READ, 0, &mapped), "reading the picture back");
    for (UINT row = 0; row < height_; row++) {
        std::memcpy(&nv12[static_cast<size_t>(row) * width_], static_cast<const BYTE*>(mapped.pData) + static_cast<size_t>(row) * mapped.RowPitch, width_);
    }
    context_->Unmap(lumaRead_.Get(), 0);
    check(context_->Map(chromaRead_.Get(), 0, D3D11_MAP_READ, 0, &mapped), "reading the picture back");
    BYTE* uv = nv12.data() + static_cast<size_t>(width_) * height_;
    for (UINT row = 0; row < height_ / 2; row++) {
        std::memcpy(uv + static_cast<size_t>(row) * width_, static_cast<const BYTE*>(mapped.pData) + static_cast<size_t>(row) * mapped.RowPitch, width_);
    }
    context_->Unmap(chromaRead_.Get(), 0);
}

}  // namespace capture
