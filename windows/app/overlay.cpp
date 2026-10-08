#include "overlay.h"

#include "capture/gpu.h"
#include "capture/writer.h"

#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_2.h>
#include <shellscalingapi.h>
#include <windowsx.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

using Microsoft::WRL::ComPtr;

namespace app {

namespace {

constexpr wchar_t stageClass[] = L"VidlarkStage";
constexpr wchar_t bubbleClass[] = L"VidlarkBubble";
// From the drawing thread to the window thread: the card has shrunk into the bubble, so the bubble window shows.
constexpr UINT bubbleArrived = WM_APP + 21;
constexpr ULONGLONG moveMs = 500;  // the Mac's 0.5 s

// The card: her camera in a rounded rectangle (a circle when the corners meet), with a white edge,
// see-through outside. Colours from the camera's NV12, BT.601 video range.
const char* cardShaders = R"(
Texture2D lumaTex : register(t0);
Texture2D chromaTex : register(t1);
SamplerState smooth : register(s0);
cbuffer Card : register(b0) {
    float4 rect;     // left, top, right, bottom, in this window's pixels
    float4 crop;     // the part of the camera picture shown, 0 to 1: left, top, right, bottom
    float radius;    // corner radius in pixels
    float border;    // the white edge, in pixels
    float opacity;
    float picture;   // 1 when there is a camera picture
};

float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 ps(float4 pos : SV_Position) : SV_Target {
    float2 size = max(rect.zw - rect.xy, float2(1, 1));
    float2 uv = lerp(crop.xy, crop.zw, saturate((pos.xy - rect.xy) / size));
    float y = lumaTex.Sample(smooth, uv).r - 16.0 / 255.0;
    float2 c = chromaTex.Sample(smooth, uv).rg - 128.0 / 255.0;
    float3 rgb = saturate(float3(1.164 * y + 1.596 * c.y, 1.164 * y - 0.392 * c.x - 0.813 * c.y, 1.164 * y + 2.017 * c.x));
    if (picture < 0.5) rgb = float3(0.08, 0.09, 0.09);

    float2 centre = (rect.xy + rect.zw) * 0.5;
    float r = min(radius, min(size.x, size.y) * 0.5);
    float2 q = abs(pos.xy - centre) - (size * 0.5 - r);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;   // below 0 inside the card
    float alpha = saturate(0.5 - d) * opacity;
    float edge = border > 0.01 ? saturate(border + 0.5 + d) : 0.0;
    rgb = lerp(rgb, float3(1, 1, 1), edge * 0.85);
    return float4(rgb * alpha, alpha);
}
)";

struct CardParams {
    float rect[4];
    float crop[4];
    float radius;
    float border;
    float opacity;
    float picture;
};

float ease(float t) { return t * t * (3 - 2 * t); }

Overlay::Look mix(const Overlay::Look& a, const Overlay::Look& b, float t) {
    auto m = [t](float x, float y) { return x + (y - x) * t; };
    Overlay::Look out;
    out.left = m(a.left, b.left);
    out.top = m(a.top, b.top);
    out.right = m(a.right, b.right);
    out.bottom = m(a.bottom, b.bottom);
    out.radius = m(a.radius, b.radius);
    out.border = m(a.border, b.border);
    out.opacity = m(a.opacity, b.opacity);
    for (int i = 0; i < 4; i++) out.crop[i] = m(a.crop[i], b.crop[i]);
    return out;
}

float scaleFor(const RECT& r) {
    UINT x = 96, y = 96;
    if (FAILED(GetDpiForMonitor(MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST), MDT_EFFECTIVE_DPI, &x, &y))) x = 96;
    return x / 96.0f;
}

void registerClass(const wchar_t* name, WNDPROC proc) {
    WNDCLASSEXW wc{sizeof wc};
    if (GetClassInfoExW(GetModuleHandleW(nullptr), name, &wc)) return;
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = name;
    RegisterClassExW(&wc);
}

}  // namespace

