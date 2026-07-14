#include "json.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>

/* ============================================================
 * 内部辅助
 * ============================================================ */

static void skip_ws(const char *src, size_t *pos) {
    while (src[*pos] == ' ' || src[*pos] == '\t' ||
           src[*pos] == '\n' || src[*pos] == '\r') {
        (*pos)++;
    }
}

static JsonParse make_err(const char *msg) {
    JsonParse p;
    memset(&p, 0, sizeof(p));
    p.error = msg;
    return p;
}

static JsonParse make_val(JsonType type, const char *src, size_t start, size_t end) {
    JsonParse p;
    p.val.type = type;
    p.val.src = src;
    p.val.start = start;
    p.val.end = end;
    p.error = NULL;
    return p;
}

/* 解析 JSON 字符串（从开引号开始） */
static JsonParse parse_string(const char *src, size_t *pos) {
    size_t start = *pos;
    (*pos)++; /* 跳过开引号 */
    while (src[*pos] && src[*pos] != '"') {
        if (src[*pos] == '\\') {
            (*pos)++; /* 跳过转义字符 */
        }
        (*pos)++;
    }
    if (src[*pos] != '"') return make_err("unclosed string");
    (*pos)++; /* 跳过闭引号 */
    return make_val(JSON_STRING, src, start, *pos);
}

/* 解析 JSON 数字 */
static JsonParse parse_number(const char *src, size_t *pos) {
    size_t start = *pos;
    if (src[*pos] == '-') (*pos)++;
    while (isdigit((unsigned char)src[*pos])) (*pos)++;
    if (src[*pos] == '.') {
        (*pos)++;
        while (isdigit((unsigned char)src[*pos])) (*pos)++;
    }
    if (src[*pos] == 'e' || src[*pos] == 'E') {
        (*pos)++;
        if (src[*pos] == '+' || src[*pos] == '-') (*pos)++;
        while (isdigit((unsigned char)src[*pos])) (*pos)++;
    }
    return make_val(JSON_NUMBER, src, start, *pos);
}

/* 前向声明 */
static JsonParse json_parse_internal(const char *src, size_t *pos);

/* 解析 JSON 数组 */
static JsonParse parse_array(const char *src, size_t *pos) {
    size_t start = *pos;
    (*pos)++; /* 跳过 [ */
    skip_ws(src, pos);
    if (src[*pos] == ']') { (*pos)++; return make_val(JSON_ARRAY, src, start, *pos); }
    for (;;) {
        skip_ws(src, pos);
        JsonParse vp = json_parse(src, pos);
        if (vp.error) return vp;
        skip_ws(src, pos);
        if (src[*pos] == ',') { (*pos)++; continue; }
        if (src[*pos] == ']') { (*pos)++; break; }
        return make_err("expected ',' or ']'");
    }
    return make_val(JSON_ARRAY, src, start, *pos);
}

/* 解析 JSON 对象 */
static JsonParse parse_object(const char *src, size_t *pos) {
    size_t start = *pos;
    (*pos)++; /* 跳过 { */
    skip_ws(src, pos);
    if (src[*pos] == '}') { (*pos)++; return make_val(JSON_OBJECT, src, start, *pos); }
    for (;;) {
        skip_ws(src, pos);
        if (src[*pos] != '"') return make_err("expected string key");
        JsonParse kp = parse_string(src, pos);
        if (kp.error) return kp;
        skip_ws(src, pos);
        if (src[*pos] != ':') return make_err("expected ':'");
        (*pos)++;
        skip_ws(src, pos);
        JsonParse vp = json_parse(src, pos);
        if (vp.error) return vp;
        skip_ws(src, pos);
        if (src[*pos] == ',') { (*pos)++; continue; }
        if (src[*pos] == '}') { (*pos)++; break; }
        return make_err("expected ',' or '}'");
    }
    return make_val(JSON_OBJECT, src, start, *pos);
}

