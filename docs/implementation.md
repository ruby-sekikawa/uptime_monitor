# 実装ドキュメント — 死活監視ダッシュボード

Rails 8 の **Solid Queue / Solid Cache** を、Redis・Sidekiq・Memcached を使わずに実装した記録。
「何を・なぜ・どう作ったか」を1本にまとめる。数字と詰まりログは [`../NOTES.md`](../NOTES.md)、使い方は [`../README.md`](../README.md)。

## 目次

1. [全体構成](#1-全体構成)
2. [複数DB構成のセットアップ](#2-複数db構成のセットアップ)
3. [モデルと画面](#3-モデルと画面)
4. [Solid Queue の実装](#4-solid-queue-の実装)
5. [Solid Cache の実装](#5-solid-cache-の実装)
6. [並列性の設計（threads / processes / GVL）](#6-並列性の設計threads--processes--gvl)
7. [Kamal 2 デプロイ設定](#7-kamal-2-デプロイ設定)
8. [主要な設計判断まとめ](#8-主要な設計判断まとめ)
9. [ハマりどころと対処](#9-ハマりどころと対処)

---

## 1. 全体構成

URL を登録し、1分おきに HTTP を叩いて死活を記録・表示するダッシュボード。

```
┌─────────────┐   毎分    ┌──────────────────────┐  perform_later  ┌───────────────┐
│ recurring.yml │ ───────▶ │ EnqueueDueChecksJob  │ ──────────────▶ │ CheckSiteJob  │
│ (dispatcher)  │          │ (対象を列挙して投入)  │  (checksキュー)  │ (HTTPを叩く)   │
└─────────────┘          └──────────────────────┘                 └──────┬────────┘
                                                                          │ 記録
                                                                          ▼
                                                    Site.last_status / Check(履歴)
                                                                          │
                                              ┌───────────────────────────┘
                                              ▼
                          一覧/詳細画面（Solid Cache で稼働率と行HTMLをキャッシュ）
```

- **技術スタック**: Rails 8.1 / Ruby 3.4.9 / SQLite（複数DB）/ Solid Queue / Solid Cache / mission_control-jobs / Kamal 2
- **HTTPクライアント**: `Net::HTTP`（標準ライブラリ、追加gem無し）
- モデル名は `Site`（`Monitor` は Ruby 標準ライブラリと衝突するため。→ [9章](#9-ハマりどころと対処)）

---

## 2. 複数DB構成のセットアップ

Solid Queue / Solid Cache / Solid Cable はそれぞれ専用の SQLite ファイルに分離する。
Rails 8 のデフォルトは **production のみ複数DB、development は primary 単一**なので、開発でも同じ構成で動くよう手を入れた。

### 2.1 `config/database.yml`（development を複数DB化）

```yaml
development:
  primary:
    database: storage/development.sqlite3
  cache:
    database: storage/development_cache.sqlite3
    migrations_paths: db/cache_migrate
  queue:
    database: storage/development_queue.sqlite3
    migrations_paths: db/queue_migrate
  cable:
    database: storage/development_cable.sqlite3
    migrations_paths: db/cable_migrate
```

### 2.2 `config/environments/development.rb`

```ruby
config.cache_store = :solid_cache_store                             # キャッシュを Solid Cache に
config.action_controller.perform_caching = true                    # フラグメントキャッシュを有効化
config.active_job.queue_adapter = :solid_queue                     # ジョブを Solid Queue に
config.solid_queue.connects_to = { database: { writing: :queue } } # Queue の接続先を queue DB に
```

> **Queue と Cache で接続の指定方法が違う**のが要注意。
> Queue は `development.rb` の `connects_to`、Cache は `config/cache.yml` の `database:` で指定する。

### 2.3 スキーマの読み込み

`solid_*:install` が生成する `db/queue_schema.rb` / `db/cache_schema.rb` を、`bin/rails db:prepare` が
各DBへロードする（DB名 `queue` → `db/queue_schema.rb` という命名規約で対応づく）。

```bash
bin/rails db:prepare   # 4つのDBを作成 + primary をマイグレーション + solid_* スキーマをロード
```

### 2.4 確認

```ruby
ActiveRecord::Base.connection_db_config.database  # => storage/development.sqlite3
SolidQueue::Job.connection_db_config.database     # => storage/development_queue.sqlite3
SolidCache::Entry.connection_db_config.database   # => storage/development_cache.sqlite3
```

---

## 3. モデルと画面

scaffold ベースで最小限に作る（CSS は素のまま、ステータスは色バッジのみ）。

### モデル

```
Site   name / url / interval_seconds(既定60) / enabled(既定true) / last_status / last_checked_at
Check  site:references / ok / status_code / response_time_ms / error_message / checked_at
       add_index [:site_id, :checked_at]   # 稼働率の集計クエリ用。必須
```

- `app/models/site.rb`: `has_many :checks`、バリデーション、`scope :due`（チェック時刻を過ぎた対象）、`uptime_ratio`
- `app/models/check.rb`: `belongs_to :site`、`scope :recent`

### 画面

- 一覧 `/sites`: ステータス色バッジ・稼働率（フラグメントキャッシュ）
- 詳細 `/sites/:id`: チェック履歴50件・稼働率・「今すぐチェック」ボタン
- `/jobs`: mission_control-jobs（Basic認証）

---

## 4. Solid Queue の実装

DB をジョブキューにする仕組み。Redis 不要でジョブが `solid_queue_*` テーブルに永続化される。

### 4.1 設定の4層

| 層 | ファイル | 役割 |
|---|---|---|
| DB | `database.yml` | `queue` 接続の定義 |
| アダプタ | `development.rb` / `production.rb` | `queue_adapter = :solid_queue` と `connects_to` |
| ワーカー構成 | `queue.yml` | dispatcher と worker の定義 |
| 定期実行 | `recurring.yml` | 毎分のスケジュール |

### 4.2 ジョブ設計 — 親子分割 ★中心

```ruby
# app/jobs/enqueue_due_checks_job.rb — 毎分実行。列挙して投入するだけ（HTTPは叩かない）
class EnqueueDueChecksJob < ApplicationJob
  queue_as :default
  def perform
    Site.due(Time.current).find_each { |site| CheckSiteJob.perform_later(site.id) }
  end
end

# app/jobs/check_site_job.rb — 実際にHTTPを叩く子ジョブ
class CheckSiteJob < ApplicationJob
  queue_as :checks
  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(site_id)
    site = Site.find_by(id: site_id)
    return if site.nil?
    # Net::HTTP で open/read timeout 5秒。経過時間を計測して Check を作成、Site を更新
  end
end
```

**なぜ親子に分けたか**: 1本で全URLを順に叩くと1件のタイムアウトで全体が止まる。
子に分割して **並列実行・リトライ・失敗の隔離** をジョブ基盤に委ねる。

**エラーハンドリングの3系統**:

| ケース | 対応 | 意図 |
|---|---|---|
| タイムアウト | `retry_on`（3回）→ 尽きたら rescue して **down 記録** | 「落ちている」事実を残す |
| DNS失敗/接続拒否 | `perform_request` 内で即 down | 一時障害でないのでリトライ不要 |
| 対象削除済み | `discard_on DeserializationError` | 記録しても無意味 |

### 4.3 `config/queue.yml`

```yaml
dispatchers:
  - polling_interval: 1
    batch_size: 500
    recurring_tasks: true      # これが true でないと recurring.yml が動かない
workers:
  - queues: "checks"           # HTTPチェック専用キュー（I/Oバウンド）
    threads: 5
  - queues: "*"                # その他（親ジョブ・後片付け）
    threads: 3
```

- **dispatcher（配車係）**: 予約時刻が来たジョブを ready に昇格させ、定期ジョブを投入する。
- **worker（作業員）**: ready なジョブを claim して実際に実行する。
- `checks` を専用キューにして `threads: 5` を割り当て、他の種類のジョブと混ざって詰まらないよう隔離。

### 4.4 `config/recurring.yml`

```yaml
development: &default
  enqueue_due_checks:
    class: EnqueueDueChecksJob
    schedule: every minute
production:
  <<: *default
```

> Rails 8 生成物は `production:` だけを持つことがある。開発でも動かすため
> `development: &default` を定義し `production: <<: *default` で共有した。

### 4.5 ジョブのライフサイクル（テーブルの動き）

```
perform_later → solid_queue_jobs にINSERT →（即実行可なら）ready_executions
worker がポーリング(1秒) → 空きスレッド分を claim（ready→claimed_executions へ移動）
perform 実行 → 成功: claimed削除 + finished_at セット / 失敗: failed_executions へ
```

- **claim** により1ジョブを1ワーカーが専有 → 二重実行を防ぐ（DBの排他制御を利用。SQLite は単一ライターロック）。
- ワーカーが死んでも `solid_queue_processes` の heartbeat 監視で claimed を ready に戻して回収。

### 4.6 起動

- 開発: `bin/jobs`（dispatcher + worker を queue.yml どおり起動）
- 本番: `SOLID_QUEUE_IN_PUMA=true` で Puma プロセス内にワーカーを同居（`config/puma.rb` の `plugin :solid_queue`）

---

## 5. Solid Cache の実装

DB をキャッシュストアにする仕組み。`solid_cache_entries` テーブルにディスク保存。

### 5.1 設定

```yaml
# config/cache.yml
development:
  database: cache          # ← development にも必要（デフォルトは production だけ）
  store_options:
    max_size: <%= 256.megabytes %>
    namespace: <%= Rails.env %>
```

### 5.2 使いどころ — 詳細ページの低レベルキャッシュ（`app/models/site.rb`）

```ruby
def uptime_ratio(period = 24.hours)
  Rails.cache.fetch([ cache_key_with_version, "uptime", period.to_i ], expires_in: 5.minutes) do
    scope = checks.where(checked_at: period.ago..)
    total = scope.count
    total.zero? ? nil : (scope.where(ok: true).count.to_f / total * 100).round(2)
  end
end
```

- キーは `cache_key_with_version`（`sites/1-<updated_at>`）を含むので、**Site を更新すると自動的に別キー**になり即失効する。
- Check が増えるだけでは `sites.updated_at` は動かないので、そこは **TTL 5分**で反映上限を決める。
  `touch: true` で即時反映もできるが、1分ごとに大量の Check を作る本アプリでは `sites` への書き込み競合を招くため不採用。
- 保存キー例: `development:sites/1-20260814060631925095/uptime/86400`（値は `100.0` のような Float）。

> **一覧ページではキャッシュを使っていない**。当初はフラグメントキャッシュ（`<% cache site %>`）を使っていたが、
> 計測の結果、一覧の稼働率は **N+1** で、キャッシュは対症療法にすぎなかった。→ 5.3 参照。

### 5.3 一覧の N+1 を GROUP BY で畳んだ（キャッシュより根治を優先）★見直し

一覧で各行 `site.uptime_ratio` を呼ぶと **1 + 2N クエリ**の N+1 になる。キャッシュはこれを2回目以降隠すだけで、
コールドや失効のたびに N+1 が再発する。そこで**全サイトの稼働率を1クエリで取る**メソッドに畳んだ。

```ruby
# app/models/site.rb
def self.uptime_ratios(period = 24.hours)
  Check.where(checked_at: period.ago..)
       .group(:site_id)
       .pluck(Arel.sql("site_id"),
              Arel.sql("ROUND(100.0 * SUM(CASE WHEN ok THEN 1 ELSE 0 END) / COUNT(*), 2)"))
       .to_h    # { site_id => ratio_or_nil }
end
```

```ruby
# controller: 1 クエリで全サイトぶん取得
@uptime = Site.uptime_ratios(24.hours)
```
```erb
<%= uptime_label(@uptime[site.id]) %>   <!-- ビューはハッシュ参照。行ごとのクエリ0 -->
```

**3パターンの実測**（一覧ページ `/sites`、サイト4件、クエリ本数で比較）:

| 実装 | コールド | ウォーム | 鮮度 |
|---|---|---|---|
| A. N+1 + フラグメントキャッシュ（当初） | 25 | 5 | TTLで最大5分古い |
| B. 集計1クエリ + キャッシュ | 10 | 6 | TTLで最大5分古い |
| C. 集計1クエリ・キャッシュなし（採用） | **2** | **2** | **常に最新** |

- 50サイト×各200チェック（1万件）の集計コストは **N+1: 100クエリ/43ms → GROUP BY: 1クエリ/19ms**（結果一致）。
- **C が全項目で最良**。集計を畳んだ後は、フラグメントキャッシュはむしろ二重コストで足を引っ張る（B > C）。
- 教訓: **キャッシュの前にまず N+1 を疑う。計測 → 根本原因の特定 → 根治（GROUP BY）→ 必要なら最後にキャッシュ**。
  dev モードの計測はテンプレートコンパイルが混ざるので、判断は**クエリ本数**と**本番モードの再計測**で行う。

---

## 6. 並列性の設計（threads / processes / GVL）

`checks` キューに `threads: 5` を割り当てた根拠。

- **同時実行数 = threads × processes**。
- Ruby(MRI) には **GVL** があり、Rubyコードを実行できるのは1プロセス内で常に1スレッドだけ。
- ただし **I/O待ち（HTTP応答待ち）の間はGVLを手放す**（スレッドは眠り、通信はOS+相手サーバーが担う）。
- `CheckSiteJob` は応答待ちが大半の **I/Oバウンド** → 複数の待ちを重ね合わせられる → **threads を増やすと効く**。
- 逆にCPU中心の処理は GVL を握りっぱなしで並列化しない → **processes（GVLごと増やす）** で対応する。
  そのための環境変数が `JOB_CONCURRENCY`（`queue.yml` の `processes:` に流す値。本アプリは I/O 中心のため未使用）。

| 処理の種類 | 増やすべきもの | 理由 |
|---|---|---|
| I/Oバウンド（HTTP/DB/外部API） | `threads` | 待ちを重ねられる |
| CPUバウンド（画像変換/大量計算） | `processes`（`JOB_CONCURRENCY`） | GVLを増やして真の並列に |

---

## 7. Kamal 2 デプロイ設定

`config/deploy.yml`（実デプロイは VPS が必要。`<VPS_IP>` 等はプレースホルダ）。

- **`volumes: ["uptime_monitor_storage:/rails/storage"]`** ★最重要。無いとデプロイ毎にSQLiteが消える。
- **`SOLID_QUEUE_IN_PUMA: true`（方式A）**: 1台構成ではワーカーを Puma 内で動かすのが最も簡単。
  SQLite は同一ホストのファイルなので、別ホストのワーカーからは共有できない。複数台化するなら
  job ロールに分離するが、その場合も同一ホスト・同一ボリューム共有が前提（→ 方式Aを選んだ理由）。
- **SSL**: kamal-proxy が Let's Encrypt で終端。`production.rb` の `assume_ssl` / `force_ssl` を有効化済み。
- `/jobs` の Basic 認証は `MISSION_CONTROL_HTTP_BASIC_AUTH_USER/PASSWORD` を `.kamal/secrets` 経由で注入。

```bash
export KAMAL_REGISTRY_PASSWORD=... MISSION_CONTROL_HTTP_BASIC_AUTH_PASSWORD=...
kamal setup    # 初回
kamal deploy   # 2回目以降
```

---

## 8. 主要な設計判断まとめ

| 判断 | 理由 |
|---|---|
| ジョブを親子に分割 | 1件のタイムアウトで全体を止めないため。並列・リトライ・失敗を隔離 |
| リトライ全滅後も down を記録 | 死活監視では「落ちている」事実こそ残したい |
| `checks` 専用キュー + threads:5 | HTTPチェックはI/Oバウンド。待ちを重ねて効率化 |
| ワーカーを Puma 内（方式A） | SQLite の同一ホスト制約。1台構成では最も簡単 |
| 一覧は GROUP BY 1クエリ（キャッシュ撤去） | 計測の結果 N+1 が根本原因。集計を畳めば常に最新・最少クエリでキャッシュ不要 |
| 詳細ページの稼働率は Solid Cache（TTL 5分） | Check 増加の反映上限。`touch` は書き込み競合を招くため不採用 |
| モデル名 Site | `Monitor` は Ruby 標準ライブラリと衝突するため |

---

## 9. ハマりどころと対処

| 症状 | 原因 | 対処 |
|---|---|---|
| `rails new` が SyntaxError | Rails 8.1 は実質 Ruby 3.4+ 必要 | `.ruby-version` を 3.4.9 に |
| `Monitor.all` が `undefined method` | Ruby 標準ライブラリの `Monitor` と衝突しZeitwerkが読めない | モデル名を `Site` に変更 |
| Solid Cache が `solid_cache_entries` を見つけられない | `cache.yml` の development に `database: cache` が無く primary を見ていた | development にも `database: cache` |
| `db:prepare` が古い `monitors` テーブルを復活 | 旧 `db/schema.rb` が残っていた | schema.rb と sqlite を消してマイグレーションから再生成 |
| 定期ジョブが動かない | `recurring.yml` が production キーだけ / `recurring_tasks: false` | development キー追加 & dispatcher の `recurring_tasks: true` 確認 |
| `SQLite3::BusyException` | ワーカーの書き込み競合 | スレッド数を下げる（5→3 等） |

詳細な計測値（例: 一覧ページ 19ms/25クエリ → 4ms/5クエリ、母数3万件）は [`../NOTES.md`](../NOTES.md) を参照。
