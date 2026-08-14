module SitesHelper
  # ステータスに応じた色付きバッジ。up=緑 / down=赤 / 未チェック=グレー。
  def status_badge(status)
    color, label =
      case status
      when "up"   then [ "#16a34a", "UP" ]
      when "down" then [ "#dc2626", "DOWN" ]
      else             [ "#9ca3af", "—" ]
      end

    content_tag :span, label,
      style: "display:inline-block;min-width:52px;text-align:center;" \
             "padding:2px 8px;border-radius:4px;color:#fff;font-weight:bold;" \
             "background:#{color};"
  end

  def uptime_label(ratio)
    return content_tag(:span, "データなし", style: "color:#9ca3af;") if ratio.nil?
    content_tag :span, "#{ratio}%", style: "font-weight:bold;"
  end
end
