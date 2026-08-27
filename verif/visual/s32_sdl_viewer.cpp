#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

static bool load_ppm(const fs::path& path, int& width, int& height,
                     std::vector<unsigned char>& rgb) {
    std::ifstream in(path);
    std::string magic;
    int maximum = 0;
    if (!(in >> magic >> width >> height >> maximum) || magic != "P3" ||
        maximum != 255 || width <= 0 || height <= 0)
        return false;
    rgb.resize(static_cast<size_t>(width) * height * 3);
    for (auto& sample : rgb) {
        int value = 0;
        if (!(in >> value)) return false;
        sample = static_cast<unsigned char>(value);
    }
    return true;
}

static void write_input(const fs::path& path, unsigned value) {
    const fs::path temporary = path.string() + ".tmp";
    {
        std::ofstream out(temporary);
        out << std::hex << value << '\n';
    }
    std::error_code ec;
    fs::remove(path, ec);
    fs::rename(temporary, path, ec);
}

static unsigned key_mask(SDL_Keycode key) {
    switch (key) {
    case SDLK_LEFT: return 0x080;
    case SDLK_RIGHT: return 0x040;
    case SDLK_UP: return 0x020;
    case SDLK_DOWN: return 0x010;
    case SDLK_z: case SDLK_a: return 0x001;
    case SDLK_x: case SDLK_s: return 0x002;
    case SDLK_c: case SDLK_d: return 0x004;
    case SDLK_5: return 0x100;
    case SDLK_6: return 0x200;
    case SDLK_q: return 0x400;
    case SDLK_e: return 0x800;
    default: return 0;
    }
}

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    const fs::path live = fs::absolute(argv[1]);
    const fs::path input = fs::absolute(argv[2]);
    SDL_SetMainReady();
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) return 3;
    SDL_Window* window = SDL_CreateWindow(
        "Sega System 32 - Verilator (waiting for build/frame)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 832, 560,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
    SDL_Renderer* renderer = SDL_CreateRenderer(
        window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    SDL_Texture* texture = nullptr;
    int texture_w = 0, texture_h = 0;
    fs::file_time_type last_ready{};
    unsigned input_mask = 0;
    write_input(input, input_mask);
    bool running = window && renderer;
    while (running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT ||
                (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE))
                running = false;
            if ((event.type == SDL_KEYDOWN && !event.key.repeat) ||
                event.type == SDL_KEYUP) {
                const unsigned bit = key_mask(event.key.keysym.sym);
                if (event.type == SDL_KEYDOWN) input_mask |= bit;
                else input_mask &= ~bit;
                write_input(input, input_mask);
            }
        }
        const fs::path ready = live.string() + ".ready";
        std::error_code ec;
        if (fs::exists(ready, ec)) {
            const auto ready_time = fs::last_write_time(ready, ec);
            if (!ec && ready_time != last_ready) {
                std::ifstream metadata(ready);
                long long frame = -1;
                int slot = 0;
                if (metadata >> frame >> slot) {
                    int width = 0, height = 0;
                    std::vector<unsigned char> rgb;
                    if (load_ppm(live.string() + "." + std::to_string(slot),
                                 width, height, rgb)) {
                        if (!texture || width != texture_w || height != texture_h) {
                            if (texture) SDL_DestroyTexture(texture);
                            texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB24,
                                SDL_TEXTUREACCESS_STREAMING, width, height);
                            texture_w = width;
                            texture_h = height;
                        }
                        SDL_UpdateTexture(texture, nullptr, rgb.data(), width * 3);
                        const std::string title = "Sega System 32 - Verilator | frame " +
                                                  std::to_string(frame);
                        SDL_SetWindowTitle(window, title.c_str());
                        last_ready = ready_time;
                    }
                }
            }
        }
        SDL_SetRenderDrawColor(renderer, 17, 17, 17, 255);
        SDL_RenderClear(renderer);
        if (texture) SDL_RenderCopy(renderer, texture, nullptr, nullptr);
        SDL_RenderPresent(renderer);
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    write_input(input, 0);
    if (texture) SDL_DestroyTexture(texture);
    if (renderer) SDL_DestroyRenderer(renderer);
    if (window) SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
