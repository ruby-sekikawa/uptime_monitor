# Redisを立てずにRails 8のSolid Queue / Solid Cacheで死活監視ダッシュボードを作ってKamalでデプロイした

## 背景

Rails 8 で「外部依存（Redis / Sidekiq / Memcached）を立てなくてもジョブとキャッシュが動く」と聞いて、本当にそうなのか自分の手で確かめたくなった。題材は**死活監視ダッシュボード**にした。URLを登録して1分おきにHTTPを叩き、稼働率を集計・表示するもの。

「5秒待ってログを出すだけのジョブ」でも技術的には試せるが、それだと「なぜその設計にしたか」を語れない。死活監視なら「1件のタイムアウトが全体を止めるから親子ジョブに分けた」「集計が重かったからキャッシュした」と、**必要性が先にある形**で判断を説明できる。そこを狙った。

## 作ったもの

- URL（監視対象）を登録 → 1分おきに `Net::HTTP` でチェック → 結果を蓄積
- 一覧でUP/DOWNと24時間の稼働率を表示、詳細でチェック履歴を表示
- **Redis / Sidekiq / Memcached はゼロ**。ジョブもキャッシュもSQLiteの別DBに載せた

技術スタック:

| 領域 | 採用 |
|---|---|
| Rails | 8.1 / Ruby 3.4.9 |
| DB | SQLite（primary / cache / queue / cable の複数DB） |
| ジョブ | Solid Queue + `recurring.yml` |
| キャッシュ | Solid Cache |
| HTTPクライアント | `Net::HTTP`（標準ライブラリ） |
| ジョブ監視 | mission_control-jobs（`/jobs`） |
| デプロイ | Kamal 2 |

モデルは `Site`（監視対象URL）と `Check`（1回のチェック結果）の2つ。

> 補足: モデル名を `Monitor` にしたら `undefined method 'all' for class Monitor` で動かなかった。Ruby標準ライブラリの `Monitor`（排他制御クラス）と定数が衝突して、Zeitwerkが自作モデルを読み込めなかったため。`Site` に改名して解決した。

## デフォルトで何が有効になっていたか（複数DB構成）

`rails new` の生成物を読むと、**production は primary / cache / queue / cable の複数DB構成**になっていた。ただし development は primary 単一。開発でも本番同様に動かしたかったので、`database.yml` の development を複数DB化し、`development.rb` に以下を足した。

```ruby
config.cache_store = :solid_cache_store
config.active_job.queue_adapter = :solid_queue
config.solid_queue.connects_to = { database: { writing: :queue } }
```

ここで一つハマった。**Solid Queue は `connects_to` で接続先を指定するのに対し、Solid Cache は `config/cache.yml` の `database:` で指定する**。cache.yml の development に `database: cache` を書き忘れると、Cache が primary DB を見に行って `Could not find table 'solid_cache_entries'` で落ちる。入口が別なのが分かりにくかった。

```yaml
# config/cache.yml
development:
  database: cache   # ← これが要る（デフォルトは production だけ）
```

接続が別DBを向いていることは、こう確認できる。

```ruby
ActiveRecord::Base.connection_db_config.database  # => storage/development.sqlite3
SolidQueue::Job.connection_db_config.database     # => storage/development_queue.sqlite3
SolidCache::Entry.connection_db_config.database   # => storage/development_cache.sqlite3
```

## Solid Queue — なぜ親子ジョブに分けたか

ここが一番語れる部分。ジョブを1本にせず、**親子に分けた**。

```ruby
# 親: 毎分実行。対象を列挙して子を投入するだけ。HTTPは叩かない
class EnqueueDueChecksJob < ApplicationJob
  queue_as :default
  def perform
    Site.due(Time.current).find_each { |site| CheckSiteJob.perform_later(site.id) }
  end
end

# 子: 実際にHTTPを叩く
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

**理由**: 1本のジョブで全URLを順に叩くと、1件のタイムアウト（最大5秒）で後続が全部止まる。子ジョブに分割すると、**並列実行・リトライ・失敗の隔離**をジョブ基盤に任せられる。

エラーハンドリングは3系統に分けた。

- タイムアウト → `retry_on` で3回リトライ。**尽きたらrescueして down として記録**する。死活監視では「落ちている」事実こそ残したいので、単にジョブを失敗させて終わりにしない。
- DNS解決失敗・接続拒否 → 一時障害ではないので即 down（リトライしない）。
- 監視対象が削除済み → `discard_on ActiveJob::DeserializationError` で捨てる。

ワーカー構成（`config/queue.yml`）はHTTPチェック専用のキューを切って、スレッドを多めにした。

```yaml
workers:
  - queues: "checks"   # HTTPチェックはI/O待ちが中心なのでスレッド多め
    threads: 5
  - queues: "*"
    threads: 3
```

HTTPチェックは応答待ち（ブロッキングI/O）が処理時間の大半で、Ruby(MRI)は**I/O待ちの間はGVLを手放す**。だからスレッドを増やすと複数の「待ち」を重ね合わせられて効率が上がる。CPU中心の処理ならこうはいかない（GVLを握りっぱなしで並列化しないので、その場合はプロセス数=`JOB_CONCURRENCY`を増やす方向になる）。

### 一次体験: Redisなしで永続化されている

`bin/jobs`（ワーカー）を止める → チェックが `solid_queue_ready_executions` に溜まる → 再起動すると溜まった分が処理される。ジョブがDBに永続化されているのを目で確認できた。Redisのように別プロセスを立てていないのに、ジョブが消えない。

## Solid Cache — と、その前に「まず計測」でN+1に気づいた話

ここが一番の学びだった。当初は素直に、一覧を行ごとにフラグメントキャッシュ、稼働率集計を `Rails.cache.fetch` で包んだ。

```ruby
def uptime_ratio(period = 24.hours)
  Rails.cache.fetch([cache_key_with_version, "uptime", period.to_i], expires_in: 5.minutes) do
    scope = checks.where(checked_at: period.ago..)
    total = scope.count
    total.zero? ? nil : (scope.where(ok: true).count.to_f / total * 100).round(2)
  end
