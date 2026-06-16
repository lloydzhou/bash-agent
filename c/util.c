#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

/* ============================================================
 * StrBuf — 动态字符串缓冲区
 * ============================================================ */

void sb_init(StrBuf *sb) {
    sb->data = NULL;
    sb->len = 0;
    sb->cap = 0;
}

void sb_free(StrBuf *sb) {
    free(sb->data);
    sb->data = NULL;
    sb->len = 0;
    sb->cap = 0;
}

void sb_ensure(StrBuf *sb, size_t extra) {
    if (sb->len + extra + 1 <= sb->cap) return;
    size_t newcap = sb->cap ? sb->cap : 256;
    while (newcap < sb->len + extra + 1) newcap *= 2;
    char *p = realloc(sb->data, newcap);
    if (!p) { fprintf(stderr, "out of memory\n"); abort(); }
    sb->data = p;
    sb->cap = newcap;
}

void sb_append(StrBuf *sb, const char *s) {
    if (!s) return;
    size_t n = strlen(s);
    sb_appendn(sb, s, n);
}

void sb_appendn(StrBuf *sb, const char *s, size_t n) {
    if (n == 0) return;
    sb_ensure(sb, n);
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

void sb_appendf(StrBuf *sb, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    sb_ensure(sb, (size_t)n);
    vsnprintf(sb->data + sb->len, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    sb->len += (size_t)n;
    sb->data[sb->len] = '\0';
}

void sb_append_char(StrBuf *sb, char c) {
    sb_ensure(sb, 1);
    sb->data[sb->len++] = c;
    sb->data[sb->len] = '\0';
}

void sb_truncate(StrBuf *sb, size_t len) {
    if (len < sb->len) {
        sb->len = len;
        sb->data[len] = '\0';
    }
}

void sb_append_json_string(StrBuf *sb, const char *src) {
    if (!src) { sb_append(sb, "null"); return; }
    sb_append_char(sb, '"');
    while (*src) {
        unsigned char c = (unsigned char)*src;
        switch (c) {
            case '"':  sb_append(sb, "\\\""); src++; break;
            case '\\': sb_append(sb, "\\\\"); src++; break;
            case '\b': sb_append(sb, "\\b"); src++; break;
            case '\f': sb_append(sb, "\\f"); src++; break;
            case '\n': sb_append(sb, "\\n"); src++; break;
            case '\r': sb_append(sb, "\\r"); src++; break;
            case '\t': sb_append(sb, "\\t"); src++; break;
            default:
                if (c < 0x20) {
                    /* 控制字符 → \uXXXX（JSON 规范要求） */
                    sb_appendf(sb, "\\u%04x", c);
                    src++;
                } else {
                    /* ASCII 可打印 + 所有非控制字节（含 UTF-8 多字节）原样输出
                     * UTF-8 非法字节由上游 util_sanitize_utf8 在源头处理 */
                    sb_append_char(sb, c);
                    src++;
                }
                break;
        }
    }
    sb_append_char(sb, '"');
}

void sb_append_shell_arg(StrBuf *sb, const char *src) {
    if (!src) {
        sb_append(sb, "''");
        return;
    }
    sb_append_char(sb, '\'');
    for (; *src; src++) {
        if (*src == '\'') sb_append(sb, "'\\''");
        else sb_append_char(sb, *src);
    }
    sb_append_char(sb, '\'');
}

/* UTF-8 sanitize：与 awk/sanitize_utf8.awk 完全一致的逻辑
 * 逐字节扫描，非法 UTF-8 字节替换为字面文本 \ufffd（6 个 ASCII 字符）
 * 返回新 malloc'd 字符串，调用者负责 free
 */
char *util_sanitize_utf8(const char *src) {
    if (!src) return util_strdup("");
    size_t len = strlen(src);
    /* 最坏情况：每个字节都非法，替换为 6 字符 \ufffd */
    StrBuf sb;
    sb_init(&sb);
    sb_ensure(&sb, len * 6 + 1);

    const unsigned char *p = (const unsigned char *)src;
    const unsigned char *end = p + len;

    while (p < end) {
        unsigned char b = *p;
        if (b < 0x80) {
            /* ASCII (0x00-0x7F): 直接输出 */
            sb_append_char(&sb, b);
            p++;
        } else if (b >= 0xC2 && b <= 0xDF) {
            /* 2 字节序列: C2-DF + 80-BF */
            if (p + 1 < end && p[1] >= 0x80 && p[1] <= 0xBF) {
                sb_appendn(&sb, (const char *)p, 2);
                p += 2;
            } else {
                sb_append(&sb, "\\ufffd");
                p++;
            }
        } else if (b >= 0xE0 && b <= 0xEF) {
            /* 3 字节序列: E0-EF + 80-BF + 80-BF */
            if (p + 2 < end && p[1] >= 0x80 && p[1] <= 0xBF && p[2] >= 0x80 && p[2] <= 0xBF) {
                sb_appendn(&sb, (const char *)p, 3);
                p += 3;
            } else {
                sb_append(&sb, "\\ufffd");
                p++;
            }
        } else if (b >= 0xF0 && b <= 0xF4) {
            /* 4 字节序列: F0-F4 + 80-BF + 80-BF + 80-BF */
            if (p + 3 < end && p[1] >= 0x80 && p[1] <= 0xBF && p[2] >= 0x80 && p[2] <= 0xBF && p[3] >= 0x80 && p[3] <= 0xBF) {
                sb_appendn(&sb, (const char *)p, 4);
                p += 4;
            } else {
                sb_append(&sb, "\\ufffd");
                p++;
            }
        } else {
            /* 非法字节: C0-C1(过长编码), 80-BF(孤立 continuation), F5-FF(超范围) */
            sb_append(&sb, "\\ufffd");
            p++;
        }
    }
    return sb.data;
}

/* 检查字符串是否为合法 UTF-8。返回 1=合法, 0=非法 */
static int is_valid_utf8(const char *src, size_t len) {
    const unsigned char *p = (const unsigned char *)src;
    const unsigned char *end = p + len;
    while (p < end) {
        unsigned char b = *p;
        if (b < 0x80) { p++; }
        else if (b >= 0xC2 && b <= 0xDF) {
            if (p + 1 >= end || p[1] < 0x80 || p[1] > 0xBF) return 0;
            p += 2;
        } else if (b >= 0xE0 && b <= 0xEF) {
            if (p + 2 >= end || p[1] < 0x80 || p[1] > 0xBF || p[2] < 0x80 || p[2] > 0xBF) return 0;
            p += 3;
        } else if (b >= 0xF0 && b <= 0xF4) {
            if (p + 3 >= end || p[1] < 0x80 || p[1] > 0xBF || p[2] < 0x80 || p[2] > 0xBF || p[3] < 0x80 || p[3] > 0xBF) return 0;
            p += 4;
        } else {
            return 0; /* C0-C1, 80-BF, F5-FF */
        }
    }
    return 1;
}

/* 用 popen 调用 file -bi 检测编码，返回检测到的 from_enc（malloc'd）。
 * iso-8859-* 一律视为 gb18030（兼容 GBK）。失败返回 NULL。 */
static char *detect_encoding(const char *content, size_t len) {
    char tmppath[256];
    snprintf(tmppath, sizeof(tmppath), "/tmp/iconv_detect_%d.tmp", (int)getpid());
    FILE *f = fopen(tmppath, "wb");
    if (!f) return NULL;
    fwrite(content, 1, len, f);
    fclose(f);

    char cmd[512];
    snprintf(cmd, sizeof(cmd), "file -bi '%s' 2>/dev/null", tmppath);
    FILE *pp = popen(cmd, "r");
    if (!pp) { unlink(tmppath); return NULL; }

    char mime[256] = {0};
    if (fgets(mime, sizeof(mime), pp)) {
        /* 转小写 */
        for (char *c = mime; *c; c++) { if (*c >= 'A' && *c <= 'Z') *c += 32; }
    }
    pclose(pp);
    unlink(tmppath);

    /* 检查 charset */
    if (strstr(mime, "charset=utf-8") || strstr(mime, "charset=us-ascii")) {
        return util_strdup("utf-8");
    }
    /* 匹配已知中文/日文编码 */
    const char *encs[] = {"gbk", "gb2312", "gb18030", "big5", "shift_jis", "euc-jp", "euc-kr", NULL};
    for (int i = 0; encs[i]; i++) {
        char needle[32];
        snprintf(needle, sizeof(needle), "charset=%s", encs[i]);
        if (strstr(mime, needle)) return util_strdup(encs[i]);
    }
    /* iso-8859-* → 视为 gb18030（file 对中文文件常误报 iso-8859-1） */
    if (strstr(mime, "charset=iso-8859")) return util_strdup("gb18030");
    return NULL;
}

char *util_iconv_if_needed(const char *content) {
    if (!content) return util_sanitize_utf8("");
    size_t len = strlen(content);

    /* UTF-8 合法 → 直接 sanitize（idempotent） */
    if (is_valid_utf8(content, len)) {
        return util_sanitize_utf8(content);
    }

    /* 非 UTF-8 → 尝试 iconv 转码 */
    char *from_enc = detect_encoding(content, len);
    if (!from_enc) from_enc = util_strdup("gb18030"); /* 默认按 gb18030 尝试 */

    /* 构建 iconv 管道：echo content | iconv -f gb18030 -t UTF-8//IGNORE */
    char tmppath[256];
    snprintf(tmppath, sizeof(tmppath), "/tmp/iconv_in_%d.tmp", (int)getpid());
    FILE *f = fopen(tmppath, "wb");
    if (!f) { free(from_enc); return util_sanitize_utf8(content); }
    fwrite(content, 1, len, f);
    fclose(f);

    char cmd[512];
    snprintf(cmd, sizeof(cmd), "iconv -f '%s' -t UTF-8//IGNORE '%s' 2>/dev/null", from_enc, tmppath);
    free(from_enc);

    FILE *pp = popen(cmd, "r");
    if (!pp) { unlink(tmppath); return util_sanitize_utf8(content); }

    StrBuf sb;
    sb_init(&sb);
    char buf2[4096];
    size_t total = 0;
    while (fgets(buf2, sizeof(buf2), pp)) {
        sb_append(&sb, buf2);
        total += strlen(buf2);
    }
    pclose(pp);
    unlink(tmppath);

    if (total == 0 && len > 0) {
        /* iconv 失败 → 兜底 */
        sb_free(&sb);
        return util_sanitize_utf8(content);
    }

    char *result = util_sanitize_utf8(sb.data);
    sb_free(&sb);
    return result;
}

/* ============================================================
 * 工具函数
 * ============================================================ */

char *util_new_session_id(void) {
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char *buf = malloc(64);  /* 比实际需要的大，消除 -Wformat-truncation 警告 */
    unsigned short r = (unsigned short)(rand() & 0xFFFF);
    snprintf(buf, 64, "%04d%02d%02d-%02d%02d%02d-%04x",
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec, r);
    return buf;
}

char *util_path_join(const char *a, const char *b) {
    size_t alen = strlen(a);
    /* 跳过 b 前导斜杠 */
    while (*b == '/') b++;
    size_t blen = strlen(b);
    char *r = malloc(alen + 1 + blen + 1);
    memcpy(r, a, alen);
    /* 确保 a 末尾有斜杠 */
    if (alen > 0 && a[alen - 1] != '/') {
        r[alen++] = '/';
    }
    memcpy(r + alen, b, blen + 1);
    return r;
}

int util_mkdirs(const char *path, int mode) {
    char *tmp = util_strdup(path);
    if (!tmp) return -1;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
                free(tmp);
                return -1;
            }
            *p = '/';
        }
    }
    if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
        free(tmp);
        return -1;
    }
    free(tmp);
    return 0;
}

