#include "spout_output.hpp"
#include <windows.h>
#include <d3d12.h>
#include <d3d11on12.h>
#include <wrl/client.h>
#include "SpoutDX.h"
#include <sstream>
#include <stdexcept>

namespace mocap {
using Microsoft::WRL::ComPtr;
namespace {
void check(HRESULT result, const char* message) {
    if (FAILED(result)) {
        std::ostringstream error; error << message << " (0x" << std::hex << static_cast<unsigned long>(result) << ")";
        throw std::runtime_error(error.str());
    }
}
}

struct SpoutOutput::Impl {
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12Resource> texture;
    ComPtr<ID3D11Device> device11;
    ComPtr<ID3D11DeviceContext> context11;
    ComPtr<ID3D11On12Device> bridge;
    ComPtr<ID3D11Resource> wrapped;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList7> commands;
    ComPtr<ID3D12Fence> fence;
    std::unique_ptr<spoutDX> sender;
    HANDLE event = nullptr;
    std::uint64_t fence_value = 0;
    bool enhanced = false;

    ~Impl() { if (event) CloseHandle(event); }
    void wait() {
        if (!queue || !fence) return;
        const auto value = ++fence_value;
        check(queue->Signal(fence.Get(), value), "Cannot signal video output fence");
        if (fence->GetCompletedValue() < value) {
            check(fence->SetEventOnCompletion(value, event), "Cannot wait for video output");
            if (WaitForSingleObject(event, 5000) != WAIT_OBJECT_0) throw std::runtime_error("Video output GPU fence timed out");
        }
    }
    void transition(bool to_common) {
        if (!enhanced) return;
        wait();
        check(allocator->Reset(), "Cannot reset video output allocator");
        check(commands->Reset(allocator.Get(), nullptr), "Cannot reset video output command list");
        D3D12_TEXTURE_BARRIER texture_barrier{};
        texture_barrier.SyncBefore = D3D12_BARRIER_SYNC_ALL;
        texture_barrier.SyncAfter = D3D12_BARRIER_SYNC_ALL;
        texture_barrier.AccessBefore = to_common ? D3D12_BARRIER_ACCESS_COPY_DEST : D3D12_BARRIER_ACCESS_COMMON;
        texture_barrier.AccessAfter = to_common ? D3D12_BARRIER_ACCESS_COMMON : D3D12_BARRIER_ACCESS_COPY_DEST;
        texture_barrier.LayoutBefore = to_common ? D3D12_BARRIER_LAYOUT_COPY_DEST : D3D12_BARRIER_LAYOUT_COMMON;
        texture_barrier.LayoutAfter = to_common ? D3D12_BARRIER_LAYOUT_COMMON : D3D12_BARRIER_LAYOUT_COPY_DEST;
        texture_barrier.pResource = texture.Get();
        texture_barrier.Subresources.IndexOrFirstMipLevel = UINT32_MAX;
        D3D12_BARRIER_GROUP group{};
        group.Type = D3D12_BARRIER_TYPE_TEXTURE;
        group.NumBarriers = 1;
        group.pTextureBarriers = &texture_barrier;
        commands->Barrier(1, &group);
        check(commands->Close(), "Cannot finish video output barrier");
        ID3D12CommandList* lists[] = {commands.Get()};
        queue->ExecuteCommandLists(1, lists);
    }
};

SpoutOutput::SpoutOutput() : impl(std::make_unique<Impl>()) {}
SpoutOutput::~SpoutOutput() { try { close(); } catch (...) {} }

std::uint64_t SpoutOutput::create(std::uint64_t device_pointer, std::uint64_t queue_pointer, int width, int height) {
    close();
    if (!device_pointer || !queue_pointer || width < 16 || width > 3840 || height < 16 || height > 2160) throw std::invalid_argument("Invalid D3D12 output device or dimensions");
    auto& state = *impl;
    state.device = reinterpret_cast<ID3D12Device*>(device_pointer);
    state.queue = reinterpret_cast<ID3D12CommandQueue*>(queue_pointer);
    D3D12_FEATURE_DATA_D3D12_OPTIONS12 options{};
    state.enhanced = SUCCEEDED(state.device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS12, &options, sizeof(options))) && options.EnhancedBarriersSupported;
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    heap.CreationNodeMask = heap.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = width; desc.Height = height; desc.DepthOrArraySize = 1; desc.MipLevels = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    const auto initial_state = state.enhanced ? D3D12_RESOURCE_STATE_COMMON : D3D12_RESOURCE_STATE_RENDER_TARGET;
    check(state.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, initial_state, nullptr, IID_PPV_ARGS(&state.texture)), "Cannot create RGBA output texture");
    check(state.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&state.fence)), "Cannot create output fence");
    state.event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!state.event) throw std::runtime_error("Cannot create output synchronization event");
    if (state.enhanced) {
        check(state.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&state.allocator)), "Cannot create output command allocator");
        ComPtr<ID3D12GraphicsCommandList> base;
        check(state.device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, state.allocator.Get(), nullptr, IID_PPV_ARGS(&base)), "Cannot create output command list");
        check(base.As(&state.commands), "GPU does not expose enhanced barrier command lists");
        check(state.commands->Close(), "Cannot initialize output command list");
    }
    IUnknown* queues[] = {state.queue.Get()};
    check(D3D11On12CreateDevice(state.device.Get(), D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, queues, 1, 0, &state.device11, &state.context11, nullptr), "Cannot create D3D11-on-12 video output");
    check(state.device11.As(&state.bridge), "Cannot query D3D11-on-12 output bridge");
    D3D11_RESOURCE_FLAGS flags{};
    const auto external_state = state.enhanced ? D3D12_RESOURCE_STATE_COMMON : D3D12_RESOURCE_STATE_COPY_DEST;
    check(state.bridge->CreateWrappedResource(state.texture.Get(), &flags, external_state, external_state, IID_PPV_ARGS(&state.wrapped)), "Cannot wrap RGBA video output texture");
    state.sender = std::make_unique<spoutDX>();
    if (!state.sender->OpenDirectX11(state.device11.Get())) throw std::runtime_error("Cannot initialize Spout2 sender");
    state.sender->SetSenderName("BengRender");
    state.sender->SetSenderFormat(DXGI_FORMAT_R8G8B8A8_UNORM);
    return reinterpret_cast<std::uint64_t>(state.texture.Get());
}

