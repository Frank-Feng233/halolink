#include "annexb_parser.h"

namespace halolink {

namespace {

// Returns true when a start code begins at `pos`.
inline bool IsStartCode3(const uint8_t *data, size_t length, size_t pos) {
  return pos + 3 <= length && data[pos] == 0x00 && data[pos + 1] == 0x00 &&
         data[pos + 2] == 0x01;
}

inline bool IsStartCode4(const uint8_t *data, size_t length, size_t pos) {
  return pos + 4 <= length && data[pos] == 0x00 && data[pos + 1] == 0x00 &&
         data[pos + 2] == 0x00 && data[pos + 3] == 0x01;
}

}  // namespace

std::vector<NalUnit> SplitAnnexB(const uint8_t *data, size_t length) {
  std::vector<NalUnit> units;
  if (data == nullptr || length < 3) {
    return units;
  }
  size_t i = 0;
  while (i + 3 <= length) {
    size_t start = SIZE_MAX;
    size_t scLength = 0;
    for (size_t p = i; p + 3 <= length; ++p) {
      if (IsStartCode3(data, length, p)) {
        // Prefer a 4-byte start code when the preceding byte is zero: the scan
        // may have landed on the 3-byte tail of a 00 00 00 01 sequence.
        start = p;
        scLength = 3;
        break;
      }
      if (IsStartCode4(data, length, p)) {
        start = p;
        scLength = 4;
        break;
      }
    }
    if (start == SIZE_MAX) {
      break;
    }
    const size_t headerPos = start + scLength;
    if (headerPos >= length) {
      break;
    }
    // Find the beginning of the next start code.
    size_t nextStart = length;
    for (size_t p = headerPos + 1; p + 3 <= length; ++p) {
      if (IsStartCode3(data, length, p) || IsStartCode4(data, length, p)) {
        nextStart = p;
        break;
      }
    }
    // A NAL unit runs from its start code up to (excluding) the next start
    // code. Trailing zero bytes belong to the next start code, not the payload.
    const size_t end = nextStart;
    NalUnit unit;
    unit.start = start;
    unit.headerPos = headerPos;
    unit.end = end;
    unit.type = data[headerPos] & 0x1F;
    units.push_back(unit);
    if (nextStart >= length) {
      break;
    }
    i = nextStart;
  }
  return units;
}

bool ExtractCodecConfig(const uint8_t *data, size_t length, std::vector<uint8_t> &out,
                        size_t maxBytes) {
  out.clear();
  if (data == nullptr || length == 0) {
    return false;
  }
  const std::vector<NalUnit> units = SplitAnnexB(data, length);
  for (const NalUnit &unit : units) {
    if (unit.type != 7 && unit.type != 8) {  // SPS / PPS
      continue;
    }
    const size_t unitLength = unit.end - unit.start;
    if (out.size() + unitLength > maxBytes) {
      out.clear();
      return false;
    }
    out.insert(out.end(), data + unit.start, data + unit.end);
  }
  return !out.empty();
}

}  // namespace halolink
