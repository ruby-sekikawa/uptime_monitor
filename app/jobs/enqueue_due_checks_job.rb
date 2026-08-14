# recurring（config/recurring.yml）で毎分実行される親ジョブ。
# 「有効かつチェック時刻を過ぎた Site」を抽出し、各 Site ごとに子ジョブ（CheckSiteJob）を enqueue する。
#
# このジョブ自体は HTTP を叩かない。実 I/O は子ジョブに任せ、ここは列挙と投入だけに徹する。
# こうすることで、1件の遅い監視対象が他の監視のスケジューリングを止めない。
class EnqueueDueChecksJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    due = Site.due(now)
    count = 0

    due.find_each do |site|
      CheckSiteJob.perform_later(site.id)
      count += 1
    end

    Rails.logger.info("[EnqueueDueChecksJob] enqueued #{count} check(s)")
  end
end
