#include "mmd_pmx.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <cstring>

template <class T> void put(std::string& out, T value) { out.append(reinterpret_cast<char*>(&value), sizeof(value)); }
void text(std::string& out, const std::string& value) { put<uint32_t>(out, static_cast<uint32_t>(value.size())); out += value; }
void zeros(std::string& out, int count) { for (int i = 0; i < count; ++i) put<float>(out, 0); }
std::string fixture() {
    std::string out = "PMX "; put<float>(out, 2.0f);
    for (uint8_t value : {8, 1, 0, 1, 1, 1, 1, 1, 1}) put<uint8_t>(out, value);
    text(out, "模型"); text(out, ""); text(out, ""); text(out, "");
    put<uint32_t>(out, 3);
    for (int i = 0; i < 3; ++i) {
        put<float>(out, i == 1 ? 1.f : 0.f); put<float>(out, i == 2 ? 1.f : 0.f); put<float>(out, 0);
        zeros(out, 2); put<float>(out, 1); zeros(out, 2);
        put<uint8_t>(out, 0); put<uint8_t>(out, 0); put<float>(out, 1);
    }
    put<uint32_t>(out, 3); for (uint8_t i : {0, 1, 2}) put<uint8_t>(out, i);
    put<uint32_t>(out, 1); text(out, "贴图.png");
    put<uint32_t>(out, 1); text(out, "颜"); text(out, "");
    for (int i = 0; i < 4; ++i) put<float>(out, 1); zeros(out, 7);
    put<uint8_t>(out, 0x1d); zeros(out, 4); put<float>(out, 1);
    put<uint8_t>(out, 0); put<uint8_t>(out, 255); put<uint8_t>(out, 0); put<uint8_t>(out, 1); put<uint8_t>(out, 0);
    text(out, ""); put<uint32_t>(out, 3);
    put<uint32_t>(out, 1); text(out, "頭"); text(out, ""); zeros(out, 3);
    put<uint8_t>(out, 255); put<uint32_t>(out, 0); put<uint16_t>(out, 0); zeros(out, 3);
    for (int i = 0; i < 4; ++i) put<uint32_t>(out, 0);
    return out;
}
void parse(const std::string& bytes) {
    std::istringstream input(bytes); input.exceptions(std::ios::badbit | std::ios::failbit);
    kaitai::kstream stream(&input); mmd_pmx_t model(&stream);
    if (model.header()->model_name()->value() != "模型" || model.materials()->at(0)->name()->value() != "颜") throw std::runtime_error("Unicode changed");
}
void reject(const std::string& bytes) {
    try { parse(bytes); } catch (const std::exception&) { return; }
    throw std::runtime_error("Invalid model was accepted");
}
int main(int argc, char** argv) {
    try {
        auto bytes = fixture(); parse(bytes);
        auto bad = bytes; bad[0] = 'X'; reject(bad);
        bad = bytes; bad.resize(bad.size() - 1); reject(bad);
        bad = bytes; bad[11] = 3; reject(bad);
        bad = bytes; uint32_t huge = 0xffffffff; std::memcpy(bad.data() + 39, &huge, 4); reject(bad);
        for (int i = 1; i < argc; ++i) {
            std::ifstream input(std::filesystem::u8path(argv[i]), std::ios::binary);
            input.exceptions(std::ios::badbit | std::ios::failbit);
            kaitai::kstream stream(&input); mmd_pmx_t model(&stream);
            std::cout << "PMX_FILE " << model.header()->model_name()->value() << " vertices=" << model.vertex_count() << " faces=" << model.face_vertex_count()/3 << " materials=" << model.material_count() << " bones=" << model.bone_count() << " morphs=" << model.morph_count() << " bodies=" << model.rigid_body_count() << '\n';
        }
        std::cout << "PMX_PARSER_PASS UTF8 Chinese, malformed header, truncation and count bounds\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
