#ifndef UTIL_H
#define UTIL_H

#include <stddef.h>

/*
 * 工具函数 — 字符串处理、路径拼接、时间戳等
 */

/* 动态字符串缓冲区 */
typedef struct {
    char *data;
    size_t len;      /* 当前字符串长度（不含 '\0'） */
    size_t cap;      /* 缓冲区容量 */
} StrBuf;

void sb_init(StrBuf *sb);
void sb_free(StrBuf *sb);
void sb_ensure(StrBuf *sb, size_t extra);
void sb_append(StrBuf *sb, const char *s);
void sb_appendn(StrBuf *sb, const char *s, size_t n);
void sb_appendf(StrBuf *sb, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
void sb_append_char(StrBuf *sb, char c);
/* 截断到指定长度 */
void sb_truncate(StrBuf *sb, size_t len);

/* JSON 字符串转义：将 src 转义后追加到 sb */
void sb_append_json_string(StrBuf *sb, const char *src);
/* shell 参数转义：将 src 作为单个 shell 参数安全追加到 sb */
void sb_append_shell_arg(StrBuf *sb, const char *src);

/* 生成 session id: YYYYMMDD-HHMMSS-XXXX */
char *util_new_session_id(void);

/* 路径拼接：a/b （处理尾部/前导斜杠） */
char *util_path_join(const char *a, const char *b);

/* 确保目录存在（递归创建，类似 mkdir -p） */
int util_mkdirs(const char *path, int mode);

/* 获取家目录路径 */
const char *util_home_dir(void);

/* 复制字符串（strdup 的安全版本，NULL 安全） */
char *util_strdup(const char *s);

/* 安全的 free + 置 NULL */
#define FREE_PTR(p) do { free(p); (p) = NULL; } while(0)

/* 从环境变量读取，带默认值 */
const char *util_env(const char *name, const char *defval);

/* 获取当前时间戳字符串 (ISO 8601) */
char *util_timestamp_now(void);

/* 解析带 k/m/g 后缀的数字（对齐 bash 版 util_parse_size） */
long util_parse_size(const char *s);

/* 获取当前 epoch 秒 */
long util_epoch_seconds(void);

/* 计算 UTF-8 字符数（近似 token 计数用） */
int util_utf8_char_count(const char *s);

/* 返回不超过 max_bytes 的安全截断位置（不切断 UTF-8 多字节字符） */
size_t util_utf8_truncate_len(const char *s, size_t max_bytes);

/* 原地截断到 max_total 字节以内（UTF-8 安全），超长时尾部追加 "..." */
void util_truncate_str(char *s, size_t max_total);

/* 原地截断到 max_chars 个 UTF-8 字符以内，超长时尾部追加 "..." */
void util_truncate_chars(char *s, int max_chars);

/* UTF-8 sanitize：将非法字节替换为 \ufffd 字面文本，返回新 malloc'd 字符串 */
char *util_sanitize_utf8(const char *src);

/* trim 尾部空白 */
char *util_rtrim(char *s);

/* 读取整个文件到字符串 */
char *util_read_file(const char *path);

/* 写入整个文件 */
int util_write_file(const char *path, const char *content);

#endif /* UTIL_H */
