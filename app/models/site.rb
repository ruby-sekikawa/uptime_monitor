# 監視対象URL 1件を表す。ドメイン上は「モニター（監視対象）」。
# モデル名を Monitor にすると Ruby 標準ライブラリの Monitor クラスと衝突するため Site とした。
class Site < ApplicationRecord
  has_many :checks, dependent: :delete_all

  validates :name, presence: true
  validates :url, presence: true, format: { with: %r{\Ahttps?://}i, message: "は http(s):// で始まる必要があります" }
  validates :interval_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 10 }

  scope :enabled, -> { where(enabled: true) }

  # チェック時刻を過ぎた（= 前回チェックから interval_seconds 以上経過した）有効な監視対象。
  # last_checked_at が nil（未チェック）のものは常に対象。
  scope :due, ->(now = Time.current) {
    enabled.where(
      "last_checked_at IS NULL OR last_checked_at <= datetime(:now, '-' || interval_seconds || ' seconds')",
      now: now.utc.strftime("%Y-%m-%d %H:%M:%S")
    )
  }

  # 全サイトの稼働率(%)を GROUP BY で「1クエリ」でまとめて返す。 { site_id => ratio_or_nil }。
  # 一覧ページで各行ごとに uptime_ratio を呼ぶと N+1(1 + 2N クエリ)になるため、
  # 一覧ではこちらを使って 1 クエリに畳む。期間内に Check が無いサイトはハッシュに現れない(= nil 扱い)。
  def self.uptime_ratios(period = 24.hours)
    Check.where(checked_at: period.ago..)
         .group(:site_id)
         .pluck(
           Arel.sql("site_id"),
           Arel.sql("ROUND(100.0 * SUM(CASE WHEN ok THEN 1 ELSE 0 END) / COUNT(*), 2)")
         )
         .to_h
  end

  # 単一サイトの稼働率(%)。詳細ページ用。集計を Solid Cache に載せる（Phase 4）。
  # cache_key_with_version により、Site 更新時は自動的に別キーになる。
  def uptime_ratio(period = 24.hours)
    Rails.cache.fetch([ cache_key_with_version, "uptime", period.to_i ], expires_in: 5.minutes) do
      scope = checks.where(checked_at: period.ago..)
      total = scope.count
      total.zero? ? nil : (scope.where(ok: true).count.to_f / total * 100).round(2)
    end
  end
end
