#!/usr/bin/env python3
"""使用 X API v2 分页抓取某条帖子的公开回复。

用法：
  export X_BEARER_TOKEN='你的 Bearer Token'
  python3 scripts/fetch_x_replies.py \
    'https://x.com/tianyi/status/2083519855203078320'

也可以传入帖子 ID：
  python3 scripts/fetch_x_replies.py 2083519855203078320

默认输出到 data/x-replies-2083519855203078320.json 和 .csv。
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

API_URL = "https://api.x.com/2/tweets/search/all"
RECENT_API_URL = "https://api.x.com/2/tweets/search/recent"
DEFAULT_TWEET_URL = "https://x.com/tianyi/status/2083519855203078320"

TWEET_FIELDS = ",".join(
    [
        "id",
        "text",
        "author_id",
        "conversation_id",
        "created_at",
        "entities",
        "public_metrics",
        "possibly_sensitive",
        "lang",
        "referenced_tweets",
        "reply_settings",
        "attachments",
    ]
)
USER_FIELDS = ",".join(
    [
        "id",
        "name",
        "username",
        "description",
        "url",
        "created_at",
        "public_metrics",
        "verified",
        "protected",
        "entities",
    ]
)
EXPANSIONS = "author_id,referenced_tweets.id,attachments.media_keys"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="抓取 X 帖子下的公开回复")
    parser.add_argument(
        "tweet",
        nargs="?",
        default=DEFAULT_TWEET_URL,
        help="帖子 URL 或帖子 ID",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Bearer Token；不建议直接写在命令行，优先使用 X_BEARER_TOKEN",
    )
    parser.add_argument(
        "--api",
        choices=("all", "recent"),
        default="all",
        help="all 需要全量搜索权限；recent 适合最近 7 天内的帖子",
    )
    parser.add_argument(
        "--out-dir",
        default="data",
        help="输出目录，默认 data",
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=100,
        help="最多请求页数，默认 100；每页最多 100 条",
    )
    parser.add_argument(
        "--sleep",
        type=float,
        default=0.2,
        help="分页请求间隔秒数，默认 0.2",
    )
    parser.add_argument(
        "--start-time",
        default=None,
        help="可选 RFC3339 起始时间，例如 2026-08-01T00:00:00Z",
    )
    parser.add_argument(
        "--end-time",
        default=None,
        help="可选 RFC3339 结束时间，例如 2026-08-03T00:00:00Z",
    )
    return parser.parse_args()


def extract_tweet_id(value: str) -> str:
    value = value.strip()
    if value.isdigit():
        return value
    match = re.search(r"/status/(\d+)", value)
    if not match:
        raise ValueError(f"无法从输入中解析帖子 ID：{value}")
    return match.group(1)


def bearer_token(args: argparse.Namespace) -> str:
    token = args.token or os.environ.get("X_BEARER_TOKEN") or os.environ.get(
        "TWITTER_BEARER_TOKEN"
    )
    if not token:
        raise RuntimeError(
            "未找到 Bearer Token。请先执行：export X_BEARER_TOKEN='你的令牌'"
        )
    return token.strip()


def get_json(url: str, token: str, params: dict[str, Any]) -> dict[str, Any]:
    query = urlencode({key: value for key, value in params.items() if value is not None})
    request = Request(
        f"{url}?{query}",
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": "x-reply-collector/1.0",
            "Accept": "application/json",
        },
        method="GET",
    )
    try:
        with urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
            return json.loads(body)
    except HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(body)
        except json.JSONDecodeError:
            detail = body[:1000]
        raise RuntimeError(f"X API HTTP {error.code}: {detail}") from error
    except URLError as error:
        raise RuntimeError(f"无法连接 X API：{error.reason}") from error


def expanded_github_urls(tweet: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    entities = tweet.get("entities") or {}
    for url in entities.get("urls") or []:
        expanded = url.get("expanded_url") or url.get("unwound_url") or url.get("url")
        if expanded and re.search(r"(?:https?://)?(?:www\.)?github\.com/", expanded, re.I):
            urls.append(expanded)
    return sorted(set(urls))


def make_flat_reply(tweet: dict[str, Any], users: dict[str, dict[str, Any]]) -> dict[str, Any]:
    author = users.get(tweet.get("author_id", ""), {})
    metrics = tweet.get("public_metrics") or {}
    referenced = tweet.get("referenced_tweets") or []
    return {
        "tweet_id": tweet.get("id"),
        "tweet_url": f"https://x.com/{author.get('username', 'i')}/status/{tweet.get('id')}",
        "text": tweet.get("text", ""),
        "created_at": tweet.get("created_at"),
        "conversation_id": tweet.get("conversation_id"),
        "author_id": tweet.get("author_id"),
        "author_username": author.get("username"),
        "author_name": author.get("name"),
        "author_url": f"https://x.com/{author['username']}" if author.get("username") else None,
        "author_description": author.get("description"),
        "author_profile_url": author.get("url"),
        "author_verified": author.get("verified"),
        "author_protected": author.get("protected"),
        "author_followers": (author.get("public_metrics") or {}).get("followers_count"),
        "author_following": (author.get("public_metrics") or {}).get("following_count"),
        "reply_count": metrics.get("reply_count"),
        "repost_count": metrics.get("retweet_count"),
        "like_count": metrics.get("like_count"),
        "quote_count": metrics.get("quote_count"),
        "bookmark_count": metrics.get("bookmark_count"),
        "impression_count": metrics.get("impression_count"),
        "lang": tweet.get("lang"),
        "referenced_tweets": referenced,
        "github_urls": expanded_github_urls(tweet),
        "entities": tweet.get("entities"),
    }


def fetch_replies(
    tweet_id: str,
    token: str,
    api_kind: str,
    max_pages: int,
    sleep_seconds: float,
    start_time: str | None,
    end_time: str | None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    api_url = RECENT_API_URL if api_kind == "recent" else API_URL
    query = f"conversation_id:{tweet_id} -is:retweet"
    params: dict[str, Any] = {
        "query": query,
        "max_results": 100,
        "tweet.fields": TWEET_FIELDS,
        "expansions": EXPANSIONS,
        "user.fields": USER_FIELDS,
        "start_time": start_time,
        "end_time": end_time,
    }

    tweets: dict[str, dict[str, Any]] = {}
    users: dict[str, dict[str, Any]] = {}
    pages = 0
    api_meta: dict[str, Any] = {}

    while pages < max_pages:
        pages += 1
        print(f"请求第 {pages} 页：{api_url}", file=sys.stderr)
        payload = get_json(api_url, token, params)
        api_meta = payload.get("meta") or {}
        for tweet in payload.get("data") or []:
            tweets[tweet["id"]] = tweet
        for user in (payload.get("includes") or {}).get("users") or []:
            users[user["id"]] = user

        next_token = api_meta.get("next_token")
        print(
            f"本页 {len(payload.get('data') or [])} 条，累计 {len(tweets)} 条；"
            f"剩余结果 {api_meta.get('result_count', '?')} 条",
            file=sys.stderr,
        )
        if not next_token:
            break
        params["next_token"] = next_token
        if sleep_seconds > 0:
            time.sleep(sleep_seconds)

    replies = [make_flat_reply(tweet, users) for tweet in tweets.values()]
    replies.sort(key=lambda item: item.get("created_at") or "")
    return replies, {
        "api": api_kind,
        "api_url": api_url,
        "query": query,
        "pages_requested": pages,
        "last_meta": api_meta,
        "users_returned": len(users),
    }


def write_outputs(
    replies: list[dict[str, Any]],
    tweet_id: str,
    source: str,
    fetch_info: dict[str, Any],
    out_dir: Path,
) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / f"x-replies-{tweet_id}.json"
    csv_path = out_dir / f"x-replies-{tweet_id}.csv"
    captured_at = datetime.now(timezone.utc).isoformat()
    authors = {item["author_id"] for item in replies if item.get("author_id")}
    github_replies = [item for item in replies if item.get("github_urls")]
    result = {
        "source": source,
        "captured_at": captured_at,
        "tweet_id": tweet_id,
        "tweet_url": f"https://x.com/i/status/{tweet_id}",
        "capture_scope": "X API 搜索结果中的公开回复；不保证覆盖已删除、受保护或被平台隐藏的回复",
        "total_replies": len(replies),
        "unique_authors": len(authors),
        "replies_with_github_urls": len(github_replies),
        "github_url_count": len({url for item in replies for url in item.get("github_urls", [])}),
        "fetch": fetch_info,
        "replies": replies,
    }
    json_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    fieldnames = [
        "tweet_id",
        "tweet_url",
        "text",
        "created_at",
        "conversation_id",
        "author_id",
        "author_username",
        "author_name",
        "author_url",
        "author_description",
        "author_profile_url",
        "author_verified",
        "author_protected",
        "author_followers",
        "author_following",
        "reply_count",
        "repost_count",
        "like_count",
        "quote_count",
        "bookmark_count",
        "impression_count",
        "lang",
        "github_urls",
        "referenced_tweets",
    ]
    with csv_path.open("w", encoding="utf-8-sig", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for item in replies:
            row = dict(item)
            row["github_urls"] = "\n".join(row.get("github_urls") or [])
            row["referenced_tweets"] = json.dumps(
                row.get("referenced_tweets") or [], ensure_ascii=False
            )
            writer.writerow(row)
    return json_path, csv_path


def main() -> int:
    args = parse_args()
    try:
        token = bearer_token(args)
        tweet_id = extract_tweet_id(args.tweet)
        replies, fetch_info = fetch_replies(
            tweet_id=tweet_id,
            token=token,
            api_kind=args.api,
            max_pages=args.max_pages,
            sleep_seconds=args.sleep,
            start_time=args.start_time,
            end_time=args.end_time,
        )
        json_path, csv_path = write_outputs(
            replies=replies,
            tweet_id=tweet_id,
            source=args.tweet,
            fetch_info=fetch_info,
            out_dir=Path(args.out_dir),
        )
    except (RuntimeError, ValueError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1

    authors = {item["author_id"] for item in replies if item.get("author_id")}
    github_urls = {url for item in replies for url in item.get("github_urls", [])}
    print(f"抓取完成：{len(replies)} 条回复")
    print(f"去重后作者：{len(authors)} 人")
    print(f"包含 GitHub 链接的回复：{sum(bool(x.get('github_urls')) for x in replies)} 条")
    print(f"唯一 GitHub 链接：{len(github_urls)} 个")
    print(f"JSON：{json_path}")
    print(f"CSV：{csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
