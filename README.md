# Uptime Monitor — 死活監視ダッシュボード

Rails 8 の **Solid Queue / Solid Cache / Kamal 2** を、Redis・Sidekiq・Memcached を一切立てずに動かす学習用アプリ。
URL を登録し、1分おきに HTTP を叩いて結果を記録・表示する。設計判断と計測値は [`NOTES.md`](NOTES.md) に集約。

- 実装の詳細（仕組み・手順・設計判断）: [`docs/implementation.md`](docs/implementation.md)
- 詰まりログ・計測値・判断: [`NOTES.md`](NOTES.md)
- 実装計画: [`solid-trifecta-uptime-monitor-plan.md`](solid-trifecta-uptime-monitor-plan.md)

## 技術スタック

| 領域 | 採用 |
|---|---|
| Rails | 8.1 / Ruby 3.4.9 |
| DB | SQLite（primary / cache / queue / cable の複数DB構成） |
| ジョブ | Solid Queue + `config/recurring.yml`（毎分） |
| キャッシュ | Solid Cache（ディスクベース） |
| HTTPクライアント | `Net::HTTP`（標準ライブラリ、追加gem無し） |
| ジョブ監視 | mission_control-jobs（`/jobs`, Basic認証） |
| デプロイ | Kamal 2（`config/deploy.yml`） |

> 注: モデル名は `Site`。Ruby 標準ライブラリの `Monitor` クラスと衝突するため（詳細は NOTES.md ①）。

## ドメインモデル

- **Site** — 監視対象URL 1件（`name`, `url`, `interval_seconds`, `enabled`, `last_status`, `last_checked_at`）
- **Check** — 1回のチェック結果（`ok`, `status_code`, `response_time_ms`, `error_message`, `checked_at`）
  - 集計用に複合インデックス `[:site_id, :checked_at]`

## ジョブ設計（親子分割）

```
EnqueueDueChecksJob   # recurring.yml で毎分。有効かつ時刻超過の Site を抽出し子ジョブを enqueue するだけ
  └─ CheckSiteJob     # queue: checks。実際に Net::HTTP で叩き、Check を作成・Site を更新
```

1本で全URLを順に叩くと1件のタイムアウトで全体が止まるため、子ジョブに分割して並列・リトライ・失敗の隔離を
Solid Queue に委ねている。タイムアウトはリトライし、尽きたら down として記録する。

## セットアップ

```bash
# Ruby 3.4.9（.ruby-version 参照）と bundler が前提
bundle install
bin/rails db:prepare      # 4つのDB作成 + マイグレーション + seed（監視対象4件）
```

## 起動（開発）

別々のターミナルで:

```bash
bin/rails server          # Web (http://localhost:3000)
bin/jobs                  # Solid Queue ワーカー + dispatcher（recurring 実行）
```

- ダッシュボード: <http://localhost:3000/>
- ジョブ監視: <http://localhost:3000/jobs>（Basic認証、開発デフォルト `admin` / `password`）

`bin/jobs` を起動しておくと毎分 `EnqueueDueChecksJob` が走り、登録URLへチェックが飛ぶ。
詳細ページの「今すぐチェック」で任意のタイミングでも実行できる。

### Solid Queue の永続化を体感する

`bin/jobs` を止める → チェック時刻が溜まる → 再起動すると溜まった分が処理される。
Redis 無しでジョブがDBに永続化されていることの一次体験（計画書 Phase 2）。

## キャッシュのベンチマーク（Phase 4）

大量の Check を生成して稼働率集計を計測する:

```bash
SEED_CHECKS=30000 bin/rails db:seed        # 先頭の Site に3万件生成
# /sites を開き、log/development.log の "Completed ..." 行で Views/ActiveRecord/クエリ数を確認
```

計測結果は [`NOTES.md`](NOTES.md) ② を参照（一覧ページ 19ms/25クエリ → 4ms/5クエリ、母数3万件）。

## デプロイ（Kamal 2 / Phase 5）

`config/deploy.yml` を用意済み（要 VPS）。`<VPS_IP>` / `uptime.example.com` / `your-user` を実値に置換し、
レジストリと Basic 認証のパスワードを環境変数で渡してから:

```bash
export KAMAL_REGISTRY_PASSWORD=...
export MISSION_CONTROL_HTTP_BASIC_AUTH_USER=admin
export MISSION_CONTROL_HTTP_BASIC_AUTH_PASSWORD=<強いパスワード>
kamal setup       # 初回
kamal deploy      # 2回目以降
```

要点:
- **`volumes: ["uptime_monitor_storage:/rails/storage"]`** が無いとデプロイのたびにSQLiteが消える（最重要）。
- ワーカーは方式A（`SOLID_QUEUE_IN_PUMA: true`）で Puma 内実行。SQLite の同一ホスト制約による判断（NOTES.md ③）。
- SSL は kamal-proxy が Let's Encrypt で終端。`production.rb` の `assume_ssl` / `force_ssl` を有効化済み。

## スコープ外

- **Solid Cable**（リアルタイム反映）は今回未実装（計画書 Phase 3 は任意）。cable.yml / cable DB の器だけ生成済み。