const char *util_home_dir(void) {
    const char *home = getenv("HOME");
    if (home) return home;
    return "/tmp";
}

char *util_strdup(const char *s) {
    if (!s) return NULL;
    return strdup(s);
}

const char *util_env(const char *name, const char *defval) {
    const char *v = getenv(name);
    return v ? v : defval;
}

char *util_timestamp_now(void) {
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char *buf = malloc(32);
    strftime(buf, 32, "%Y-%m-%dT%H:%M:%S", &tm);
    return buf;
}

long util_parse_size(const char *s) {
    if (!s || !*s) return -1;
    char *endp = NULL;
    long val = strtol(s, &endp, 10);
    if (endp == s || val <= 0) return -1;
    if (*endp == 'k' || *endp == 'K') { val *= 1000; endp++; }
    else if (*endp == 'm' || *endp == 'M') { val *= 1000000; endp++; }
    else if (*endp == 'g' || *endp == 'G') { val *= 1000000000; endp++; }
    return (*endp == '\0') ? val : -1;
}

long util_epoch_seconds(void) {
    return (long)time(NULL);
}

int util_utf8_char_count(const char *s) {
    int count = 0;
    for (; *s; s++) {
        /* UTF-8 后续字节是 10xxxxxx (0x80-0xBF)，不计为字符 */
        if ((*(unsigned char*)s & 0xC0) != 0x80) count++;
    }
    return count;
}