// Direct3D and DirectComposition, on the drawing thread only.
struct Overlay::Gpu {
    struct Surface {
        ComPtr<IDXGISwapChain1> chain;
        ComPtr<IDCompositionTarget> target;
        ComPtr<IDCompositionVisual> visual;
        UINT w = 0, h = 0;
        bool empty = false;  // the last frame drawn was see-through
    };
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGIFactory2> factory;
    ComPtr<IDCompositionDevice> dcomp;
    Surface stage, bubble;
    ComPtr<ID3D11VertexShader> vs;
    ComPtr<ID3D11PixelShader> ps;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11Buffer> params;
    ComPtr<ID3D11BlendState> blend;
    ComPtr<ID3D11Texture2D> luma, chroma;
    ComPtr<ID3D11ShaderResourceView> lumaView, chromaView;
    UINT cw = 0, ch = 0;
    unsigned long long uploaded = 0;

    Gpu() {
        device = capture::makeDevice();
        device->GetImmediateContext(&context);
        ComPtr<IDXGIDevice> dxgi;
        capture::check(device.As(&dxgi), "reaching the graphics chip");
        ComPtr<IDXGIAdapter> adapter;
        capture::check(dxgi->GetAdapter(&adapter), "reaching the graphics chip");
        capture::check(adapter->GetParent(IID_PPV_ARGS(&factory)), "reaching the graphics chip");
        capture::check(DCompositionCreateDevice(dxgi.Get(), IID_PPV_ARGS(&dcomp)), "starting DirectComposition");

        auto vsCode = capture::compileShader(cardShaders, "vs", "vs_4_0");
        auto psCode = capture::compileShader(cardShaders, "ps", "ps_4_0");
        capture::check(device->CreateVertexShader(vsCode->GetBufferPointer(), vsCode->GetBufferSize(), nullptr, &vs), "loading a shader");
        capture::check(device->CreatePixelShader(psCode->GetBufferPointer(), psCode->GetBufferSize(), nullptr, &ps), "loading a shader");
        D3D11_SAMPLER_DESC s{};
        s.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        s.AddressU = s.AddressV = s.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        s.MaxLOD = D3D11_FLOAT32_MAX;
        capture::check(device->CreateSamplerState(&s, &sampler), "making a sampler");
        D3D11_BUFFER_DESC b{};
        b.ByteWidth = sizeof(CardParams);
        b.Usage = D3D11_USAGE_DEFAULT;
        b.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        capture::check(device->CreateBuffer(&b, nullptr, &params), "making the shader's settings");
        D3D11_BLEND_DESC blendDesc{};
        blendDesc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;  // the shader's colour as it is
        capture::check(device->CreateBlendState(&blendDesc, &blend), "making a blend");
    }

    ~Gpu() {
        for (Surface* s : {&stage, &bubble}) {
            if (s->target) s->target->SetRoot(nullptr);
        }
        if (dcomp) dcomp->Commit();
    }

    // The window's swap chain at this size, made or resized as needed.
    void fit(Surface& s, HWND window, UINT w, UINT h) {
        w = std::max<UINT>(w, 8);
        h = std::max<UINT>(h, 8);
        if (s.chain && s.w == w && s.h == h) return;
        if (s.chain) {
            capture::check(s.chain->ResizeBuffers(2, w, h, DXGI_FORMAT_B8G8R8A8_UNORM, 0), "resizing a window's picture");
        } else {
            DXGI_SWAP_CHAIN_DESC1 desc{};
            desc.Width = w;
            desc.Height = h;
            desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            desc.SampleDesc.Count = 1;
            desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            desc.BufferCount = 2;
            desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
            desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
            capture::check(factory->CreateSwapChainForComposition(device.Get(), &desc, nullptr, &s.chain), "making a window's picture");
            capture::check(dcomp->CreateTargetForHwnd(window, TRUE, &s.target), "showing a window's picture");
            capture::check(dcomp->CreateVisual(&s.visual), "showing a window's picture");
            capture::check(s.visual->SetContent(s.chain.Get()), "showing a window's picture");
            capture::check(s.target->SetRoot(s.visual.Get()), "showing a window's picture");
            capture::check(dcomp->Commit(), "showing a window's picture");
        }
        s.w = w;
        s.h = h;
        s.empty = false;
    }

