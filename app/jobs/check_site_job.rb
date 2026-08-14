require "net/http"

# 1件の Site に対して実際に HTTP を叩き、結果を Check として記録する子ジョブ。
#
# 親子に分けた理由（面接で話す内容）:
#   1本のジョブで全URLを順に叩くと、1件のタイムアウトで全体が止まる。
#   子ジョブに分割することで、並列実行・リトライ・失敗の隔離をジョブ基盤（Solid Queue）に任せられる。
class CheckSiteJob < ApplicationJob
  queue_as :checks

  TIMEOUT = 5 # open/read ともに 5 秒

  # タイムアウトは一時的な障害の可能性があるのでリトライする。
  # ただしリトライ全滅後は「落ちている」ことを記録したいので、rescue して down を保存する（下記参照）。
  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3

  # 監視対象が削除済みなど、引数を復元できないケースは記録しても意味がないので捨てる。
  discard_on ActiveJob::DeserializationError

  def perform(site_id)
    site = Site.find_by(id: site_id)
    return if site.nil? # 削除済み

    started = monotonic_ms
    result = perform_request(site.url)
    elapsed = monotonic_ms - started

    record(site, ok: result[:ok], status_code: result[:status_code],
                 response_time_ms: elapsed, error_message: result[:error])
  rescue Net::OpenTimeout, Net::ReadTimeout
    # retry_on の試行がすべて尽きたあとにここへ到達する。down として記録してから終了する。
    elapsed = defined?(started) && started ? (monotonic_ms - started) : nil
    record(site, ok: false, status_code: nil, response_time_ms: elapsed,
                 error_message: "timeout (#{TIMEOUT}s)")
  end

  private

  # HTTP リクエストを実行し、結果をハッシュで返す。
  # 2xx/3xx を up、それ以外(4xx/5xx)や例外を down とみなす。
  def perform_request(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.start { |h| h.request(Net::HTTP::Get.new(uri.request_uri)) }
    code = response.code.to_i
    { ok: code < 400, status_code: code, error: (code >= 400 ? "HTTP #{code}" : nil) }
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise # retry_on に処理させる
  rescue StandardError => e
    # DNS 解決失敗・接続拒否・SSL エラーなどは即 down（リトライ対象にしない）
    { ok: false, status_code: nil, error: "#{e.class}: #{e.message}".truncate(200) }
  end

  def record(site, ok:, status_code:, response_time_ms:, error_message:)
    now = Time.current
    site.checks.create!(
      ok: ok, status_code: status_code, response_time_ms: response_time_ms,
      error_message: error_message, checked_at: now
    )
    site.update!(last_status: ok ? "up" : "down", last_checked_at: now)
  end

  def monotonic_ms
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
  end
end
