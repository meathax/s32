// Savable timing-loop frontend for the visible System 32 Verilator model.
#include "verilated.h"
#include "verilated_save.h"
#include "Vtb_core_romboot.h"
#include "Vtb_core_romboot___024root.h"

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>

static double g_sc_time = 0.0;
double sc_time_stamp() { return g_sc_time; }

namespace {

// Verilator's POSIX save helper opens descriptors in the host CRT's default
// text mode on native Windows.  That silently rewrites binary 0x0a bytes and
// makes a later restore stop before the trailer.  Keep the generated model
// serializer, but provide a small binary stream adapter for this Windows
// visual harness.
class BinarySave final : public VerilatedSerialize {
    std::ofstream file_;

public:
    void open(const std::string& path) {
        file_.open(path, std::ios::binary | std::ios::trunc);
        if (!file_) return;
        m_filename = path;
        m_isOpen = true;
        m_cp = m_bufp;
        header();
    }
    void flush() override {
        if (!m_isOpen) return;
        file_.write(reinterpret_cast<const char*>(m_bufp), m_cp - m_bufp);
        file_.flush();
        m_cp = m_bufp;
    }
    void close() override {
        if (!m_isOpen) return;
        trailer();
        flush();
        file_.close();
        m_isOpen = false;
    }
    ~BinarySave() override { close(); }
};

class BinaryRestore final : public VerilatedDeserialize {
    std::ifstream file_;

public:
    void open(const std::string& path) {
        file_.open(path, std::ios::binary);
        if (!file_) return;
        m_filename = path;
        m_isOpen = true;
        m_cp = m_bufp;
        m_endp = m_bufp;
        header();
    }
    void fill() override {
        if (!m_isOpen) return;
        uint8_t* dst = m_bufp;
        for (const uint8_t* src = m_cp; src < m_endp; *dst++ = *src++) {}
        m_endp = dst;
        m_cp = m_bufp;
        const std::streamsize room =
            static_cast<std::streamsize>(m_bufp + bufferSize() - m_endp);
        file_.read(reinterpret_cast<char*>(m_endp), room);
        const std::streamsize got = file_.gcount();
        if (got > 0) m_endp += got;
        while (m_endp < m_bufp + bufferSize()) *m_endp++ = 0;
    }
    void close() override {
        if (!m_isOpen) return;
        trailer();
        file_.close();
        m_isOpen = false;
    }
    ~BinaryRestore() override { close(); }
};

std::string plusarg_value(int argc, char** argv, const char* key) {
    const std::string prefix = std::string{"+"} + key + "=";
    for (int i = 1; i < argc; ++i) {
        if (std::strncmp(argv[i], prefix.c_str(), prefix.size()) == 0)
            return argv[i] + prefix.size();
    }
    return {};
}

void save_checkpoint(const std::string& path, VerilatedContext* contextp,
                     Vtb_core_romboot* topp) {
    BinarySave stream;
    stream.open(path);
    // The generated model serializer already includes its owning context
    // (Vtb_core_romboot___024root::__Vserialize writes _vm_contextp__).
    // Serializing the context a second time here makes the stream layout
    // disagree with the model restore path and leaves the trailer unread.
    stream << *topp;
    stream.close();
    VL_PRINTF("Saved full-state checkpoint: %s at t=%llu\n", path.c_str(),
              static_cast<unsigned long long>(contextp->time()));
}

}  // namespace

