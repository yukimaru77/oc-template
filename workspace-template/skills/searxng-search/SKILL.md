---
name: searxng-search
description: Keyword-based web search using a local SearXNG instance.
author: yukimaru
version: 2.0.0
keywords:
  - search
  - searxng
  - web
  - keyword
requires:
  bins:
    - bash
    - curl
    - jq
---

# searxng-search

この skill はローカルの SearXNG を使って Web 検索を行う。

## 使うべき場面

- Web 検索が必要なとき
- 論文、実装、比較調査の入口を探したいとき
- 検索語を変えながら複数回掘りたいとき

## 方針

- 1回で終わらせず、検索語を改善したり、新たな疑問点を繰り返し検索してより深く事実確認を行う
- URL と snippet を見て、必要なら追加検索する
- 必要なら本文確認につなげる

## 実行方法

次の script を使う:

```bash
/workspace/skills/searxng-search/searxng_search.sh "検索クエリ"
````

オプション:

```bash
--limit N
--json
```

例:

```bash
/workspace/skills/searxng-search/searxng_search.sh "OpenClaw browser tool"
/workspace/skills/searxng-search/searxng_search.sh --limit 3 "PyTorch FSDP tutorial"
/workspace/skills/searxng-search/searxng_search.sh --json "DGX Spark specs"
```

## 環境変数

```bash
SEARXNG_URL
```

未設定なら次を使う:

```bash
http://10.65.100.1:18080
```