    void upload(const std::vector<BYTE>& y, const std::vector<BYTE>& uv, UINT w, UINT h) {
        if (!luma || cw != w || ch != h) {
            luma.Reset();
            chroma.Reset();
            lumaView.Reset();
            chromaView.Reset();
            auto make = [&](UINT tw, UINT th, DXGI_FORMAT format, ComPtr<ID3D11Texture2D>& tex, ComPtr<ID3D11ShaderResourceView>& view) {
                D3D11_TEXTURE2D_DESC desc{};
                desc.Width = tw;
                desc.Height = th;
                desc.MipLevels = 0;  // every smaller size too, so a big camera picture shrinks into the bubble smoothly
                desc.ArraySize = 1;
                desc.Format = format;
                desc.SampleDesc.Count = 1;
                desc.Usage = D3D11_USAGE_DEFAULT;
                desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
                desc.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
                capture::check(device->CreateTexture2D(&desc, nullptr, &tex), "keeping the camera picture");
                capture::check(device->CreateShaderResourceView(tex.Get(), nullptr, &view), "keeping the camera picture");
            };
            make(w, h, DXGI_FORMAT_R8_UNORM, luma, lumaView);
            make(w / 2, h / 2, DXGI_FORMAT_R8G8_UNORM, chroma, chromaView);
            cw = w;
            ch = h;
        }
        context->UpdateSubresource(luma.Get(), 0, nullptr, y.data(), w, 0);
        context->UpdateSubresource(chroma.Get(), 0, nullptr, uv.data(), w, 0);
        context->GenerateMips(lumaView.Get());
        context->GenerateMips(chromaView.Get());
    }

    // One frame: the card at `look` (in this window's pixels), or nothing.
    void render(Surface& s, const Overlay::Look* look) {
        if (!s.chain) return;
        if (!look && s.empty) return;  // already see-through; nothing to change
        ComPtr<ID3D11Texture2D> buffer;
        capture::check(s.chain->GetBuffer(0, IID_PPV_ARGS(&buffer)), "drawing a window");
        ComPtr<ID3D11RenderTargetView> target;
        capture::check(device->CreateRenderTargetView(buffer.Get(), nullptr, &target), "drawing a window");
        const float clear[4] = {0, 0, 0, 0};
        context->ClearRenderTargetView(target.Get(), clear);
        if (look) {
            CardParams p{};
            p.rect[0] = look->left;
            p.rect[1] = look->top;
            p.rect[2] = look->right;
            p.rect[3] = look->bottom;
            std::memcpy(p.crop, look->crop, sizeof p.crop);
            p.radius = look->radius;
            p.border = look->border;
            p.opacity = look->opacity;
            p.picture = luma ? 1.0f : 0.0f;
            context->UpdateSubresource(params.Get(), 0, nullptr, &p, 0, 0);
            D3D11_VIEWPORT viewport{0, 0, float(s.w), float(s.h), 0, 1};
            context->RSSetViewports(1, &viewport);
            context->OMSetRenderTargets(1, target.GetAddressOf(), nullptr);
            context->OMSetBlendState(blend.Get(), nullptr, 0xFFFFFFFF);
            context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context->IASetInputLayout(nullptr);
            context->VSSetShader(vs.Get(), nullptr, 0);
            context->PSSetShader(ps.Get(), nullptr, 0);
            ID3D11ShaderResourceView* views[2] = {lumaView.Get(), chromaView.Get()};
            context->PSSetShaderResources(0, 2, views);
            context->PSSetSamplers(0, 1, sampler.GetAddressOf());
            context->PSSetConstantBuffers(0, 1, params.GetAddressOf());
            context->Draw(3, 0);
            ID3D11RenderTargetView* none = nullptr;
            context->OMSetRenderTargets(1, &none, nullptr);
        }
        capture::check(s.chain->Present(0, 0), "showing a window");
        s.empty = look == nullptr;
    }
};