int main(int argc, char** argv, char**) {
    Verilated::debug(0);
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->threads(1);
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<Vtb_core_romboot> topp{
        new Vtb_core_romboot{contextp.get(), ""}};

    const std::string restore_path = plusarg_value(argc, argv, "RESTORE");
    const std::string save_path = plusarg_value(argc, argv, "SAVE");
    const std::string autosave_frame_text =
        plusarg_value(argc, argv, "AUTOSAVEFRAME");
    const std::string postrestore_frames_text =
        plusarg_value(argc, argv, "POSTRESTOREFRAMES");
    const std::string max_frames_text = plusarg_value(argc, argv, "FRAMES");
    const std::string live_ppm_text = plusarg_value(argc, argv, "LIVEPPM");
    const std::string live_every_text = plusarg_value(argc, argv, "LIVEEVERY");
    const std::string dump_at_text = plusarg_value(argc, argv, "DUMPAT");
    const std::string dump_n_text = plusarg_value(argc, argv, "DUMPN");
    const std::string dump_every_text = plusarg_value(argc, argv, "DUMPEVERY");
    const std::string adc0_text = plusarg_value(argc, argv, "ADC0");
    long long autosave_frame = -1;
    if (!autosave_frame_text.empty())
        autosave_frame = std::strtoll(autosave_frame_text.c_str(), nullptr, 10);

    if (!restore_path.empty()) {
        // Verilator deliberately omits large read-only memories from the
        // savable state. Run the initial blocks once so the ROM images loaded
        // by $readmemh/$fread are resident before applying the checkpoint.
        // The serialized RTL state then overwrites the one initialization
        // tick, leaving the model at the exact saved boundary.
        topp->eval();
        BinaryRestore stream;
        stream.open(restore_path);
        stream >> *topp;
        stream.close();
        VL_PRINTF("Restored full-state checkpoint: %s at t=%llu\n",
                  restore_path.c_str(),
                  static_cast<unsigned long long>(contextp->time()));
        if (!postrestore_frames_text.empty()) {
            topp->rootp->tb_core_romboot__DOT__cur_frame =
                static_cast<uint32_t>(std::strtoul(
                    postrestore_frames_text.c_str(), nullptr, 10));
            VL_PRINTF("Post-restore frame barrier: %u\n",
                      topp->rootp->tb_core_romboot__DOT__cur_frame);
        }
        // The testbench's max-frame argument is also savable state, so the
        // checkpoint carries the short cold-run limit. Reapply the requested
        // long-run limit after restore.
        if (!max_frames_text.empty()) {
            topp->rootp->tb_core_romboot__DOT__frames =
                static_cast<uint32_t>(std::strtoul(
                    max_frames_text.c_str(), nullptr, 10));
            VL_PRINTF("Post-restore frame limit: %u\n",
                      topp->rootp->tb_core_romboot__DOT__frames);
        }
        if (!live_every_text.empty())
            topp->rootp->tb_core_romboot__DOT__live_every =
                static_cast<uint32_t>(std::strtoul(live_every_text.c_str(), nullptr, 10));
        // LIVEPPM is a host-side capture destination, not savable RTL state.
        // Checkpoints made without a viewer restore an empty path, so reapply
        // the requested absolute path and arm the ready-file publication.
        if (!live_ppm_text.empty()) {
            topp->rootp->tb_core_romboot__DOT__live_ppm_path = live_ppm_text;
            topp->rootp->tb_core_romboot__DOT__live_ready_path = live_ppm_text + ".ready";
            topp->rootp->tb_core_romboot__DOT__live_ppm = 1;
        }
        if (!dump_at_text.empty())
            topp->rootp->tb_core_romboot__DOT__dump_at =
                static_cast<uint32_t>(std::strtol(dump_at_text.c_str(), nullptr, 10));
        if (!dump_n_text.empty())
            topp->rootp->tb_core_romboot__DOT__dump_n =
                static_cast<uint32_t>(std::strtoul(dump_n_text.c_str(), nullptr, 10));
        if (!dump_every_text.empty())
            topp->rootp->tb_core_romboot__DOT__dump_every =
                static_cast<uint32_t>(std::strtoul(dump_every_text.c_str(), nullptr, 10));
        // Steering is host scenario input. A restored checkpoint otherwise
        // retains the ADC0 value from the run that created it, ignoring the
        // replay command line just like the frame/capture controls above.
        if (!adc0_text.empty())
            topp->rootp->tb_core_romboot__DOT__adc0_override =
                static_cast<uint32_t>(std::strtoul(adc0_text.c_str(), nullptr, 16));
    }

    // One host tick is half a clk_ram period (5.175 ns). clk_sys toggles every
    // second tick, preserving the original 2:1 clock relationship.
    constexpr vluint64_t kResetTime = 2048ULL * 4ULL;
    constexpr vluint64_t kFrameTime = 804000ULL * 4ULL;
    const vluint64_t autosave_time = autosave_frame < 0
        ? ~vluint64_t{0}
        : kResetTime + static_cast<vluint64_t>(autosave_frame) * kFrameTime;
    bool autosaved = autosave_frame < 0 || save_path.empty() ||
                     contextp->time() >= autosave_time;

    bool clk_ram = topp->clk_ram;
    bool clk_sys = topp->clk_sys;
    g_sc_time = static_cast<double>(contextp->time());
    while (VL_LIKELY(!contextp->gotFinish())) {
        clk_ram = !clk_ram;
        topp->clk_ram = clk_ram;
        if ((contextp->time() & 1ULL) != 0) {
            clk_sys = !clk_sys;
            topp->clk_sys = clk_sys;
        }
        topp->eval();
        if (!autosaved && contextp->time() >= autosave_time) {
            save_checkpoint(save_path, contextp.get(), topp.get());
            autosaved = true;
        }
        contextp->timeInc(1);
        g_sc_time = static_cast<double>(contextp->time());
    }

    // Also preserve the latest state on normal early completion when the
    // requested automatic milestone was never reached.
    if (!autosaved && !save_path.empty())
        save_checkpoint(save_path, contextp.get(), topp.get());

    if (VL_LIKELY(!contextp->gotFinish()))
        VL_DEBUG_IF(VL_PRINTF("+ Exiting without $finish; no events left\n"););
    topp->final();
    contextp->statsPrintSummary();
    return 0;
}
