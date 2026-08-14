# 実装計画書（面接向け一次体験版）
## 死活監視ダッシュボードで Solid Queue / Solid Cache / Kamal 2 を動かす

## 0. この計画書の前提

**目的は「Rails 8 の新しい構成について聞かれたときに、自分の手で動かした話ができる状態になること」。**
網羅的な習得ではないので、語れる材料にならない部分は意図的に削っている。

- 想定工数: 週末1〜2回（実働 10〜14時間）
- 題材: 死活監視ダッシュボード（URLを登録し、定期的にHTTPを叩いて記録・表示する）
- **Solid Cable は今回スコープ外**（Phase 3 に任意課題として残置）

### なぜ「捨てコードの練習課題」にしないか

「5秒待ってログを出すジョブ」「わざと重いページ」でも技術的には同じことを試せるが、
面接で聞かれるのは技術名ではなく**なぜその判断をしたか**。
死活監視なら「1件のタイムアウトが全体を止めるから親子ジョブに分けた」「稼働率集計が実際に重かったからキャッシュした」と、
必要性が先にある形で説明できる。作為的な題材だとここが語れない。

---

## 1. 完成状態の定義

- VPS 上に Kamal 2 でデプロイされ、HTTPS でアクセスできる
- 1分おきに登録URLへHTTPリクエストが飛び、結果がDBに蓄積される
- 稼働率の集計がキャッシュされ、**キャッシュ前後の実測値を数字で言える**
- Redis / Sidekiq / Memcached を一切立てていない

---

## 2. 技術スタック

| 領域 | 採用 |
|---|---|
| Rails | 8.x（`rails new` のデフォルトをなるべく崩さない） |
| DB | SQLite（primary / cache / queue の複数DB構成） |
| ジョブ | Solid Queue + `config/recurring.yml` |
| キャッシュ | Solid Cache |
| HTTPクライアント | `Net::HTTP`（標準、追加gem不要） |
| デプロイ | Kamal 2（VPS 1台、月数百円〜） |
| ジョブ監視 | mission_control-jobs |

---

## Phase 0: 生成物を読む（1時間）

**作業**

```
rails new uptime_monitor
```

生成された以下を**読むだけ**。この時点でコードは書かない。

- `config/database.yml` — 複数DB構成になっているか
- `config/queue.yml` / `config/cache.yml` / `config/recurring.yml`
- `config/deploy.yml`（Kamalの設定が最初から入っている）
- `db/queue_schema.rb` / `db/cache_schema.rb`
- `config/environments/production.rb` — cache_store と queue_adapter の指定

**注意**

Rails 8 の生成物は **production のみ複数DB構成で、development は primary だけ**という場合がある。
開発環境でも動かしたいので、`database.yml` の development に queue / cache を追加し、
`config/environments/development.rb` に以下を足す。

- `config.active_job.queue_adapter = :solid_queue`
- `config.solid_queue.connects_to = { database: { writing: :queue } }`
- `config.cache_store = :solid_cache_store`

**確認すること**

- [ ] `storage/` 配下に用途別の .sqlite3 が生成される
- [ ] `rails console` で `ActiveRecord::Base.connection` と `SolidQueue::Job.connection` が別DBを向いている

**メモに残すこと**: デフォルトで何が有効になっていたか（面接で「デフォルトでこうなっていました」と言える）

---

## Phase 1: モデルと最低限の画面（2時間）

**作り込まない。scaffold で済ませる。**

```
Monitor
  name              :string   not null
  url               :string   not null
  interval_seconds  :integer  default: 60
  enabled           :boolean  default: true
  last_status       :string             # "up" / "down" / nil
  last_checked_at   :datetime

Check
  monitor           :references
  ok                :boolean  not null
  status_code       :integer
  response_time_ms  :integer
  error_message     :string
  checked_at        :datetime not null
  index [:monitor_id, :checked_at]      # 集計クエリ用。必須
```

**画面**: 一覧（ステータスを色で表示）と詳細（履歴テーブル + 稼働率）のみ。CSSは触らない。

**登録するURL**: 正常なもの2件 + 必ず失敗するもの1件（存在しないホスト、または `https://httpbin.org/status/500`）

---

## Phase 2: Solid Queue（半日）★語れる部分

**ジョブ設計 — ここが面接の話の中心になる**

```
EnqueueDueChecksJob        # recurring で毎分実行
  → 有効かつチェック時刻を過ぎた Monitor を抽出
  → 各 Monitor ごとに CheckMonitorJob を enqueue

CheckMonitorJob(monitor)   # 実際にHTTPを叩く
  queue_as :checks
  → Net::HTTP、open_timeout / read_timeout は 5秒
  → 経過時間を計測して Check を作成
  → Monitor の last_status / last_checked_at を更新
```

