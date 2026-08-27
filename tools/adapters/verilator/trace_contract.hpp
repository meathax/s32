#pragma once

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace mister_fpga {

class TraceWriter {
public:
    explicit TraceWriter(const char* path = std::getenv("MISTER_TRACE_OUT")) {
        if (path == nullptr || *path == '\0') {
            throw std::runtime_error("MISTER_TRACE_OUT is required");
        }
        stream_.open(path, std::ios::out | std::ios::trunc);
        if (!stream_) {
            throw std::runtime_error(std::string("Cannot open trace: ") + path);
        }
    }

    TraceWriter(const TraceWriter&) = delete;
    TraceWriter& operator=(const TraceWriter&) = delete;

    void emit_bus(
        const std::string& domain,
        const std::string& phase,
        char rw,
        std::uint64_t native_address,
        std::uint64_t native_data,
        std::uint64_t native_byte_enable,
        const std::string& event = "bus"
    ) {
        if (rw != 'R' && rw != 'W') {
            throw std::invalid_argument("rw must be R or W");
        }
        const auto seq = sequence_[domain]++;
        stream_
            << "{\"domain\":\"" << escape(domain)
            << "\",\"seq\":" << seq
            << ",\"event\":\"" << escape(event)
            << "\",\"phase\":\"" << escape(phase)
            << "\",\"rw\":\"" << rw
            << "\",\"address\":" << native_address
            << ",\"data\":" << native_data
            << ",\"byte_enable\":" << native_byte_enable
            << "}\n";
        if (!stream_) {
            throw std::runtime_error("Trace write failed");
        }
    }

    void flush() { stream_.flush(); }

private:
    static std::string escape(const std::string& input) {
        std::string out;
        out.reserve(input.size());
        for (const char ch : input) {
            switch (ch) {
                case '\\': out += "\\\\"; break;
                case '"': out += "\\\""; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default: out += ch; break;
            }
        }
        return out;
    }

    std::ofstream stream_;
    std::unordered_map<std::string, std::uint64_t> sequence_;
};

}  // namespace mister_fpga