Overlay::Overlay() {
    registerClass(stageClass, windowProc);
    registerClass(bubbleClass, windowProc);
    // The stage lets every click through to what is under it (layered and transparent to the mouse).
    stage_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOREDIRECTIONBITMAP,
                             stageClass, L"Vidlark stage", WS_POPUP, 0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (stage_) SetLayeredWindowAttributes(stage_, 0, 255, LWA_ALPHA);
    // The bubble can be dragged anywhere.
    bubbleWindow_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_NOREDIRECTIONBITMAP, bubbleClass,
                                    L"Vidlark face", WS_POPUP, 0, 0, 200, 200, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    for (HWND w : {stage_, bubbleWindow_}) {
        if (w) SetWindowLongPtrW(w, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    }
    thread_ = std::thread([this] { run(); });
}

Overlay::~Overlay() {
    {
        std::lock_guard guard(lock_);
        quit_ = true;
    }
    woken_.notify_all();
    if (thread_.joinable()) thread_.join();
    for (HWND w : {stage_, bubbleWindow_}) {
        if (w) {
            SetWindowLongPtrW(w, GWLP_USERDATA, 0);
            DestroyWindow(w);
        }
    }
}

void Overlay::wake() {
    {
        std::lock_guard guard(lock_);
        kick_ = true;
    }
    woken_.notify_all();
}

std::string Overlay::problem() const {
    std::lock_guard guard(lock_);
    return problem_;
}

RECT Overlay::bubbleRect() const {
    std::lock_guard guard(lock_);
    return bubble_;
}

void Overlay::camera(const BYTE* nv12, LONG pitch, UINT32 width, UINT32 height) {
    if (!wantsCamera_ || !nv12 || width < 2 || height < 2) return;
    {
        std::lock_guard guard(lock_);
        width &= ~1u;
        height &= ~1u;
        luma_.resize(static_cast<size_t>(width) * height);
        chroma_.resize(static_cast<size_t>(width) * height / 2);
        for (UINT32 row = 0; row < height; row++) std::memcpy(&luma_[static_cast<size_t>(row) * width], nv12 + static_cast<size_t>(row) * pitch, width);
        const BYTE* uv = nv12 + static_cast<size_t>(pitch) * height;
        for (UINT32 row = 0; row < height / 2; row++) std::memcpy(&chroma_[static_cast<size_t>(row) * width], uv + static_cast<size_t>(row) * pitch, width);
        cameraW_ = width;
        cameraH_ = height;
        cameraAspect_ = float(width) / float(height);
        cameraFrame_++;
        kick_ = true;
    }
    woken_.notify_all();
}

// Her camera across the whole area, cropped to fill it, keeping a little more of the top: faces sit high.
Overlay::Look Overlay::fullLook() const {
    Look look;
    look.left = float(area_.left);
    look.top = float(area_.top);
    look.right = float(area_.right);
    look.bottom = float(area_.bottom);
    look.opacity = 1;
    const float areaAspect = std::max(1.0f, look.right - look.left) / std::max(1.0f, look.bottom - look.top);
    if (cameraAspect_ > areaAspect) {
        const float w = areaAspect / cameraAspect_;
        look.crop[0] = (1 - w) / 2;
        look.crop[2] = look.crop[0] + w;
    } else {
        const float h = cameraAspect_ / areaAspect;
        look.crop[1] = (1 - h) * 0.4f;
        look.crop[3] = look.crop[1] + h;
    }
    return look;
}

// Her face in the bubble: a square from the middle of the camera picture, a little above centre.
// (The Mac follows her face with Vision; Windows face framing comes later.)
Overlay::Look Overlay::bubbleLook() const {
    Look look;
    look.left = float(bubble_.left);
    look.top = float(bubble_.top);
    look.right = float(bubble_.right);
    look.bottom = float(bubble_.bottom);
    look.radius = (look.right - look.left) / 2;
    look.border = 3 * scaleFor(bubble_);
    look.opacity = bubbleOn_ ? 1.0f : 0.0f;
    if (cameraAspect_ >= 1) {
        const float w = 1 / cameraAspect_;
        look.crop[0] = (1 - w) / 2;
        look.crop[2] = look.crop[0] + w;
    } else {
        const float h = cameraAspect_;
        look.crop[1] = (1 - h) * 0.4f;
        look.crop[3] = look.crop[1] + h;
    }
    return look;
}

void Overlay::placeBubble() {
    RECT area, work;
    bool placed;
    {
        std::lock_guard guard(lock_);
        area = area_;
        work = work_;
        placed = bubblePlaced_;
    }
    const float scale = scaleFor(area);
    const int size = static_cast<int>(std::lround(200 * scale));
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(MonitorFromRect(&area, MONITOR_DEFAULTTONEAREST), &info);
    const bool wholeScreen = EqualRect(&area, &info.rcMonitor);
    int x, y;
    if (wholeScreen) {
        // Bottom right of the screen, above the taskbar, where a face cam usually sits, until it is dragged.
        if (placed) return;
        const RECT& r = IsRectEmpty(&work) ? area : work;
        x = r.right - size - static_cast<int>(24 * scale);
        y = r.bottom - size - static_cast<int>(24 * scale);
    } else {
        // Bottom right of the shared window, following it.
        x = area.right - size - static_cast<int>(12 * scale);
        y = area.bottom - size - static_cast<int>(12 * scale);
    }
    SetWindowPos(bubbleWindow_, HWND_TOPMOST, x, y, size, size, SWP_NOACTIVATE);
    std::lock_guard guard(lock_);
    bubble_ = RECT{x, y, x + size, y + size};
}

void Overlay::cover(const RECT& area, const RECT& work) {
    {
        std::lock_guard guard(lock_);
        area_ = area;
        work_ = work;
        covering_ = true;
    }
    SetWindowPos(stage_, HWND_TOPMOST, area.left, area.top, area.right - area.left, area.bottom - area.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    placeBubble();
    {
        // Her camera across the area follows a shared window too.
        std::lock_guard guard(lock_);
        if (me_ && moveDone_) to_ = fullLook();
    }
    wake();
}

void Overlay::showMe(bool animated) {
    ShowWindow(bubbleWindow_, SW_HIDE);
    {
        std::lock_guard guard(lock_);
        me_ = true;
        wantsCamera_ = true;
        from_ = bubbleLook();
        to_ = fullLook();
        moveStart_ = GetTickCount64();
        moveLength_ = animated ? moveMs : 0;
        moveDone_ = !animated;
        if (!animated) ready_ = false;
    }
    wake();
}

void Overlay::showScreen(bool animated) {
    {
        std::lock_guard guard(lock_);
        me_ = false;
        wantsCamera_ = bubbleOn_.load();
        from_ = fullLook();
        to_ = bubbleLook();
        moveStart_ = GetTickCount64();
        moveLength_ = animated ? moveMs : 0;
        moveDone_ = !animated;
    }
    if (!animated && bubbleOn_) ShowWindow(bubbleWindow_, SW_SHOWNOACTIVATE);
    wake();
}

void Overlay::setBubble(bool visible) {
    bubbleOn_ = visible;
    bool showNow;
    {
        std::lock_guard guard(lock_);
        wantsCamera_ = me_ || visible;
        showNow = covering_ && !me_ && moveDone_;
    }
    if (showNow) ShowWindow(bubbleWindow_, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    wake();
}

void Overlay::hide() {
    {
        std::lock_guard guard(lock_);
        covering_ = false;
        me_ = false;
        moveDone_ = true;
        wantsCamera_ = false;
        ready_ = false;
        bubblePlaced_ = false;
    }
    ShowWindow(stage_, SW_HIDE);
    ShowWindow(bubbleWindow_, SW_HIDE);
    wake();
}

void Overlay::run() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    while (true) {
        {
            std::unique_lock guard(lock_);
            const auto wait = std::chrono::milliseconds(!moveDone_ ? 15 : 250);
            woken_.wait_for(guard, wait, [this] { return quit_ || kick_; });
            if (quit_) break;
            kick_ = false;
        }
        try {
            draw();
        } catch (const std::exception& error) {
            std::lock_guard guard(lock_);
            if (problem_.empty()) problem_ = error.what();
        }
    }
    gpu_.reset();
    CoUninitialize();
}

void Overlay::draw() {
    Look stageLook, bubbleCard;
    bool covering, me, bubbleOn, moving, arrived = false;
    RECT area, bubble;
    bool newPicture = false;
    {
        std::lock_guard guard(lock_);
        covering = covering_;
        me = me_;
        bubbleOn = bubbleOn_;
        area = area_;
        bubble = bubble_;
        moving = !moveDone_;
        if (moving) {
            const float t = std::min(1.0f, float(GetTickCount64() - moveStart_) / float(std::max<ULONGLONG>(1, moveLength_)));
            stageLook = mix(from_, to_, ease(t));
            if (t >= 1) {
                moveDone_ = true;
                arrived = !me_;
            }
        } else {
            stageLook = me_ ? fullLook() : to_;
        }
        bubbleCard = bubbleLook();
        newPicture = gpu_ && cameraFrame_ != gpu_->uploaded && cameraW_ > 0;
    }
    if (!covering) {
        gpu_.reset();  // nothing shows between takes: the graphics memory goes back
        return;
    }
    if (!gpu_) {
        gpu_ = std::make_unique<Gpu>();
        newPicture = true;
    }
    {
        std::lock_guard guard(lock_);
        if (cameraW_ > 0 && cameraFrame_ != gpu_->uploaded) {
            gpu_->upload(luma_, chroma_, cameraW_, cameraH_);
            gpu_->uploaded = cameraFrame_;
        }
    }
    (void)newPicture;

    // The stage: the card while it fills the area or moves; see-through once it rests in the bubble.
    gpu_->fit(gpu_->stage, stage_, area.right - area.left, area.bottom - area.top);
    if (me || moving || arrived) {
        Look local = stageLook;
        local.left -= area.left;
        local.right -= area.left;
        local.top -= area.top;
        local.bottom -= area.top;
        gpu_->render(gpu_->stage, &local);
        if (me && !moving && gpu_->luma) ready_ = true;
    } else {
        gpu_->render(gpu_->stage, nullptr);
    }

    // The bubble window: her face, while the video shows the screen.
    if (bubbleOn && !me) {
        gpu_->fit(gpu_->bubble, bubbleWindow_, bubble.right - bubble.left, bubble.bottom - bubble.top);
        Look local = bubbleCard;
        local.right -= local.left;
        local.bottom -= local.top;
        local.left = 0;
        local.top = 0;
        gpu_->render(gpu_->bubble, &local);
    }
    // The card has shrunk into the bubble: the bubble window takes over, and the stage empties next time.
    if (arrived) PostMessageW(bubbleWindow_, bubbleArrived, 0, 0);
}

LRESULT CALLBACK Overlay::windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto* self = reinterpret_cast<Overlay*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_NCHITTEST:
        if (self && window == self->bubbleWindow_) {
            // Drag the bubble by any part of its circle.
            RECT r;
            GetWindowRect(window, &r);
            const float cx = (r.left + r.right) / 2.0f, cy = (r.top + r.bottom) / 2.0f, radius = (r.right - r.left) / 2.0f;
            const float dx = GET_X_LPARAM(lParam) - cx, dy = GET_Y_LPARAM(lParam) - cy;
            return dx * dx + dy * dy <= radius * radius ? HTCAPTION : HTTRANSPARENT;
        }
        return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_WINDOWPOSCHANGED:
        if (self && window == self->bubbleWindow_) {
            RECT r;
            GetWindowRect(window, &r);
            std::lock_guard guard(self->lock_);
            self->bubble_ = r;
        }
        break;
    case WM_EXITSIZEMOVE:
        if (self && window == self->bubbleWindow_) {
            std::lock_guard guard(self->lock_);
            self->bubblePlaced_ = true;  // dragged: it stays where she put it
        }
        break;
    case bubbleArrived:
        if (self) {
            bool show;
            {
                std::lock_guard guard(self->lock_);
                show = self->covering_ && !self->me_ && self->bubbleOn_ && self->moveDone_;
            }
            if (show) ShowWindow(self->bubbleWindow_, SW_SHOWNOACTIVATE);
            self->wake();
        }
        return 0;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace app