size_t util_utf8_truncate_len(const char *s, size_t max_bytes) {
    size_t len = strlen(s);
    if (len <= max_bytes) return len;
    /* 从 max_bytes 处往前跳过 UTF-8 后继字节 (10xxxxxx)，确保不在字符中间切断 */
    while (max_bytes > 0 && ((unsigned char)s[max_bytes] & 0xC0) == 0x80) {
        max_bytes--;
    }
    return max_bytes;
}

void util_truncate_str(char *s, size_t max_total) {
    size_t len = strlen(s);
    if (len <= max_total) return;
    /* 留 3 字节给 "..."，UTF-8 安全截断 */
    size_t cut = (max_total >= 3) ? max_total - 3 : 0;
    cut = util_utf8_truncate_len(s, cut);
    s[cut] = '.';
    s[cut + 1] = '.';
    s[cut + 2] = '.';
    s[cut + 3] = '\0';
}

void util_truncate_chars(char *s, int max_chars) {
    if (util_utf8_char_count(s) <= max_chars) return;
    /* 留 3 字符给 "..."，找到前 (max_chars - 3) 个字符的字节位置 */
    int target = max_chars >= 3 ? max_chars - 3 : 0;
    int char_count = 0;
    char *p = s;
    while (*p && char_count < target) {
        if ((*(unsigned char *)p & 0xC0) != 0x80) char_count++;
        p++;
    }
    p[0] = '.'; p[1] = '.'; p[2] = '.'; p[3] = '\0';
}

char *util_rtrim(char *s) {
    size_t len = strlen(s);
    while (len > 0 && (s[len-1] == '\n' || s[len-1] == '\r' ||
                       s[len-1] == ' '  || s[len-1] == '\t')) {
        s[--len] = '\0';
    }
    return s;
}

char *util_read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t nread = fread(buf, 1, (size_t)sz, f);
    buf[nread] = '\0';
    fclose(f);
    return buf;
}

int util_write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    size_t len = strlen(content);
    size_t nw = fwrite(content, 1, len, f);
    fclose(f);
    return (nw == len) ? 0 : -1;
}
