// Host unit test for the Annex-B / SPS-PPS extraction used by libdecoder.so.
//
// Build & run: test/native/run_tests.sh
// (compiled with the host clang++ — the same annexb_parser.cpp that ships inside
// libdecoder.so for the tablet, so this genuinely tests the shipping logic.)

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "annexb_parser.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool condition, const std::string &what) {
  g_checks++;
  if (condition) {
    std::printf("  [PASS] %s\n", what.c_str());
  } else {
    g_failures++;
    std::printf("  [FAIL] %s\n", what.c_str());
  }
}

std::vector<uint8_t> Bytes(std::initializer_list<int> values) {
  std::vector<uint8_t> out;
  for (int v : values) {
    out.push_back(static_cast<uint8_t>(v));
  }
  return out;
}

std::vector<uint8_t> ReadFile(const std::string &path) {
  std::ifstream in(path, std::ios::binary);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(in),
                              std::istreambuf_iterator<char>());
}

void TestSplitAndExtract() {
  std::printf("== synthetic Annex-B buffers ==\n");
  // 4-byte start codes: SPS(7) PPS(8) SEI(6) IDR(5) P(1)
  const std::vector<uint8_t> sps = Bytes({0, 0, 0, 1, 0x67, 0x4d, 0x00, 0x1f});
  const std::vector<uint8_t> pps = Bytes({0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80});
  const std::vector<uint8_t> sei = Bytes({0, 0, 0, 1, 0x06, 0x05, 0x01});
  const std::vector<uint8_t> idr = Bytes({0, 0, 0, 1, 0x65, 0xaa, 0xbb, 0xcc});
  const std::vector<uint8_t> p = Bytes({0, 0, 0, 1, 0x41, 0x11, 0x22});

  std::vector<uint8_t> au;
  for (const auto *nal : {&sps, &pps, &sei, &idr}) {
    au.insert(au.end(), nal->begin(), nal->end());
  }
  au.insert(au.end(), p.begin(), p.end());

  const std::vector<halolink::NalUnit> units = halolink::SplitAnnexB(au.data(), au.size());
  Check(units.size() == 5, "SplitAnnexB finds 5 NAL units in SPS+PPS+SEI+IDR+P");
  if (units.size() == 5) {
    Check(units[0].type == 7 && units[1].type == 8 && units[2].type == 6 &&
              units[3].type == 5 && units[4].type == 1,
          "NAL types are 7,8,6,5,1");
    Check(units[0].start == 0 && units[1].start == sps.size(),
          "NAL start offsets are contiguous");
    Check(units[4].end == au.size(), "last NAL ends at buffer end");
  }

  std::vector<uint8_t> config;
  Check(halolink::ExtractCodecConfig(au.data(), au.size(), config), "codec config extracted");
  std::vector<uint8_t> expected = sps;
  expected.insert(expected.end(), pps.begin(), pps.end());
  Check(config == expected, "codec config == SPS+PPS with start codes (no SEI/IDR/P)");

  // 3-byte start codes must also work.
  const std::vector<uint8_t> sps3 = Bytes({0, 0, 1, 0x67, 0x42, 0x00, 0x1e});
  const std::vector<uint8_t> pps3 = Bytes({0, 0, 1, 0x68, 0xce, 0x3c, 0x80});
  std::vector<uint8_t> au3 = sps3;
  au3.insert(au3.end(), pps3.begin(), pps3.end());
  const std::vector<uint8_t> idr3 = Bytes({0, 0, 1, 0x65, 0x01, 0x02});
  au3.insert(au3.end(), idr3.begin(), idr3.end());
  std::vector<uint8_t> config3;
  Check(halolink::ExtractCodecConfig(au3.data(), au3.size(), config3),
        "3-byte start codes: codec config extracted");
  std::vector<uint8_t> expected3 = sps3;
  expected3.insert(expected3.end(), pps3.begin(), pps3.end());
  Check(config3 == expected3, "3-byte start codes: SPS+PPS exact bytes");

  // No parameter sets -> false (decoder must tolerate inline SPS/PPS).
  std::vector<uint8_t> onlyIdr = idr;
  onlyIdr.insert(onlyIdr.end(), p.begin(), p.end());
  std::vector<uint8_t> none;
  Check(!halolink::ExtractCodecConfig(onlyIdr.data(), onlyIdr.size(), none),
        "no SPS/PPS -> returns false");

  // Too-small budget -> false + cleared output.
  std::vector<uint8_t> tooSmall;
  Check(!halolink::ExtractCodecConfig(au.data(), au.size(), tooSmall, 4),
        "maxBytes too small -> returns false");

  // Degenerate inputs must not crash.
  std::vector<uint8_t> empty;
  Check(!halolink::ExtractCodecConfig(nullptr, 0, empty), "null input -> false");
  const std::vector<uint8_t> junk = Bytes({0x12, 0x34, 0x56});
  Check(halolink::SplitAnnexB(junk.data(), junk.size()).empty(), "no start code -> empty");
  const std::vector<uint8_t> truncated = Bytes({0, 0, 0, 1});
  Check(halolink::SplitAnnexB(truncated.data(), truncated.size()).empty(),
        "start code without NAL header -> empty");
}