/* 解析 JSON 值 */
static JsonParse json_parse_internal(const char *src, size_t *pos) {    skip_ws(src, pos);
    char c = src[*pos];
    if (c == '"') return parse_string(src, pos);
    if (c == '{') return parse_object(src, pos);
    if (c == '[') return parse_array(src, pos);
    if (c == 't') {
        if (strncmp(src + *pos, "true", 4) == 0) { *pos += 4; return make_val(JSON_BOOL, src, *pos - 4, *pos); }
        return make_err("expected 'true'");
    }
    if (c == 'f') {
        if (strncmp(src + *pos, "false", 5) == 0) { *pos += 5; return make_val(JSON_BOOL, src, *pos - 5, *pos); }
        return make_err("expected 'false'");
    }
    if (c == 'n') {
        if (strncmp(src + *pos, "null", 4) == 0) { *pos += 4; return make_val(JSON_NULL, src, *pos - 4, *pos); }
        return make_err("expected 'null'");
    }
    if (c == '-' || isdigit((unsigned char)c)) return parse_number(src, pos);
    return make_err("unexpected character");
}

/* 公开的解析函数 */
JsonParse json_parse(const char *src, size_t *pos) {
    return json_parse_internal(src, pos);
}

JsonParse json_parse_root(const char *src) {
    if (!src) return make_err("null input");
    size_t pos = 0;
    JsonParse p = json_parse_internal(src, &pos);
    if (p.error) return p;
    skip_ws(src, &pos);
    if (src[pos] != '\0') return make_err("trailing content");
    return p;
}

/* ============================================================
 * 查询函数
 * ============================================================ */

JsonVal json_get(JsonVal obj, const char *key) {
    if (obj.type != JSON_OBJECT) {
        JsonVal null_val;
        memset(&null_val, 0, sizeof(null_val));
        return null_val;
    }
    size_t pos = obj.start + 1; /* 跳过 { */
    const char *src = obj.src;
    skip_ws(src, &pos);
    if (src[pos] == '}') {
        JsonVal null_val;
        memset(&null_val, 0, sizeof(null_val));
        return null_val;
    }
    for (;;) {
        skip_ws(src, &pos);
        /* 解析 key */
        JsonParse kp = parse_string(src, &pos);
        if (kp.error) break;
        /* 比较 key（不含引号） */
        size_t klen = (kp.val.end - 1) - (kp.val.start + 1);
        const char *kstr = src + kp.val.start + 1;
        bool match = (strlen(key) == klen && strncmp(key, kstr, klen) == 0);
        skip_ws(src, &pos);
        if (src[pos] != ':') break;
        pos++;
        skip_ws(src, &pos);
        if (match) {
            return json_parse(src, &pos).val;
        }
        /* 跳过值 */
        JsonParse vp = json_parse(src, &pos);
        if (vp.error) break;
        skip_ws(src, &pos);
        if (src[pos] == ',') { pos++; continue; }
        break;
    }
    JsonVal null_val;
    memset(&null_val, 0, sizeof(null_val));
    return null_val;
}

char *json_get_string(JsonVal obj, const char *key) {
    JsonVal v = json_get(obj, key);
    return json_string_val(v);
}

int json_get_int(JsonVal obj, const char *key) {
    JsonVal v = json_get(obj, key);
    if (v.type != JSON_NUMBER) return 0;
    /* 从 src 中提取子串并转 int */
    char buf[64];
    size_t len = v.end - v.start;
    if (len >= sizeof(buf)) return 0;
    memcpy(buf, v.src + v.start, len);
    buf[len] = '\0';
    return (int)strtod(buf, NULL);
}

long long json_get_ll(JsonVal obj, const char *key) {
    JsonVal v = json_get(obj, key);
    if (v.type != JSON_NUMBER) return 0;
    char buf[64];
    size_t len = v.end - v.start;
    if (len >= sizeof(buf)) return 0;
    memcpy(buf, v.src + v.start, len);
    buf[len] = '\0';
    return strtoll(buf, NULL, 10);
}

double json_get_double(JsonVal obj, const char *key) {
    JsonVal v = json_get(obj, key);
    return json_number_val(v);
}

bool json_get_bool(JsonVal obj, const char *key, bool def) {
    JsonVal v = json_get(obj, key);
    if (v.type == JSON_NULL) return def;
    return json_bool_val(v);
}

