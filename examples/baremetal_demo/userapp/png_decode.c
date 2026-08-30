#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

extern uint64_t sys_open(uint8_t* path, uint64_t mode);
extern uint64_t sys_read(uint64_t fd, uint8_t* buf, uint64_t len);
extern uint64_t sys_write(uint64_t fd, uint8_t* buf, uint64_t len);
extern uint64_t sys_close(uint64_t fd);
extern uint8_t* sys_malloc(uint64_t size);
extern uint64_t sys_free(uint8_t* ptr);

#define O_RDONLY 0
#define O_CREATE 1
#define PNG_SIG0 0x89504E47u
#define PNG_SIG1 0x0D0A1A0Au
#define Z_OK 0
#define Z_STREAM_END 1

#define PNG_IHDR 0x49484452u
#define PNG_IDAT 0x49444154u
#define PNG_IEND 0x49454E44u
#define PNG_PLTE 0x504C5445u
#define PNG_TRNS 0x74524E53u

#define MAX_BITS 15
#define TABLE_SIZE (1u << MAX_BITS)

typedef struct {
    uint16_t sym;
    uint8_t len;
} HuffEntry;

typedef struct {
    const uint8_t* in;
    size_t len;
    size_t pos;
    uint32_t bitbuf;
    int bitcount;
} BitStream;

typedef struct {
    uint64_t width;
    uint64_t height;
    uint8_t* data;
} PngImageOut;

static const char* png_last_error = "ok";

static bool png_fail(const char* reason) {
    png_last_error = reason;
    return false;
}

uint8_t* png_decode_last_error(void) {
    return (uint8_t*)png_last_error;
}

static HuffEntry lit_table[TABLE_SIZE];
static HuffEntry dist_table[TABLE_SIZE];
static HuffEntry cl_table[TABLE_SIZE];
static bool fixed_ready = false;

