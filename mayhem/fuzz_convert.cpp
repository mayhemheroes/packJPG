/*
 * mayhem/fuzz_convert.cpp — in-process libFuzzer harness for packJPG.
 *
 * packJPG is a JPEG <-> PJG recompressor: it parses a JPEG (or a PJG) and converts
 * it to the other format. The attack surface is parsing an untrusted JPEG/PJG and
 * walking the full decode/recompress path — exactly what `pjglib_convert_stream2mem`
 * drives. We feed the raw fuzz bytes straight in as a MEMORY input stream and ask the
 * library to convert to a MEMORY output, so ASan/UBSan instrument the whole parse +
 * Huffman-decode + arithmetic-(de)code path on attacker-controlled input.
 *
 * packJPG auto-detects the input type from its first two bytes (JPEG SOI 0xFFD8 ->
 * compress; PJG magic -> decompress), so a single harness covers both directions.
 *
 * The library API comes from compiling packjpg.cpp with -DBUILD_LIB (see build.sh),
 * which also excludes the CLI main(). The streams are std::unique_ptr-backed and
 * reset_buffers() re-initializes global state on every call, so repeated in-process
 * invocations are safe.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// packJPGlib.h API (BUILD_LIB). Declared here so the harness needs no upstream headers.
// NB: packjpg.cpp includes packJPGlib.h WITHOUT extern "C", so these have C++ linkage —
// declare them the same way (plain C++ decls) or the references won't resolve.
void pjglib_init_streams(void* in_src, int in_type, int in_size,
                         void* out_dest, int out_type);
bool pjglib_convert_stream2mem(unsigned char** out_file, unsigned int* out_size,
                               char* msg);

// Disable LeakSanitizer for this harness. packJPG's parser (read_jpeg, packjpg.cpp:2129) leaks
// internal buffers on its malformed-input error paths — a real but low-severity defect that would
// otherwise fire on nearly every fuzz input and drown out the memory-corruption / UB bugs this
// harness targets (OOB read/write, the coefficient-decode UB). We keep ASan + UBSan halting and
// only turn off leak reporting, so the campaign stays focused on the higher-severity parse faults.
extern "C" const char* __lsan_default_options(void) { return "detect_leaks=0"; }

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  // Cap input: packJPG is happy with arbitrary sizes, but keep the campaign fast.
  if (size > (1u << 20))  // 1 MiB
    return 0;
  if (size < 2)           // need at least the 2-byte type-detection header
    return 0;

  // packJPG reads from the input buffer in place; give it a private mutable copy
  // (in_type 1 = memory). Out_type 1 = memory (library allocates / owns it).
  unsigned char* buf = (unsigned char*)malloc(size);
  if (!buf) return 0;
  memcpy(buf, data, size);

  pjglib_init_streams(buf, 1, (int)size, NULL, 1);

  unsigned char* out = NULL;
  unsigned int   out_size = 0;
  char msg[1024];
  msg[0] = '\0';
  // On success the library returns an out buffer it malloc()'d for us (Writer::get_c_data
  // hands over a fresh copy — ownership transfers to the caller), so we must free it. We only
  // care that the parse + convert path ran without memory-safety / UB faults.
  pjglib_convert_stream2mem(&out, &out_size, msg);
  if (out) free(out);

  free(buf);
  return 0;
}