end
```

Check を3万件入れて `Completed` ログを見ると、キャッシュ前25クエリ・後5クエリ。一見よさそう。だが**クエリの内訳**を見て気づいた——一覧で各行が `uptime_ratio` を呼んでいて、これは **N+1（1 + 2N クエリ）** だ。

**キャッシュはN+1の対症療法にすぎない。** コールドや失効のたびにN+1が再発する。そこで根本を直すことにした。全サイトの稼働率を `GROUP BY` で**1クエリ**にまとめる。

```ruby
# 全サイトの稼働率を1クエリで取得（N+1の解消）
def self.uptime_ratios(period = 24.hours)
  Check.where(checked_at: period.ago..)
       .group(:site_id)
       .pluck(Arel.sql("site_id"),
              Arel.sql("ROUND(100.0 * SUM(CASE WHEN ok THEN 1 ELSE 0 END) / COUNT(*), 2)"))
       .to_h
end
```

### 計測: 3パターン比較（一覧ページ / サイト4件・クエリ本数）

| 実装 | コールド | ウォーム | 鮮度 |
|---|---|---|---|
| A. N+1 + フラグメントキャッシュ | 25 | 5 | TTLで最大5分古い |
| B. 集計1クエリ + キャッシュ | 10 | 6 | TTLで最大5分古い |
| C. 集計1クエリ・キャッシュなし | **2** | **2** | **常に最新** |

50サイト×各200チェック（1万件）の集計コストでも、**N+1版100クエリ/43ms → GROUP BY版1クエリ/19ms**（結果は完全一致）。

**Cが全項目で最良**だった。集計を1クエリに畳んだ後は、フラグメントキャッシュはむしろ足を引っ張る（Bのウォーム6 > Cの2。キャッシュ読み書き＋集計クエリの二重コスト）。結果、**一覧のキャッシュは撤去し、`Site.uptime_ratios`（1クエリ・常に最新）に変更**した。

さらに正直に言うと、`checks` に `[:site_id, :checked_at]` の複合インデックスを張っていたので集計クエリ単体は約1msで既に速く、教科書的な「320ms→8ms」の劇的差は出なかった。そして**devモードの計測はテンプレートコンパイルが初回に混ざる**ので、判断は再現性のある「クエリ本数」と本番モードの再計測でやるべきだった。

教訓は明確で、**「まず計測 → 根本原因（N+1）を特定 → 対症療法（キャッシュ）ではなくGROUP BYで根治 → 必要なら最後にキャッシュ」**。キャッシュを入れる前に、まずN+1を疑う。

### Solid Cache はどこで使ったか

一覧では不要になったが、**詳細ページの稼働率**は `uptime_ratio` の低レベルキャッシュ（Solid Cache）で残している。キーに `cache_key_with_version` を含めるのでSite更新時は即失効、Check増加はTTL5分で反映、という設計。`touch: true` での即時反映は、1分ごとに大量のCheckを作る本アプリでは `sites` への書き込み競合を招くので見送った。

## Kamal 2 — 詰まった3箇所

（ローカル検証まで実施。実デプロイ手順は `config/deploy.yml` を整備済み）

Kamal でつまずきやすいのはこの3つだと思う。

1. **デプロイのたびにデータが消える** → `volumes` 未設定。SQLiteファイルは永続ボリュームに載せないと、コンテナ入れ替えで消える。
   ```yaml
   volumes:
     - "uptime_monitor_storage:/rails/storage"   # ★最重要
   ```
2. **ワーカーをどう動かすか** → 1台構成なら `SOLID_QUEUE_IN_PUMA: true` で Puma プロセス内にワーカーを同居させるのが簡単（方式A）。別ロールに分ける方式Bもあるが、**SQLiteは同一ホストのファイルなので、同じホストで同じボリュームを共有する必要がある**。この制約が方式Aを選ぶ理由になる。
3. **SSL** → kamal-proxy が Let's Encrypt で終端するので、`production.rb` の `assume_ssl` / `force_ssl` を有効化しておく。DNSのAレコードが伝播する前に `kamal setup` すると証明書取得に失敗する。

## 所感

Redis も Sidekiq も Memcached も立てずに、ジョブ・定期実行・キャッシュ・ジョブ監視までひととおり動いた。個人開発や小規模なら、これで十分にやれるという手応えがある。運用対象のプロセスが減るのは素直にありがたい。

一方で、**SQLiteゆえの制約**もはっきり見えた。書き込みが基本1つずつなので、ワーカーのスレッドを上げすぎると `SQLite3::BusyException`（書き込み競合）が出る。ワーカーを別ホストに分離できない（同一ホスト・同一ボリュームが前提）のも、スケールを考えると効いてくる。「Redisが要らなくなった」ではなく、「**この規模ならRedisが要らない。規模が変わればトレードオフが変わる**」という理解が正確だと思う。

良かった点だけでなく制約も含めて掴めたのが、実際に手を動かした一番の収穫だった。

---

*リポジトリ / 実装の詳細ドキュメントは別途。この記事の計測値はいずれもローカル（development）でのもの。*
