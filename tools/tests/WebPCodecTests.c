#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "src/webp/encode.h"
#include "src/webp/decode.h"

int main(void) {
  const uint8_t rgba[] = {255,0,0,255, 0,255,0,255, 0,0,255,255, 123,45,67,255};
  uint8_t *encoded = NULL, *decoded = NULL;
  size_t count = WebPEncodeLosslessRGBA(rgba, 2, 2, 8, &encoded);
  int width = 0, height = 0;
  if (!count || !encoded || memcmp(encoded, "RIFF", 4) || memcmp(encoded + 8, "WEBP", 4)) return 1;
  decoded = WebPDecodeRGBA(encoded, count, &width, &height);
  if (!decoded || width != 2 || height != 2 || memcmp(decoded, rgba, sizeof(rgba))) return 2;
  WebPFree(encoded); WebPFree(decoded);
  puts("PASS: lossless WebP exact RGBA round trip and real RIFF/WEBP bytes");
  for (int quality = 0; quality <= 100; quality += 25) {
    encoded = NULL;
    count = WebPEncodeRGBA(rgba, 2, 2, 8, (float)quality, &encoded);
    decoded = WebPDecodeRGBA(encoded, count, &width, &height);
    if (!count || !decoded || width != 2 || height != 2) return 3;
    for (int i = 3; i < 16; i += 4) if (decoded[i] != 255) return 4;
    WebPFree(encoded); WebPFree(decoded);
  }
  puts("PASS: lossy WebP quality 0/25/50/75/100 decodes with opaque alpha");
  return 0;
}
