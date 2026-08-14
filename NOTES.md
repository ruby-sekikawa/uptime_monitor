# 作業ノート（面接で語るための一次情報）

> 計画書 §3「作業中に必ず残すもの」に対応。手を動かした人しか持っていない情報をここに集約する。

## ① 詰まったことログ（症状 → 原因 → 対処）

- **`rails new` が SyntaxError で途中停止**
  → Rails 8.1 の actionview が Ruby 3.4 の匿名引数フォワーディング構文を使用。手元の Ruby 3.3.0 では構文エラー。
  → `.ruby-version` を 3.4.9 に変更し `bundle install` し直して解決。
  （教訓: Rails 8.1 は実質 Ruby 3.4+ が必要。`rails new` が生成する `.ruby-version` が古い版を指すことがある。）

- **モデル名 `Monitor` が動かない（`undefined method 'all' for class Monitor`）**
  → Ruby 標準ライブラリの `Monitor`（排他制御クラス、`mon_enter` を持つ）が先に定義済みで、Zeitwerk が
     `app/models/monitor.rb` を読み込めない（定数が既に存在するため autoload されない）。scaffold 時にも衝突警告が出ていた。
  → モデル名を `Site` に変更（ドメイン概念は「監視対象URL」のまま）。テーブル `sites` / ルート `/sites` / ジョブ `CheckSiteJob`。

- **開発環境で Solid Cache が `Could not find table 'solid_cache_entries'`**
  → `config/cache.yml` は production だけに `database: cache` があり、development は primary DB を見ていた。
  → development セクションにも `database: cache` を追加して解決。
  （Solid Queue は `config/environments/development.rb` の `config.solid_queue.connects_to` で別DBに接続。
   Solid Cache は `cache.yml` の `database:` で指定、と入口が別なのがハマりどころ。）

- **`db:prepare` が古い `monitors` テーブルを復活させた**
  → 最初の Monitor 版で生成された `db/schema.rb` が残っており、sqlite ファイルだけ消しても schema.rb からロードされていた。
  → `db/schema.rb` と `storage/*.sqlite3` を削除してマイグレーションから作り直して解決。

## ② 計測値（母数とセットで）

Phase 4。`config/database.yml` の `checks` に複合インデックス `[:site_id, :checked_at]` を張った状態で計測。

- **母数**: Check **30,000 件**（直近30日に分散。稼働率は直近24hが集計対象で約1,000件）
- **一覧ページ `/sites`（development, 計画書の方法 = development.log の Completed 行）**

  | | 合計 | Views | ActiveRecord | クエリ数 |
  |---|---|---|---|---|
  | キャッシュ空（初回） | 19 ms | 14.3 ms | 2.2 ms | **25 queries** |
  | キャッシュ命中 | 4 ms | 2.2 ms | 0.1 ms | **5 queries** |

- **稼働率集計そのもの（`Site#uptime_ratio`, 母数30,000件）**
  - 生クエリ（キャッシュ無し）: 約 0.7〜1.5 ms
  - キャッシュ命中: 約 0.4 ms

### この数字から言えること（正直な所感）

- **複合インデックスを張ると、SQLite でも集計クエリ自体は約1msで済む**。「集計が重いからキャッシュ」という
  教科書的なビフォーアフター（例: 320ms→8ms）は、インデックスが無い／対象行が桁違いに多い場合の話。
- 今回キャッシュが効いたのは主に **一覧ページの View 描画とクエリ本数**（25→5, 19ms→4ms）。
  フラグメントキャッシュ（`<% cache site %>`）が行ごとの再描画を、`uptime_ratio` のキャッシュが集計クエリを省いた。
- → 面接では「まず計測したら、集計はインデックスで既に速かった。キャッシュの効果はむしろ
  一覧の描画とN+1的なクエリ本数の削減に出た」と、計測に基づいて語れる。

## ③ 判断を変えた場面 / 設計判断

- **ジョブを1本にせず親子に分けた**（`EnqueueDueChecksJob` → `CheckSiteJob`）
  1本で全URLを順に叩くと1件のタイムアウトで全体が止まる。子に分割して並列・リトライ・失敗の隔離をSolid Queueに委ねた。

- **リトライ全滅後も down を記録する**
  `retry_on Net::OpenTimeout/ReadTimeout` でリトライしつつ、尽きたら `rescue` して down を保存。
  「落ちている」という事実こそ死活監視では記録したい情報なので、単にジョブを失敗させて終わりにしない。
  一方 DNS解決失敗・接続拒否は一時障害でないので即 down（リトライしない）。

- **ワーカーを Puma 内で動かす（`SOLID_QUEUE_IN_PUMA=true`, 方式A）**
  SQLite は同一ホストのファイルなので、別ホストのワーカーからは共有できない。1台構成なら Puma 内が最も簡単。
  複数台に増やすなら job ロールに分離するが、その場合も同一ホスト・同一ボリューム共有が前提になる。

- **キャッシュ TTL を5分に**
  死活監視の稼働率は数分の鮮度で十分。`cache_key_with_version` によりレコード更新時は即座に別キーになるため、
  TTLは「更新が無いときの上限鮮度」を決めるだけ。短すぎるとキャッシュ効果が薄れ、長すぎると鮮度が落ちる妥協点。

- **ワーカースレッド数**: `checks` キューに5、`*` に3（`config/queue.yml`）。
  HTTPチェックはブロッキングI/O主体なのでスレッドを多めに。書き込み競合（`SQLite3::BusyException`）が出たら下げる方針。
