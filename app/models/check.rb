class Check < ApplicationRecord
  belongs_to :site

  scope :recent, -> { order(checked_at: :desc) }
end
