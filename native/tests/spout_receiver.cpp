#include <windows.h>
#include <wrl/client.h>
#include "SpoutDX.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) return 2;
    spoutDX receiver;
    receiver.SetReceiverName("BengRender");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (std::chrono::steady_clock::now() < deadline) {
        if (!receiver.ReceiveTexture() || !receiver.GetSenderTexture() || !receiver.IsFrameNew()) { std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
        auto* texture = receiver.GetSenderTexture();
        D3D11_TEXTURE2D_DESC desc{};
        texture->GetDesc(&desc);
        if (desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM || !desc.Width || !desc.Height) return 3;
        auto staging_desc = desc;
        staging_desc.Usage = D3D11_USAGE_STAGING; staging_desc.BindFlags = 0;
        staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ; staging_desc.MiscFlags = 0;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> staging;
        if (FAILED(receiver.GetDX11Device()->CreateTexture2D(&staging_desc, nullptr, &staging))) return 4;
        auto* context = receiver.GetDX11Context();
        context->CopyResource(staging.Get(), texture);
        D3D11_MAPPED_SUBRESOURCE map{};
        if (FAILED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &map))) return 5;
        unsigned char samples[4][4]{};
        const unsigned positions[4][2] = {{desc.Width / 4, desc.Height / 4}, {3 * desc.Width / 4, desc.Height / 4}, {desc.Width / 4, 3 * desc.Height / 4}, {3 * desc.Width / 4, 3 * desc.Height / 4}};
        for (int index = 0; index < 4; ++index) {
            const auto* pixel = static_cast<unsigned char*>(map.pData) + positions[index][1] * map.RowPitch + positions[index][0] * 4;
            std::memcpy(samples[index], pixel, 4);
        }
        context->Unmap(staging.Get(), 0);
        if (samples[0][0] < 240 || samples[0][3] < 240) continue;
        std::ofstream report{std::filesystem::path(argv[1])};
        report << "{\"width\":" << desc.Width << ",\"height\":" << desc.Height << ",\"dxgi_format\":" << desc.Format << ",\"samples\":[";
        for (int index = 0; index < 4; ++index) {
            if (index) report << ',';
            report << '[' << static_cast<int>(samples[index][0]) << ',' << static_cast<int>(samples[index][1]) << ',' << static_cast<int>(samples[index][2]) << ',' << static_cast<int>(samples[index][3]) << ']';
        }
        report << "]}";
        const bool valid = samples[0][0] > 240 && samples[0][1] < 10 && samples[0][2] < 10 && samples[0][3] > 240
            && samples[1][0] < 10 && samples[1][1] > 110 && samples[1][2] < 10 && samples[1][3] >= 120 && samples[1][3] <= 136
            && samples[2][0] < 10 && samples[2][1] < 10 && samples[2][2] > 240 && samples[2][3] > 240
            && samples[3][3] < 5;
        receiver.ReleaseReceiver();
        std::cout << (valid ? "SPOUT_RGBA_PASS" : "SPOUT_RGBA_FAIL") << std::endl;
        return valid ? 0 : 6;
    }
    std::cerr << "Spout receiver timed out" << std::endl;
    return 1;
}