void TestRealStream(const std::string &path) {
  std::printf("== real ffmpeg H.264 stream: %s ==\n", path.c_str());
  const std::vector<uint8_t> data = ReadFile(path);
  if (data.empty()) {
    std::printf("  [SKIP] stream not found (run: python3 test/mock_host.py --generate)\n");
    return;
  }
  const std::vector<halolink::NalUnit> units = halolink::SplitAnnexB(data.data(), data.size());
  Check(units.size() > 100, "many NAL units parsed (" + std::to_string(units.size()) + ")");

  int sps = 0;
  int pps = 0;
  int idr = 0;
  int nonIdr = 0;
  for (const auto &unit : units) {
    if (unit.type == 7) sps++;
    if (unit.type == 8) pps++;
    if (unit.type == 5) idr++;
    if (unit.type == 1) nonIdr++;
  }
  Check(sps >= 1 && pps >= 1, "SPS/PPS present in stream");
  Check(idr >= 1 && nonIdr >= 1, "IDR and non-IDR slices present");

  // The first SPS must be found in the very first bytes; extraction must return
  // a config that starts with SPS and contains PPS but no VCL NAL.
  std::vector<uint8_t> config;
  Check(halolink::ExtractCodecConfig(data.data(), data.size(), config),
        "codec config extracted from real stream");
  Check(config.size() >= 8, "config has reasonable size (" + std::to_string(config.size()) + ")");
  Check(config.size() > 0 && config[0] == 0 && config[1] == 0,
        "config starts with an Annex-B start code");
  // The first NAL in the config is the first SPS in the stream.
  const std::vector<halolink::NalUnit> configUnits =
      halolink::SplitAnnexB(config.data(), config.size());
  bool allParameters = !configUnits.empty();
  for (const auto &unit : configUnits) {
    if (unit.type != 7 && unit.type != 8) {
      allParameters = false;
    }
  }
  Check(allParameters, "codec config contains only SPS/PPS NAL units");

  // Split into per-IDR access units like the mock host does and make sure the
  // SPS/PPS prefix of every IDR AU yields the same config as the first one.
  size_t firstIdrStart = SIZE_MAX;
  for (size_t i = 0; i < units.size(); i++) {
    if (units[i].type == 5) {
      firstIdrStart = i;
      break;
    }
  }
  if (firstIdrStart != SIZE_MAX && firstIdrStart > 0) {
    // Walk back to include the preceding SPS/PPS NALs of that AU.
    size_t auStart = firstIdrStart;
    while (auStart > 0 && (units[auStart - 1].type == 7 || units[auStart - 1].type == 8 ||
                           units[auStart - 1].type == 6)) {
      auStart--;
    }
    const size_t begin = units[auStart].start;
    const size_t end = units[firstIdrStart].end;
    std::vector<uint8_t> idrConfig;
    Check(halolink::ExtractCodecConfig(data.data() + begin, end - begin, idrConfig),
          "codec config extracted from IDR access unit");
    Check(!idrConfig.empty() && idrConfig[0] == 0 && idrConfig[1] == 0,
          "IDR AU config starts with start code");
  }
}

}  // namespace

int main(int argc, char **argv) {
  std::printf("HaloLink native Annex-B parser tests\n");
  TestSplitAndExtract();
  const std::string streamPath = argc > 1 ? argv[1] : "test/stream.h264";
  TestRealStream(streamPath);
  std::printf("\n%d checks, %d failure(s)\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
