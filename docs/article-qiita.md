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

## Solid Cache — まず計測してから入れる

「重かったからキャッシュした」と言うために、**先に計測**した。Check を3万件生成して、稼働率を集計する一覧ページの `Completed` ログを見る。

稼働率の集計はモデルに置き、`Rails.cache.fetch` で包んだ。

```ruby
def uptime_ratio(period = 24.hours)
  Rails.cache.fetch([cache_key_with_version, "uptime", period.to_i], expires_in: 5.minutes) do
    scope = checks.where(checked_at: period.ago..)
    total = scope.count
    total.zero? ? nil : (scope.where(ok: true).count.to_f / total * 100).round(2)
  end
end
```

一覧は行ごとにフラグメントキャッシュ。

```erb
<% @sites.each do |site| %>
  <% cache site do %>
    <tr>...</tr>
  <% end %>
<% end %>
```

### 計測結果（母数: Check 3万件）

一覧ページ `/sites` の `Completed` ログ:

| | 合計 | Views | ActiveRecord | クエリ数 |
|---|---|---|---|---|
| キャッシュ空（初回） | 19 ms | 14.3 ms | 2.2 ms | 25 |
| キャッシュ命中 | 4 ms | 2.2 ms | 0.1 ms | 5 |

正直に書くと、**稼働率の集計クエリ単体は約1msで、すでに速かった**。`checks` に `[:site_id, :checked_at]` の複合インデックスを張っていたためで、教科書的な「320ms→8ms」のような劇的な差にはならなかった。キャッシュが効いたのはむしろ**一覧のView描画とクエリ本数**（25→5、19ms→4ms）。フラグメントキャッシュが行の再描画を、`uptime_ratio` のキャッシュが集計クエリを省いた形だ。

「計測したら、集計はインデックスで既に速く、キャッシュの効果は描画とクエリ本数の削減に出た」——この事実は手を動かさないと分からなかった。

### キャッシュの無効化

キーに `cache_key_with_version`（`sites/1-<updated_at>`）を含めているので、**Siteを更新すると自動的に別キー扱いになり、古いキャッシュは参照されなくなる**。TTL 5分にしたのは、Siteが更新されない状態でも新しいCheckを最大5分で反映するため（Checkが増えても `sites.updated_at` は変わらないので、そこはTTLで拾う）。`belongs_to :site, touch: true` で即時反映もできるが、1分ごとに大量のCheckを作る本アプリでは `sites` への書き込み競合を招くので採用しなかった。

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