/* ============================================================
 * 数组操作
 * ============================================================ */

int json_array_len(JsonVal arr) {
    if (arr.type != JSON_ARRAY) return 0;
    int count = 0;
    size_t pos = arr.start + 1; /* 跳过 [ */
    const char *src = arr.src;
    skip_ws(src, &pos);
    if (src[pos] == ']') return 0;
    for (;;) {
        skip_ws(src, &pos);
        JsonParse vp = json_parse(src, &pos);
        if (vp.error) break;
        count++;
        skip_ws(src, &pos);
        if (src[pos] == ',') { pos++; continue; }
        break;
    }
    return count;
}

JsonVal json_array_get(JsonVal arr, int index) {
    if (arr.type != JSON_ARRAY) {
        JsonVal null_val;
        memset(&null_val, 0, sizeof(null_val));
        return null_val;
    }
    size_t pos = arr.start + 1;
    const char *src = arr.src;
    skip_ws(src, &pos);
    if (src[pos] == ']') {
        JsonVal null_val;
        memset(&null_val, 0, sizeof(null_val));
        return null_val;
    }
    int cur = 0;
    for (;;) {
        skip_ws(src, &pos);
        JsonParse vp = json_parse(src, &pos);
        if (vp.error) break;
        if (cur == index) return vp.val;
        cur++;
        skip_ws(src, &pos);
        if (src[pos] == ',') { pos++; continue; }
        break;
    }
    JsonVal null_val;
    memset(&null_val, 0, sizeof(null_val));
    return null_val;
}

/* ============================================================
 * 值提取
 * ============================================================ */

