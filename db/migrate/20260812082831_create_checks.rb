class CreateChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :checks do |t|
      t.references :site, null: false, foreign_key: true
      t.boolean :ok, null: false
      t.integer :status_code
      t.integer :response_time_ms
      t.string :error_message
      t.datetime :checked_at, null: false

      t.timestamps
    end

    # 稼働率の集計クエリ（site_id で絞り checked_at で範囲指定）を効かせるための複合インデックス。必須。
    add_index :checks, [ :site_id, :checked_at ]
  end
end
