# Phase 1: 監視対象を登録する。正常2件 + 必ず失敗する1件。
# 「必ず失敗する」対象があることで、down の記録・リトライ・失敗ジョブの隔離を実際に観察できる。
sites = [
  { name: "Example (正常)",   url: "https://example.com",            interval_seconds: 60 },
  { name: "GitHub (正常)",    url: "https://github.com",             interval_seconds: 60 },
  { name: "HTTP 500 (失敗)",  url: "https://httpbin.org/status/500", interval_seconds: 60 },
  { name: "存在しないホスト (失敗)", url: "https://no-such-host.invalid", interval_seconds: 60 }
]

sites.each do |attrs|
  Site.find_or_create_by!(url: attrs[:url]) do |s|
    s.name = attrs[:name]
    s.interval_seconds = attrs[:interval_seconds]
    s.enabled = true
  end
end

puts "Seeded #{Site.count} sites."

# Phase 4: 稼働率集計のベンチマーク用に大量の Check を生成する。
# 通常のシードでは作らない（重いため）。SEED_CHECKS=10000 のように件数を指定したときだけ生成する。
#
#   SEED_CHECKS=10000 bin/rails db:seed
if (count = ENV["SEED_CHECKS"].to_i) > 0
  target = Site.order(:id).first
  raise "監視対象がありません" if target.nil?

  puts "Generating #{count} checks for '#{target.name}' ..."
  now = Time.current
  # 直近30日にランダムに散らす。95% を ok にして現実的な稼働率にする。
  target.checks.delete_all
  count.times.each_slice(1000) do |slice|
    rows = slice.map do |i|
      ok = (i % 20 != 0) # 5% を失敗に
      checked_at = now - rand(30 * 24 * 60 * 60).seconds
      {
        site_id: target.id,
        ok: ok,
        status_code: ok ? 200 : 500,
        response_time_ms: rand(20..800),
        error_message: ok ? nil : "HTTP 500",
        checked_at: checked_at,
        created_at: checked_at,
        updated_at: checked_at
      }
    end
    Check.insert_all(rows)
  end
  puts "Done. '#{target.name}' now has #{target.checks.count} checks."
end