char *json_string_val(JsonVal v) {
    if (v.type != JSON_STRING) return NULL;
    /* 解码 JSON 字符串（去掉引号，处理转义） */
    const char *src = v.src;
    size_t start = v.start + 1; /* 跳过开引号 */
    size_t end = v.end - 1;     /* 跳过闭引号 */
    size_t len = end - start;
    char *buf = malloc(len * 2 + 1); /* 最坏情况 */
    size_t out = 0;
    for (size_t i = start; i < end; i++) {
        if (src[i] == '\\') {
            i++;
            switch (src[i]) {
                case '"':  buf[out++] = '"'; break;
                case '\\': buf[out++] = '\\'; break;
                case '/':  buf[out++] = '/'; break;
                case 'b':  buf[out++] = '\b'; break;
                case 'f':  buf[out++] = '\f'; break;
                case 'n':  buf[out++] = '\n'; break;
                case 'r':  buf[out++] = '\r'; break;
                case 't':  buf[out++] = '\t'; break;
                case 'u': {
                    /* \uXXXX — 支持 surrogate pair */
                    unsigned int cp = 0;
                    for (int j = 0; j < 4 && i + 1 < end; j++) {
                        i++;
                        char h = src[i];
                        cp = cp * 16;
                        if (h >= '0' && h <= '9') cp += h - '0';
                        else if (h >= 'a' && h <= 'f') cp += h - 'a' + 10;
                        else if (h >= 'A' && h <= 'F') cp += h - 'A' + 10;
                    }
                    /* high surrogate? 检查紧跟的 \uDC00-\uDFFF */
                    if (cp >= 0xD800 && cp <= 0xDBFF &&
                        i + 1 < end && src[i + 1] == '\\' && src[i + 2] == 'u') {
                        size_t saved = i;
                        i += 2; /* 跳过 \u */
                        unsigned int lo = 0;
                        int valid = 1;
                        for (int j = 0; j < 4 && i + 1 < end; j++) {
                            i++;
                            char h = src[i];
                            if (h >= '0' && h <= '9') lo = lo * 16 + (h - '0');
                            else if (h >= 'a' && h <= 'f') lo = lo * 16 + (h - 'a' + 10);
                            else if (h >= 'A' && h <= 'F') lo = lo * 16 + (h - 'A' + 10);
                            else { valid = 0; break; }
                        }
                        if (valid && lo >= 0xDC00 && lo <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        } else {
                            /* 不是合法 low surrogate，回退 */
                            i = saved;
                        }
                    }
                    /* UTF-8 编码 */
                    if (cp < 0x80) {
                        buf[out++] = (char)cp;
                    } else if (cp < 0x800) {
                        buf[out++] = (char)(0xC0 | (cp >> 6));
                        buf[out++] = (char)(0x80 | (cp & 0x3F));
                    } else if (cp < 0x10000) {
                        buf[out++] = (char)(0xE0 | (cp >> 12));
                        buf[out++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        buf[out++] = (char)(0x80 | (cp & 0x3F));
                    } else {
                        buf[out++] = (char)(0xF0 | (cp >> 18));
                        buf[out++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                        buf[out++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        buf[out++] = (char)(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default: buf[out++] = src[i]; break;
            }
        } else {
            buf[out++] = src[i];
        }
    }
    buf[out] = '\0';
    /* 缩减到实际大小 */
    char *result = realloc(buf, out + 1);
    return result ? result : buf;
}

double json_number_val(JsonVal v) {
    if (v.type != JSON_NUMBER) return 0.0;
    char buf[64];
    size_t len = v.end - v.start;
    if (len >= sizeof(buf)) return 0.0;
    memcpy(buf, v.src + v.start, len);
    buf[len] = '\0';
    return strtod(buf, NULL);
}

bool json_bool_val(JsonVal v) {
    if (v.type != JSON_BOOL) return false;
    /* true 的文本是 "true"，false 是 "false" */
    return v.src[v.start] == 't';
}

char *json_as_string(JsonVal v) {
    if (v.type == JSON_STRING) return json_string_val(v);
    if (v.type == JSON_NULL) return NULL;
    /* 其他类型：提取原始文本 */
    size_t len = v.end - v.start;
    char *s = malloc(len + 1);
    memcpy(s, v.src + v.start, len);
    s[len] = '\0';
    return s;
}

/* ============================================================
 * Object 迭代器
 * ============================================================ */

void json_obj_iter_init(JsonObjectIter *it, JsonVal obj) {
    memset(it, 0, sizeof(*it));
    if (obj.type != JSON_OBJECT) return;
    it->src = obj.src;
    it->pos = obj.start + 1; /* 跳过 { */
    it->first = true;
}

bool json_obj_iter_next(JsonObjectIter *it) {
    /* 释放上一次迭代的 key */
    free((char *)it->key);
    it->key = NULL;

    const char *src = it->src;
    if (!src) return false;
    skip_ws(src, &it->pos);
    if (src[it->pos] == '}' || src[it->pos] == '\0') return false;
    if (!it->first) {
        /* 跳过逗号 */
        if (src[it->pos] == ',') it->pos++;
        skip_ws(src, &it->pos);
        if (src[it->pos] == '}' || src[it->pos] == '\0') return false;
    }
    it->first = false;
    /* 解析 key */
    JsonParse kp = parse_string(src, &it->pos);
    if (kp.error) return false;
    /* key 文本（不含引号） */
    size_t klen = (kp.val.end - 1) - (kp.val.start + 1);
    char *key = malloc(klen + 1);
    memcpy(key, src + kp.val.start + 1, klen);
    key[klen] = '\0';
    it->key = key; /* 注意：指向临时 buffer，调用者用完需自行处理 */
    /* 跳过 : */
    skip_ws(src, &it->pos);
    if (src[it->pos] == ':') it->pos++;
    skip_ws(src, &it->pos);
    /* 解析 value */
    JsonParse vp = json_parse(src, &it->pos);
    if (vp.error) { free(key); return false; }
    it->val = vp.val;
    return true;
}

/* ============================================================
 * JSONL 追加
 * ============================================================ */

int jsonl_append(const char *path, const char *json_line) {
    FILE *f = fopen(path, "a");
    if (!f) return -1;
    fprintf(f, "%s\n", json_line);
    fclose(f);
    return 0;
}

void json_obj_iter_cleanup(JsonObjectIter *it) {
    free((char *)it->key);
    it->key = NULL;
}