**親子に分けた理由（そのまま面接で話す内容）**

1つのジョブで全URLを順に叩くと、1件のタイムアウトで全体が止まる。
子ジョブに分割することで、並列実行・リトライ・失敗の隔離をジョブ基盤に任せられる。

**config/recurring.yml**

```yaml
development: &default
  enqueue_due_checks:
    class: EnqueueDueChecksJob
    schedule: every minute
production:
  <<: *default
```

**config/queue.yml**

```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
      recurring_tasks: true
  workers:
    - queues: "checks"
      threads: 5
    - queues: "*"
      threads: 3
```

**エラーハンドリング**

- `retry_on Net::OpenTimeout, wait: :polynomially_longer, attempts: 3`
  ただし「落ちている」ことは記録したいので、リトライ全滅後に down として保存する
- `discard_on ActiveJob::DeserializationError`（監視対象が削除済みのケース）

**mission_control-jobs** を入れて `/jobs` にマウント（Basic認証で十分）

**起動**: 開発は別ターミナルで `bin/jobs`

**確認すること**

- [ ] `solid_queue_jobs` に行が入り、実行後に移動すること
- [ ] 失敗ジョブが `solid_queue_failed_executions` に記録されること
- [ ] **`bin/jobs` を止める → ジョブが溜まる → 再起動で溜まった分が処理される**
      （Redis なしで永続化されているという一次体験。ここは必ずやる）
- [ ] 監視対象を30件に増やし、`threads` を変えて処理時間の差を見る

---

## Phase 3【任意・時間がなければ飛ばす】Solid Cable

リアルタイム反映（Turbo Stream ブロードキャスト）。今回の話の本筋ではないため優先度は低い。

面接では「Cable は今回触っていません」と正直に言う。
浅く3つ触った話より、2つを理由付きで語れるほうが信用される。

余力がある場合のみ:
`config/cable.yml` を `adapter: solid_cable` にし、`CheckMonitorJob` からステータス変化時に
`Turbo::StreamsChannel.broadcast_replace_to` を呼ぶ。
`polling_interval` を変えて遅延の差を体感すると、push型pubsubとの違いが分かる。

---

## Phase 4: Solid Cache（半日）★数字を取る

**まず計測してから入れる。順序が逆だと「重かったから入れた」と言えなくなる。**

1. シードで Check を1〜3万件生成する
2. 稼働率ページを開き、**ログの Views / ActiveRecord の時間を記録**
3. キャッシュを入れる
4. もう一度測る

```ruby
class Monitor < ApplicationRecord
  def uptime_ratio(period = 24.hours)
    Rails.cache.fetch([cache_key_with_version, "uptime", period.to_i], expires_in: 5.minutes) do
      scope = checks.where(checked_at: period.ago..)
      total = scope.count
      total.zero? ? nil : (scope.where(ok: true).count.to_f / total * 100).round(2)
    end
  end
end
```

一覧側はフラグメントキャッシュ（`<% cache monitor do %>`）。

**確認すること**

- [ ] **キャッシュ前後の数字を控える（母数とセットで。例: 「Check 1万件の集計で 320ms → 8ms」）**
- [ ] `solid_cache_entries` の行数とサイズを見て、ディスクベースであることを確認
- [ ] `cache_key_with_version` により、レコード更新で自動的に別キーになることを確認

---

## Phase 5: Kamal 2 デプロイ（1日）★一番効く

**前提**: VPS 1台（さくら / ConoHa / Hetzner など）、ドメイン1つ、コンテナレジストリ

**config/deploy.yml の要点**

```yaml
service: uptime-monitor
image: <user>/uptime-monitor

servers:
  web:
    - <VPS_IP>

proxy:
  ssl: true
  host: uptime.example.com

registry:
  username: <user>
  password:
    - KAMAL_REGISTRY_PASSWORD

env:
  secret:
    - RAILS_MASTER_KEY
  clear:
    SOLID_QUEUE_IN_PUMA: true

# ★最重要★ これがないとデプロイのたびにDBが消える
volumes:
  - "uptime_monitor_storage:/rails/storage"
```

**ワーカーの動かし方 — ここも判断として語れる**

| 方式 | 特徴 |
|---|---|
| A. Puma内（`SOLID_QUEUE_IN_PUMA: true`） | 1台構成なら最も簡単。今回はこれ |
| B. 別ロール（`servers.job.cmd: bin/jobs`） | 分離できるが、SQLite なので**同一ホストで同じvolumeを共有する必要がある** |