static uint32_t read_be32(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint16_t read_le16(const uint8_t* p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t reverse_bits(uint32_t v, int n) {
    uint32_t r = 0;
    int i = 0;
    while (i < n) {
        r = (r << 1) | (v & 1u);
        v >>= 1;
        i++;
    }
    return r;
}

static bool bs_fill(BitStream* bs, int need) {
    while (bs->bitcount < need) {
        if (bs->pos >= bs->len) {
            return false;
        }
        bs->bitbuf |= (uint32_t)bs->in[bs->pos++] << bs->bitcount;
        bs->bitcount += 8;
    }
    return true;
}

static uint32_t bs_peek(BitStream* bs, int bits) {
    return bs->bitbuf & ((1u << bits) - 1u);
}

static void bs_drop(BitStream* bs, int bits) {
    bs->bitbuf >>= bits;
    bs->bitcount -= bits;
}

static uint32_t bs_read_bits(BitStream* bs, int bits, bool* ok) {
    if (!bs_fill(bs, bits)) {
        *ok = false;
        return 0;
    }
    uint32_t out = bs_peek(bs, bits);
    bs_drop(bs, bits);
    return out;
}

static void table_clear(HuffEntry* table) {
    size_t i = 0;
    while (i < TABLE_SIZE) {
        table[i].sym = 0;
        table[i].len = 0;
        i++;
    }
}

static bool build_table(const uint8_t* lengths, size_t count, HuffEntry* table) {
    uint16_t counts[16];
    uint16_t next_code[16];
    int i = 0;
    while (i < 16) {
        counts[i] = 0;
        next_code[i] = 0;
        i++;
    }
    i = 0;
    while ((size_t)i < count) {
        uint8_t len = lengths[i];
        if (len > MAX_BITS) {
            return false;
        }
        if (len != 0) {
            counts[len]++;
        }
        i++;
    }

    uint32_t code = 0;
    i = 1;
    while (i <= MAX_BITS) {
        code = (code + counts[i - 1]) << 1;
        next_code[i] = (uint16_t)code;
        i++;
    }

    table_clear(table);
    i = 0;
    while ((size_t)i < count) {
        uint8_t len = lengths[i];
        if (len != 0) {
            uint32_t c = next_code[len]++;
            uint32_t rev = reverse_bits(c, len);
            uint32_t fill = 1u << (MAX_BITS - len);
            uint32_t j = 0;
            while (j < fill) {
                uint32_t idx = rev | (j << len);
                table[idx].sym = (uint16_t)i;
                table[idx].len = len;
                j++;
            }
        }
        i++;
    }
    return true;
}

static void init_fixed_tables(void) {
    if (fixed_ready) {
        return;
    }
    uint8_t lit_len[288];
    uint8_t dist_len[32];
    size_t i = 0;
    while (i < 288) {
        if (i <= 143) {
            lit_len[i] = 8;
        } else if (i <= 255) {
            lit_len[i] = 9;
        } else if (i <= 279) {
            lit_len[i] = 7;
        } else {
            lit_len[i] = 8;
        }
        i++;
    }
    i = 0;
    while (i < 32) {
        dist_len[i] = 5;
        i++;
    }
    build_table(lit_len, 288, lit_table);
    build_table(dist_len, 32, dist_table);
    fixed_ready = true;
}

static int decode_symbol(BitStream* bs, const HuffEntry* table) {
    while (bs->bitcount < MAX_BITS && bs->pos < bs->len) {
        bs->bitbuf |= (uint32_t)bs->in[bs->pos++] << bs->bitcount;
        bs->bitcount += 8;
    }
    if (bs->bitcount <= 0) {
        return -1;
    }
    uint32_t idx = bs->bitbuf & ((1u << MAX_BITS) - 1u);
    HuffEntry e = table[idx];
    if (e.len == 0 || e.len > bs->bitcount) {
        return -1;
    }
    bs_drop(bs, e.len);
    return (int)e.sym;
}

static uint32_t adler32(const uint8_t* data, size_t len) {
    const uint32_t MOD = 65521u;
    uint32_t a = 1;
    uint32_t b = 0;
    size_t i = 0;
    while (i < len) {
        a = (a + data[i]) % MOD;
        b = (b + a) % MOD;
        i++;
    }
    return (b << 16) | a;
}

static uint32_t crc32_table[256];
static bool crc32_ready = false;

static void init_crc32(void) {
    if (crc32_ready) {
        return;
    }
    uint32_t i = 0;
    while (i < 256) {
        uint32_t c = i;
        int j = 0;
        while (j < 8) {
            if (c & 1u) {
                c = 0xEDB88320u ^ (c >> 1);
            } else {
                c >>= 1;
            }
            j++;
        }
        crc32_table[i] = c;
        i++;
    }
    crc32_ready = true;
}

static uint32_t crc32_begin(void) {
    init_crc32();
    return 0xFFFFFFFFu;
}

static uint32_t crc32_update(uint32_t crc, const uint8_t* data, size_t len) {
    size_t i = 0;
    while (i < len) {
        crc = crc32_table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
        i++;
    }
    return crc;
}

static uint32_t crc32_finish(uint32_t crc) {
    return ~crc;
}

static void write_be32(uint8_t* dst, uint32_t v) {
    dst[0] = (uint8_t)((v >> 24) & 0xFFu);
    dst[1] = (uint8_t)((v >> 16) & 0xFFu);
    dst[2] = (uint8_t)((v >> 8) & 0xFFu);
    dst[3] = (uint8_t)(v & 0xFFu);
}

static void write_le16(uint8_t* dst, uint16_t v) {
    dst[0] = (uint8_t)(v & 0xFFu);
    dst[1] = (uint8_t)((v >> 8) & 0xFFu);
}

static bool write_all_fd(uint64_t fd, const uint8_t* buf, size_t len) {
    size_t pos = 0;
    while (pos < len) {
        uint64_t got = sys_write(fd, (uint8_t*)buf + pos, (uint64_t)(len - pos));
        if (got == 0xFFFFFFFFFFFFFFFFu || got == 0) {
            return false;
        }
        pos += (size_t)got;
    }
    return true;
}

static bool inflate_deflate(const uint8_t* in, size_t in_len, uint8_t* out, size_t out_cap, size_t* out_len) {
    static const uint8_t cl_order[19] = {
        16, 17, 18, 0, 8, 7, 9, 6, 10,
        5, 11, 4, 12, 3, 13, 2, 14, 1, 15
    };
    static const uint16_t length_base[29] = {
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13,
        15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
        67, 83, 99, 115, 131, 163, 195, 227, 258
    };
    static const uint8_t length_extra[29] = {
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
        1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 4, 4, 5, 5, 5, 5, 0
    };
    static const uint16_t dist_base[30] = {
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25,
        33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
        1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
    };
    static const uint8_t dist_extra[30] = {
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3,
        4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
        9, 9, 10, 10, 11, 11, 12, 12, 13, 13
    };

    BitStream bs;
    bs.in = in;
    bs.len = in_len - 4;
    bs.pos = 0;
    bs.bitbuf = 0;
    bs.bitcount = 0;

    if (in_len < 6) {
        return false;
    }
    uint8_t cmf = in[0];
    uint8_t flg = in[1];
    if ((cmf & 0x0F) != 8) {
        return false;
    }
    if ((((uint16_t)cmf << 8) | flg) % 31 != 0) {
        return false;
    }
    bs.pos = 2;

    init_fixed_tables();

    size_t out_pos = 0;
    bool final_block = false;
    while (!final_block) {
        bool ok = true;
        final_block = bs_read_bits(&bs, 1, &ok) != 0;
        if (!ok) {
            return false;
        }
        uint32_t btype = bs_read_bits(&bs, 2, &ok);
        if (!ok) {
            return false;
        }

        HuffEntry* lit = lit_table;
        HuffEntry* dist = dist_table;
        uint8_t lit_len[288];
        uint8_t dist_len[32];
        uint8_t cl_len[19];

        if (btype == 0) {
            bs.bitbuf = 0;
            bs.bitcount = 0;
            if (bs.pos + 4 > bs.len) {
                return false;
            }
            uint16_t len = read_le16(bs.in + bs.pos);
            uint16_t nlen = read_le16(bs.in + bs.pos + 2);
            bs.pos += 4;
            if ((uint16_t)~len != nlen) {
                return false;
            }
            if (bs.pos + len > bs.len || out_pos + len > out_cap) {
                return false;
            }
            size_t i = 0;
            while (i < len) {
                out[out_pos++] = bs.in[bs.pos++];
                i++;
            }
            continue;
        }

        if (btype == 1) {
            lit = lit_table;
            dist = dist_table;
        } else if (btype == 2) {
            int i = 0;
            while (i < 19) {
                cl_len[i] = 0;
                i++;
            }
            uint32_t hlit = bs_read_bits(&bs, 5, &ok) + 257;
            uint32_t hdist = bs_read_bits(&bs, 5, &ok) + 1;
            uint32_t hclen = bs_read_bits(&bs, 4, &ok) + 4;
            if (!ok || hlit > 288 || hdist > 32) {
                return false;
            }
            i = 0;
            while ((uint32_t)i < hclen) {
                cl_len[cl_order[i]] = (uint8_t)bs_read_bits(&bs, 3, &ok);
                if (!ok) {
                    return false;
                }
                i++;
            }
            if (!build_table(cl_len, 19, cl_table)) {
                return false;
            }
            i = 0;
            while (i < 288) {
                lit_len[i] = 0;
                i++;
            }
            i = 0;
            while (i < 32) {
                dist_len[i] = 0;
                i++;
            }

            uint32_t total = hlit + hdist;
            uint32_t idx = 0;
            uint8_t prev = 0;
            while (idx < total) {
                int sym = decode_symbol(&bs, cl_table);
                if (sym < 0) {
                    return png_fail("deflate code lengths");
                }
                if (sym <= 15) {
                    uint8_t len = (uint8_t)sym;
                    if (idx < hlit) {
                        lit_len[idx] = len;
                    } else {
                        dist_len[idx - hlit] = len;
                    }
                    prev = len;
                    idx++;
                } else if (sym == 16) {
                    if (idx == 0) {
                        return false;
                    }
                    uint32_t rep = bs_read_bits(&bs, 2, &ok) + 3;
                    if (!ok) {
                        return false;
                    }
                    while (rep > 0 && idx < total) {
                        if (idx < hlit) {
                            lit_len[idx] = prev;
                        } else {
                            dist_len[idx - hlit] = prev;
                        }
                        idx++;
                        rep--;
                    }
                } else if (sym == 17) {
                    uint32_t rep = bs_read_bits(&bs, 3, &ok) + 3;
                    if (!ok) {
                        return false;
                    }
                    prev = 0;
                    while (rep > 0 && idx < total) {
                        if (idx < hlit) {
                            lit_len[idx] = 0;
                        } else {
                            dist_len[idx - hlit] = 0;
                        }
                        idx++;
                        rep--;
                    }
                } else if (sym == 18) {
                    uint32_t rep = bs_read_bits(&bs, 7, &ok) + 11;
                    if (!ok) {
                        return false;
                    }
                    prev = 0;
                    while (rep > 0 && idx < total) {
                        if (idx < hlit) {
                            lit_len[idx] = 0;
                        } else {
                            dist_len[idx - hlit] = 0;
                        }
                        idx++;
                        rep--;
                    }
                } else {
                    return false;
                }
            }
            if (!build_table(lit_len, hlit, lit)) {
                return png_fail("deflate lit table");
            }
            if (!build_table(dist_len, hdist, dist)) {
                return png_fail("deflate dist table");
            }
        } else {
            return false;
        }

        for (;;) {
            int sym = decode_symbol(&bs, lit);
            if (sym < 0) {
                return png_fail("deflate literal");
            }
            if (sym < 256) {
                if (out_pos >= out_cap) {
                    return false;
                }
                out[out_pos++] = (uint8_t)sym;
            } else if (sym == 256) {
                break;
            } else if (sym >= 257 && sym <= 285) {
                uint32_t len = length_base[sym - 257];
                uint8_t extra = length_extra[sym - 257];
                if (extra != 0) {
                    len += bs_read_bits(&bs, extra, &ok);
                    if (!ok) {
                        return false;
                    }
                }

                int dsym = decode_symbol(&bs, dist);
                if (dsym < 0 || dsym >= 30) {
                    return png_fail("deflate distance");
                }
                uint32_t distv = dist_base[dsym];
                uint8_t dextra = dist_extra[dsym];
                if (dextra != 0) {
                    distv += bs_read_bits(&bs, dextra, &ok);
                    if (!ok) {
                        return false;
                    }
                }
                if (distv == 0 || distv > out_pos) {
                    return png_fail("deflate backref");
                }
                if (out_pos + len > out_cap) {
                    return false;
                }
                while (len > 0) {
                    out[out_pos] = out[out_pos - distv];
                    out_pos++;
                    len--;
                }
            } else {
                return false;
            }
        }
    }

    if (in_len < 4) {
        return png_fail("deflate trailer");
    }
    uint32_t expected = ((uint32_t)in[in_len - 4] << 24)
                      | ((uint32_t)in[in_len - 3] << 16)
                      | ((uint32_t)in[in_len - 2] << 8)
                      | (uint32_t)in[in_len - 1];
    if (expected != adler32(out, out_pos)) {
        return png_fail("deflate checksum");
    }
    *out_len = out_pos;
    return true;
}

static uint8_t paeth(uint8_t a, uint8_t b, uint8_t c) {
    int p = (int)a + (int)b - (int)c;
    int pa = p - (int)a;
    if (pa < 0) pa = -pa;
    int pb = p - (int)b;
    if (pb < 0) pb = -pb;
    int pc = p - (int)c;
    if (pc < 0) pc = -pc;
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

static bool unfilter_png(uint8_t* raw, size_t raw_len, uint32_t width, uint32_t height, uint8_t channels, uint8_t* rgba) {
    size_t row_bytes = (size_t)width * channels;
    size_t expected = (row_bytes + 1u) * (size_t)height;
    if (raw_len != expected) {
        return false;
    }
    size_t y = 0;
    while (y < height) {
        uint8_t filter = raw[y * (row_bytes + 1u)];
        uint8_t* src = raw + y * (row_bytes + 1u) + 1;
        uint8_t* dst = rgba + y * row_bytes;
        uint8_t* prev = (y == 0) ? NULL : rgba + (y - 1) * row_bytes;
        size_t x = 0;
        while (x < row_bytes) {
            uint8_t left = (x < channels) ? 0 : dst[x - channels];
            uint8_t up = prev ? prev[x] : 0;
            uint8_t up_left = (prev && x >= channels) ? prev[x - channels] : 0;
            uint8_t val = src[x];
            if (filter == 1) {
                val = (uint8_t)(val + left);
            } else if (filter == 2) {
                val = (uint8_t)(val + up);
            } else if (filter == 3) {
                val = (uint8_t)(val + ((left + up) >> 1));
            } else if (filter == 4) {
                val = (uint8_t)(val + paeth(left, up, up_left));
            } else if (filter != 0) {
                return false;
            }
            dst[x] = val;
            x++;
        }
        y++;
    }
    return true;
}

static bool unfilter_png_bytes(uint8_t* raw, size_t raw_len, size_t row_bytes, uint32_t height, uint8_t bpp, uint8_t* out) {
    size_t expected = (row_bytes + 1u) * (size_t)height;
    if (raw_len != expected || bpp == 0) {
        return false;
    }
    size_t y = 0;
    while (y < height) {
        uint8_t filter = raw[y * (row_bytes + 1u)];
        uint8_t* src = raw + y * (row_bytes + 1u) + 1;
        uint8_t* dst = out + y * row_bytes;
        uint8_t* prev = (y == 0) ? NULL : out + (y - 1) * row_bytes;
        size_t x = 0;
        while (x < row_bytes) {
            uint8_t left = (x < bpp) ? 0 : dst[x - bpp];
            uint8_t up = prev ? prev[x] : 0;
            uint8_t up_left = (prev && x >= bpp) ? prev[x - bpp] : 0;
            uint8_t val = src[x];
            if (filter == 1) {
                val = (uint8_t)(val + left);
            } else if (filter == 2) {
                val = (uint8_t)(val + up);
            } else if (filter == 3) {
                val = (uint8_t)(val + ((left + up) >> 1));
            } else if (filter == 4) {
                val = (uint8_t)(val + paeth(left, up, up_left));
            } else if (filter != 0) {
                return false;
            }
            dst[x] = val;
            x++;
        }
        y++;
    }
    return true;
}

static bool decode_png_bytes(const uint8_t* file, size_t file_len, PngImageOut* out) {
    png_last_error = "ok";
    if (file_len < 8 || read_be32(file) != PNG_SIG0 || read_be32(file + 4) != PNG_SIG1) {
        return png_fail("bad signature");
    }

    size_t pos = 8;
    uint32_t width = 0;
    uint32_t height = 0;
    uint8_t bit_depth = 0;
    uint8_t color_type = 0;
    uint8_t interlace = 0;
    uint8_t palette[256 * 4];
    uint32_t palette_count = 0;
    uint8_t* idat = NULL;
    size_t idat_len = 0;
    size_t idat_cap = file_len;
    if (idat_cap < 8) {
        idat_cap = 8;
    }
    idat = sys_malloc(idat_cap);
    if (!idat) {
        return png_fail("idat alloc");
    }

    while (pos + 12 <= file_len) {
        uint32_t clen = read_be32(file + pos);
        uint32_t ctyp = read_be32(file + pos + 4);
        pos += 8;
        if (pos + clen + 4 > file_len) {
            sys_free(idat);
            return png_fail("truncated chunk");
        }
        const uint8_t* cdata = file + pos;
        uint32_t stored_crc = read_be32(file + pos + clen);
        uint32_t crc = crc32_begin();
        crc = crc32_update(crc, file + pos - 4, 4);
        crc = crc32_update(crc, cdata, clen);
        if (crc32_finish(crc) != stored_crc) {
            sys_free(idat);
            return png_fail("chunk crc");
        }
        if (ctyp == PNG_IHDR) {
            if (clen < 13) {
                sys_free(idat);
                return png_fail("short ihdr");
            }
            width = read_be32(cdata);
            height = read_be32(cdata + 4);
            bit_depth = cdata[8];
            color_type = cdata[9];
            if (cdata[10] != 0 || cdata[11] != 0) {
                sys_free(idat);
                return png_fail("unsupported png method");
            }
            interlace = cdata[12];
        } else if (ctyp == PNG_IDAT) {
            size_t i = 0;
            while (i < clen) {
                idat[idat_len++] = cdata[i];
                i++;
            }
        } else if (ctyp == PNG_PLTE) {
            if (clen % 3 != 0 || clen > 768) {
                sys_free(idat);
                return png_fail("bad palette");
            }
            palette_count = clen / 3;
            size_t i = 0;
            while (i < palette_count) {
                palette[i * 4 + 0] = cdata[i * 3 + 0];
                palette[i * 4 + 1] = cdata[i * 3 + 1];
                palette[i * 4 + 2] = cdata[i * 3 + 2];
                palette[i * 4 + 3] = 255;
                i++;
            }
        } else if (ctyp == PNG_TRNS) {
            if (palette_count > 0) {
                size_t i = 0;
                while (i < clen && i < palette_count) {
                    palette[i * 4 + 3] = cdata[i];
                    i++;
                }
            }
        } else if (ctyp == PNG_IEND) {
            break;
        }
        pos += clen + 4;
    }

    if (width == 0 || height == 0 || interlace != 0) {
        sys_free(idat);
        return png_fail("unsupported header");
    }

    uint8_t channels = 0;
    if (color_type == 6) {
        if (bit_depth != 8) {
            sys_free(idat);
            return png_fail("unsupported depth");
        }
        channels = 4;
    } else if (color_type == 2) {
        if (bit_depth != 8) {
            sys_free(idat);
            return png_fail("unsupported depth");
        }
        channels = 3;
    } else if (color_type == 0) {
        if (bit_depth != 8) {
            sys_free(idat);
            return png_fail("unsupported depth");
        }
        channels = 1;
    } else if (color_type == 3) {
        channels = 1;
        if (!(bit_depth == 1 || bit_depth == 2 || bit_depth == 4 || bit_depth == 8)) {
            sys_free(idat);
            return png_fail("unsupported palette depth");
        }
        if (palette_count == 0) {
            sys_free(idat);
            return png_fail("missing palette");
        }
    } else {
        sys_free(idat);
        return png_fail("unsupported color");
    }

    size_t row_bytes = (size_t)width * channels;
    if (color_type == 3) {
        row_bytes = ((size_t)width * bit_depth + 7u) / 8u;
    }
    size_t inflated_cap = (size_t)height * (row_bytes + 1u) + 16u;
    uint8_t* inflated = sys_malloc((uint64_t)inflated_cap);
    if (!inflated) {
        sys_free(idat);
        return png_fail("inflate alloc");
    }
    size_t inflated_len = 0;
    if (!inflate_deflate(idat, idat_len, inflated, inflated_cap, &inflated_len)) {
        sys_free(idat);
        sys_free(inflated);
        if (png_last_error[0] == 'o' && png_last_error[1] == 'k' && png_last_error[2] == 0) {
            return png_fail("deflate decode");
        }
        return false;
    }
    sys_free(idat);

    size_t raw_len = (size_t)height * row_bytes;
    uint8_t* raw = sys_malloc((uint64_t)raw_len);
    if (!raw) {
        sys_free(inflated);
        return png_fail("raw alloc");
    }
    bool filter_ok = false;
    if (color_type == 3) {
        filter_ok = unfilter_png_bytes(inflated, inflated_len, row_bytes, height, 1, raw);
    } else {
        filter_ok = unfilter_png(inflated, inflated_len, width, height, channels, raw);
    }
    if (!filter_ok) {
        sys_free(inflated);
        sys_free(raw);
        return png_fail("filter decode");
    }
    sys_free(inflated);

    size_t out_len = (size_t)width * (size_t)height * 4u;
    uint8_t* pixels = sys_malloc((uint64_t)out_len);
    if (!pixels) {
        sys_free(raw);
        return png_fail("pixel alloc");
    }

    size_t y = 0;
    while (y < height) {
        size_t x = 0;
        while (x < width) {
            size_t src = y * row_bytes + x * channels;
            size_t dst = y * ((size_t)width * 4u) + x * 4u;
            if (color_type == 6) {
                pixels[dst + 0] = raw[src + 0];
                pixels[dst + 1] = raw[src + 1];
                pixels[dst + 2] = raw[src + 2];
                pixels[dst + 3] = raw[src + 3];
            } else if (color_type == 2) {
                pixels[dst + 0] = raw[src + 0];
                pixels[dst + 1] = raw[src + 1];
                pixels[dst + 2] = raw[src + 2];
                pixels[dst + 3] = 255;
            } else if (color_type == 3) {
                uint8_t idx = 0;
                if (bit_depth == 8) {
                    idx = raw[src];
                } else {
                    size_t bit_pos = x * bit_depth;
                    uint8_t packed = raw[y * row_bytes + (bit_pos / 8u)];
                    uint8_t shift = (uint8_t)(8u - bit_depth - (bit_pos % 8u));
                    idx = (packed >> shift) & ((1u << bit_depth) - 1u);
                }
                if (idx >= palette_count) {
                    sys_free(raw);
                    sys_free(pixels);
                    return png_fail("palette index");
                }
                pixels[dst + 0] = palette[(size_t)idx * 4 + 0];
                pixels[dst + 1] = palette[(size_t)idx * 4 + 1];
                pixels[dst + 2] = palette[(size_t)idx * 4 + 2];
                pixels[dst + 3] = palette[(size_t)idx * 4 + 3];
            } else {
                uint8_t g = raw[src];
                pixels[dst + 0] = g;
                pixels[dst + 1] = g;
                pixels[dst + 2] = g;
                pixels[dst + 3] = 255;
            }
            x++;
        }
        y++;
    }
    sys_free(raw);

    out->width = width;
    out->height = height;
    out->data = pixels;
    return true;
}

bool png_decode_bytes(uint8_t* file, uint64_t file_len, PngImageOut* out) {
    return decode_png_bytes(file, (size_t)file_len, out);
}

static bool load_file(uint8_t* path, uint8_t** data_out, size_t* len_out) {
    uint64_t fd = sys_open(path, O_RDONLY);
    if (fd == 0xFFFFFFFFFFFFFFFFu) {
        return false;
    }
    size_t cap = 65536;
    uint8_t* buf = sys_malloc((uint64_t)cap);
    if (!buf) {
        sys_close(fd);
        return false;
    }
    size_t len = 0;
    for (;;) {
        if (len == cap) {
            size_t new_cap = cap * 2;
            uint8_t* next = sys_malloc((uint64_t)new_cap);
            if (!next) {
                sys_free(buf);
                sys_close(fd);
                return false;
            }
            size_t i = 0;
            while (i < len) {
                next[i] = buf[i];
                i++;
            }
            sys_free(buf);
            buf = next;
            cap = new_cap;
        }
        uint64_t got = sys_read(fd, buf + len, (uint64_t)(cap - len));
        if (got == 0xFFFFFFFFFFFFFFFFu) {
            sys_free(buf);
            sys_close(fd);
            return false;
        }
        if (got == 0) {
            break;
        }
        len += (size_t)got;
    }
    sys_close(fd);
    *data_out = buf;
    *len_out = len;
    return true;
}

bool png_decode_file(uint8_t* path, PngImageOut* out) {
    uint8_t* file = NULL;
    size_t file_len = 0;
    if (!load_file(path, &file, &file_len)) {
        return false;
    }
    bool ok = decode_png_bytes(file, file_len, out);
    sys_free(file);
    return ok;
}

void png_free_image(PngImageOut* img) {
    if (!img) {
        return;
    }
    if (img->data) {
        sys_free(img->data);
    }
    img->data = NULL;
    img->width = 0;
    img->height = 0;
}

bool png_encode_file(uint8_t* path, uint64_t width, uint64_t height, uint64_t pitch, uint8_t* rgba) {
    if (!path || !rgba || width == 0 || height == 0) {
        return false;
    }

    uint64_t fd = sys_open(path, O_CREATE);
    if (fd == 0xFFFFFFFFFFFFFFFFu) {
        return false;
    }

    size_t row_bytes = (size_t)width * 4u;
    size_t raw_len = (size_t)height * (row_bytes + 1u);
    size_t block_count = (raw_len + 65534u) / 65535u;
    size_t idat_data_cap = 2u + raw_len + block_count * 5u + 4u;
    uint8_t* idat = sys_malloc((uint64_t)idat_data_cap);
    if (!idat) {
        sys_close(fd);
        return false;
    }

    size_t pos = 0;
    idat[pos++] = 0x78;
    idat[pos++] = 0x01;
    uint32_t adler_a = 1;
    uint32_t adler_b = 0;
    size_t block_hdr = 0;
    size_t block_len = 0;
    bool block_open = false;

    size_t y = 0;
    while (y < (size_t)height) {
        const uint8_t* src = rgba + y * (size_t)pitch;
        size_t row = 0;
        while (row <= row_bytes) {
            uint8_t byte = 0;
            if (row > 0) {
                byte = src[row - 1];
            }

            if (!block_open || block_len == 65535u) {
                if (block_open) {
                    idat[block_hdr] = 0x00;
                    write_le16(idat + block_hdr + 1, (uint16_t)block_len);
                    write_le16(idat + block_hdr + 3, (uint16_t)~((uint16_t)block_len));
                }
                if (pos + 5u > idat_data_cap) {
                    sys_free(idat);
                    sys_close(fd);
                    return false;
                }
                block_hdr = pos;
                idat[pos++] = 0x00;
                idat[pos++] = 0;
                idat[pos++] = 0;
                idat[pos++] = 0;
                idat[pos++] = 0;
                block_len = 0;
                block_open = true;
            }

            idat[pos++] = byte;
            block_len++;
            adler_a = (adler_a + byte) % 65521u;
            adler_b = (adler_b + adler_a) % 65521u;
            row++;
        }
        y++;
    }

    if (!block_open) {
        sys_free(idat);
        sys_close(fd);
        return false;
    }
    idat[block_hdr] = 0x01;
    write_le16(idat + block_hdr + 1, (uint16_t)block_len);
    write_le16(idat + block_hdr + 3, (uint16_t)~((uint16_t)block_len));
    idat[pos++] = (uint8_t)((adler_b >> 8) & 0xFFu);
    idat[pos++] = (uint8_t)(adler_b & 0xFFu);
    idat[pos++] = (uint8_t)((adler_a >> 8) & 0xFFu);
    idat[pos++] = (uint8_t)(adler_a & 0xFFu);

    uint8_t header[25];
    write_be32(header + 0, 13u);
    header[4] = 'I'; header[5] = 'H'; header[6] = 'D'; header[7] = 'R';
    write_be32(header + 8, (uint32_t)width);
    write_be32(header + 12, (uint32_t)height);
    header[16] = 8;
    header[17] = 6;
    header[18] = 0;
    header[19] = 0;
    header[20] = 0;
    uint32_t crc = crc32_begin();
    crc = crc32_update(crc, header + 4, 17);
    crc = crc32_finish(crc);
    write_be32(header + 21, crc);

    uint8_t idat_len[12];
    write_be32(idat_len, (uint32_t)(pos));
    idat_len[4] = 'I'; idat_len[5] = 'D'; idat_len[6] = 'A'; idat_len[7] = 'T';
    crc = crc32_begin();
    crc = crc32_update(crc, idat, pos);
    crc = crc32_finish(crc);
    uint8_t idat_crc[4];
    write_be32(idat_crc, crc);

    uint8_t iend[12];
    write_be32(iend, 0u);
    iend[4] = 'I'; iend[5] = 'E'; iend[6] = 'N'; iend[7] = 'D';
    crc = crc32_begin();
    crc = crc32_update(crc, iend + 4, 4);
    crc = crc32_finish(crc);
    write_be32(iend + 8, crc);

    uint8_t sig[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    bool ok = write_all_fd(fd, sig, 8)
           && write_all_fd(fd, header, 25)
           && write_all_fd(fd, idat_len, 8)
           && write_all_fd(fd, idat, pos)
           && write_all_fd(fd, idat_crc, 4)
           && write_all_fd(fd, iend, 12);

    sys_free(idat);
    sys_close(fd);
    return ok;
}
