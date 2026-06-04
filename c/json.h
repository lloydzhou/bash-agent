#ifndef JSON_H
#define JSON_H

#include <stddef.h>
#include <stdbool.h>

/*
 * 轻量 JSON 解析器 — 仅支持解析 Claude/OpenAI API 响应和 conversation.jsonl
 *
 * 设计：
 *   - 单遍扫描，零拷贝（值指向原始 JSON 字符串内部）
 *   - 提供 json_get_string 等提取函数，返回需要 free 的副本
 *   - 支持 JSON 对象、数组、字符串、数字、布尔、null
 *   - 不支持 JSON 写入（用 StrBuf 手动拼接即可）
 */

/* JSON 值类型 */
typedef enum {
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
} JsonType;

/* JSON 值 — 指向原始 JSON 文本内部的视图 */
typedef struct {
    JsonType type;
    const char *src;        /* 指向原始 JSON 字符串 */
    size_t start;           /* 值在 src 中的起始位置 */
    size_t end;             /* 值在 src 中的结束位置（不含） */
    /* 对于 STRING：src+start..src+end 是原始值（含引号） */
    /* 对于 OBJECT/ARRAY：src+start..src+end 是整个结构 */
} JsonVal;

/* 解析结果 */
typedef struct {
    JsonVal val;            /* 解析出的值 */
    const char *error;      /* 错误信息，NULL 表示成功 */
} JsonParse;

/* ============================================================
 * 解析函数
 * ============================================================ */

/* 解析 JSON 值，从 src+pos 开始，返回解析结果和更新后的 pos */
JsonParse json_parse(const char *src, size_t *pos);

/* 解析完整的 JSON 字符串（从根开始） */
JsonParse json_parse_root(const char *src);

/* ============================================================
 * 查询函数 — 从 OBJECT 中提取字段
 * ============================================================ */

/* 获取 object 中 key 对应的值，如果不存在返回 type=JSON_NULL */
JsonVal json_get(JsonVal obj, const char *key);

/* 获取字符串值（返回需要 free 的副本，找不到返回 NULL） */
char *json_get_string(JsonVal obj, const char *key);

/* 获取整数值 */
int json_get_int(JsonVal obj, const char *key);

/* 获取 long long 整数值（用于大 token 计数） */
long long json_get_ll(JsonVal obj, const char *key);

/* 获取浮点数值 */
double json_get_double(JsonVal obj, const char *key);

/* 获取布尔值（找不到返回 def） */
bool json_get_bool(JsonVal obj, const char *key, bool def);

/* ============================================================
 * 数组操作
 * ============================================================ */

/* 获取数组长度 */
int json_array_len(JsonVal arr);

/* 获取数组第 i 个元素（越界返回 JSON_NULL） */
JsonVal json_array_get(JsonVal arr, int index);

/* ============================================================
 * 值提取
 * ============================================================ */

/* 从 JSON_STRING 值中提取解码后的字符串（返回需 free 的副本） */
char *json_string_val(JsonVal v);

/* 从 JSON_NUMBER 值中提取 double */
double json_number_val(JsonVal v);

/* 从 JSON_BOOL 值中提取 bool */
bool json_bool_val(JsonVal v);

/* 通用提取：如果 v 是字符串则解码返回，否则返回 NULL */
char *json_as_string(JsonVal v);

/* ============================================================
 * 遍历 OBJECT 的键值对
 * ============================================================ */

typedef struct {
    const char *key;        /* 键名（malloc 分配，_next 自动释放上次） */
    JsonVal val;            /* 值 */
    /* 内部状态 */
    const char *src;
    size_t pos;
    bool first;
} JsonObjectIter;

void json_obj_iter_init(JsonObjectIter *it, JsonVal obj);
bool json_obj_iter_next(JsonObjectIter *it);
void json_obj_iter_cleanup(JsonObjectIter *it);  /* 提前退出循环时调用 */

/* ============================================================
 * JSON Lines 追加写入
 * ============================================================ */

/* 向 JSONL 文件追加一行（自动加 \n） */
int jsonl_append(const char *path, const char *json_line);

#endif /* JSON_H */