bool SpoutOutput::send() {
    auto& state = *impl;
    if (!state.sender || !state.wrapped) throw std::runtime_error("Video output is not initialized");
    // Godot 4.7 selects enhanced barriers using OPTIONS12; restore its tracked COPY_DEST layout after interop.
    state.transition(true);
    ID3D11Resource* resources[] = {state.wrapped.Get()};
    state.bridge->AcquireWrappedResources(resources, 1);
    ComPtr<ID3D11Texture2D> texture11;
    HRESULT query = state.wrapped.As(&texture11);
    bool sent = SUCCEEDED(query) && state.sender->SendTexture(texture11.Get());
    state.bridge->ReleaseWrappedResources(resources, 1);
    state.context11->Flush();
    state.transition(false);
    check(query, "Cannot query wrapped video texture");
    if (!sent) throw std::runtime_error("Spout2 could not share the video texture");
    return true;
}

void SpoutOutput::close() {
    if (!impl) return;
    if (impl->context11) impl->context11->Flush();
    impl->wait();
    if (impl->sender) { impl->sender->ReleaseSender(); impl->sender->CloseDirectX11(); }
    impl->wrapped.Reset();
    if (impl->context11) impl->context11->Flush();
    impl->wait();
    impl = std::make_unique<Impl>();
}

std::string SpoutOutput::sender_name() const {
    return impl->sender ? impl->sender->GetSenderName() : "";
}
}
