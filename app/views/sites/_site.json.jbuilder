json.extract! site, :id, :name, :url, :interval_seconds, :enabled, :last_status, :last_checked_at, :created_at, :updated_at
json.url site_url(site, format: :json)