「なぜAにしたか」を、SQLiteのファイル制約とセットで説明できるようにしておく。

**手順**

```
kamal setup          # 初回
kamal deploy         # 2回目以降
kamal app logs -f
kamal app exec -i "bin/rails console"
```

**確認すること**

- [ ] HTTPS でアクセスできる
- [ ] `kamal app exec "ls -la /rails/storage"` で sqlite3 ファイルを確認
- [ ] デプロイ後もジョブが動き続けている（mission_control で確認）
- [ ] 詰まった箇所（SSL / ヘルスチェック / 環境変数）を**その場でメモする**

---

## Phase 6【余力があれば】自分自身を監視する

デプロイ済みアプリに、**アプリ自身のURL**を監視対象として登録し、
`interval_seconds` を10秒に短縮した状態で次のデプロイを実行する。

- kamal-proxy のゼロダウンタイム切り替えが効いていれば、履歴に down が出ない
- コンテナ再起動中はジョブが止まるので、その間のチェックが欠落する。再開後の挙動を見る

「自作の監視アプリで自分のデプロイのダウンタイムを測った」は、そのまま面接のエピソードになる。

---

## 3. 作業中に必ず残すもの（最重要）

**後から思い出せないので、その場で書く。ここが一番語れるのに、一番忘れる。**

### ① 詰まったことログ

1行でいいので、症状・原因・対処をその場で書く。

```
例）
- kamal deploy 後にデータが消えた → volumes 未設定 → deploy.yml に storage を追加
- 定期ジョブが動かない → recurring.yml の環境キーが production だけだった → development を追加
- SQLite3::BusyException → ワーカースレッド5で書き込み競合 → 3に下げて解消
```

### ② 計測値

キャッシュ前後の数字。**必ず母数とセットで**（「1万件の集計で320ms→8ms」）。
数字だけだと条件が分からず、突っ込まれたときに答えられない。

### ③ 判断を変えた場面

- ジョブを1本にせず親子に分けた理由
- ワーカーを Puma 内にした理由（SQLite の同一ホスト制約）
- キャッシュの TTL を5分にした理由

**この3つは手を動かした人しか持っていない情報なので、ここで差がつく。**

---

## 4. 想定されるハマりどころ

| 症状 | 原因 | 対処 |
|---|---|---|
| デプロイのたびにデータが消える | `volumes:` 未設定 | deploy.yml に storage の volume を追加 |
| `SQLite3::BusyException` | 書き込み競合 | WALモード確認、timeout設定、スレッド数を下げる |
| 定期ジョブが動かない | recurring.yml の環境キー違い / `recurring_tasks: false` | queue.yml と recurring.yml の両方を確認 |
| ジョブがDBを見つけられない | `connects_to` の設定漏れ | development.rb を確認 |
| Let's Encrypt 取得失敗 | DNS未反映 / 80番閉塞 | Aレコード伝播待ち、ファイアウォール確認 |

---

## 5. 仕上げ: アウトプット

Zenn / Qiita の記事、または GitHub に README 付きで公開する。

**記事の構成案**（そのまま面接の話の順番になる）

1. 背景 — Rails 8 で外部依存が減ったと聞いたので、実際に確かめた
2. 作ったもの — 死活監視ダッシュボード（1段落 + スクショ1枚）
3. Solid Queue — なぜ親子ジョブに分けたか
4. Solid Cache — 計測値のビフォーアフター
5. Kamal 2 — 詰まった3箇所と解決
6. 所感 — Redis を立てずにここまで動いた。一方で SQLite ゆえの制約もあった

**6の「一方で」が効く。** 良かった点だけ書くと宣伝に見えるが、
制約も理解した上で使っていると分かると、技術選定できる人という印象になる。

---

## 6. スケジュール目安

| Phase | 内容 | 目安 | 優先度 |
|---|---|---|---|
| 0 | 生成物を読む | 1h | 必須 |
| 1 | モデル・scaffold | 2h | 必須 |
| 2 | Solid Queue | 4h | 必須 |
| 3 | Solid Cable | — | 任意 |
| 4 | Solid Cache | 3h | 必須 |
| 5 | Kamal デプロイ | 5h | 強く推奨 |
| 6 | 自分自身を監視 | 2h | 任意 |
| 仕上げ | 記事化 | 3h | 推奨 |

**Phase 0〜4 で「試した」と言える。Phase 5 まで行くと「デプロイまでやった」に変わる。**
