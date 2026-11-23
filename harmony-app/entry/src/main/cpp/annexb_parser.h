/*
 * HaloLink Annex-B H.264 helpers (pure C++, no OHOS dependencies).
 *
 * Kept in a standalone translation unit so the exact same code that runs in
 * libdecoder.so on the tablet can also be compiled and unit-tested on the host
 * (see harmony-app/test/native/test_annexb.cpp).
 */

#ifndef HALOLINK_ANNEXB_PARSER_H
#define HALOLINK_ANNEXB_PARSER_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace halolink {

/** A NAL unit range inside an Annex-B byte buffer (start code included). */
struct NalUnit {
  size_t start;      // offset of the start code
  size_t headerPos;  // offset of the NAL header byte
  size_t end;        // one past the last byte of the NAL unit
  uint8_t type;      // NAL unit type (header & 0x1F)
};

/**
 * Splits an Annex-B buffer into NAL units. Handles both 3-byte (00 00 01) and
 * 4-byte (00 00 00 01) start codes; trims trailing zero bytes that belong to
 * the next start code.
 */
std::vector<NalUnit> SplitAnnexB(const uint8_t *data, size_t length);

/**
 * Extracts the SPS (type 7) and PPS (type 8) NAL units, in stream order, with
 * their start codes, into `out` (as required by OH_MD_KEY_CODEC_CONFIG).
 * Returns true when at least one parameter set was found.
 * Returns false when `out` would exceed maxBytes (caller should then rely on
 * in-band SPS/PPS).
 */
bool ExtractCodecConfig(const uint8_t *data, size_t length, std::vector<uint8_t> &out,
                        size_t maxBytes = 4096);

}  // namespace halolink

#endif  // HALOLINK_ANNEXB_PARSER_H
