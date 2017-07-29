# rubocop:disable Metrics/LineLength
# == Schema Information
#
# Table name: posts
#
#  id                       :integer          not null, primary key
#  blocked                  :boolean          default(FALSE), not null
#  comments_count           :integer          default(0), not null
#  content                  :text             not null
#  content_formatted        :text             not null
#  deleted_at               :datetime         indexed
#  edited_at                :datetime
#  media_type               :string
#  nsfw                     :boolean          default(FALSE), not null
#  post_likes_count         :integer          default(0), not null
#  spoiled_unit_type        :string
#  spoiler                  :boolean          default(FALSE), not null
#  target_interest          :string
#  top_level_comments_count :integer          default(0), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  media_id                 :integer
#  spoiled_unit_id          :integer
#  target_group_id          :integer
#  target_user_id           :integer
#  user_id                  :integer          not null
#
# Indexes
#
#  index_posts_on_deleted_at  (deleted_at)
#
# Foreign Keys
#
#  fk_rails_5b5ddfd518  (user_id => users.id)
#  fk_rails_6fac2de613  (target_user_id => users.id)
#
# rubocop:enable Metrics/LineLength

require_dependency 'html/pipeline/onebox_filter'

class Post < ApplicationRecord
  include WithActivity
  include ContentProcessable

  acts_as_paranoid
  resourcify
  processable :content, LongPipeline

  belongs_to :user, required: true, counter_cache: true
  belongs_to :target_user, class_name: 'User'
  belongs_to :target_group, class_name: 'Group'
  belongs_to :media, polymorphic: true
  belongs_to :spoiled_unit, polymorphic: true
  has_many :post_likes, dependent: :destroy
  has_many :post_follows, dependent: :destroy
  has_many :comments, dependent: :destroy

  scope :sfw, -> { where(nsfw: false) }
  scope :in_group, ->(group) { where(target_group: group) }
  scope :visible_for, ->(user) {
    scope = user && !user.sfw_filter? ? all : sfw

    left_join = <<~SQL
      LEFT OUTER JOIN groups g
      ON g.id = target_group_id
    SQL
    group_visible = <<~SQL
      posts.target_group_id IS NULL
      OR (g.privacy = 0 OR g.privacy = 2)
    SQL

    return scope.joins(left_join).distinct.where(group_visible) unless user

    scope.joins(left_join).distinct.where(<<~SQL)
      #{group_visible}
      OR g.id IN (
        SELECT group_members.group_id
        FROM group_members
        WHERE group_members.user_id = #{user.id}
      )
    SQL
  }

  validates :content, :content_formatted, presence: true
  validates :media, presence: true, if: :spoiled_unit
  validates :content, length: { maximum: 9_000 }
  validates :media, polymorphism: { type: Media }, allow_blank: true
  # posting to a group, posting to a profile, and posting to an interest are mutually exclusive.
  validates_with ExclusivityValidator, over: %i[target_user target_group target_interest]

  def feed
    PostFeed.new(id)
  end

  def comments_feed
    PostCommentsFeed.new(id)
  end

  def other_feeds
    feeds = []
    feeds << InterestGlobalFeed.new(target_interest) if target_interest
    # Don't fan out beyond aggregated feed
    feeds << media&.feed&.no_fanout
    feeds << spoiled_unit&.feed
    feeds.compact
  end

  def notified_feeds
    [
      target_user&.notifications,
      *mentioned_users.map(&:notifications)
    ].compact - [user.notifications]
  end

  def target_feed
    if target_user # A => B, post to B without fanout
      target_user.profile_feed.no_fanout
    elsif target_group # A => Group, post to Group
      target_group.feed
    else # General post, fanout normally
      user.profile_feed
    end
  end

  def target_timelines
    return [] unless target_user
    [user.timeline, target_user.timeline]
  end

  def stream_activity
    target_feed.activities.new(
      post_id: id,
      updated_at: updated_at,
      post_likes_count: post_likes_count,
      comments_count: comments_count,
      nsfw: nsfw,
      mentioned_users: mentioned_users.pluck(:id),
      to: other_feeds + notified_feeds + target_timelines
    )
  end

  def mentioned_users
    User.by_name(processed_content[:mentioned_usernames])
  end

  before_save do
    # Always check if the media is NSFW and try to force into NSFWness
    self.nsfw = media.try(:nsfw?) || false unless nsfw
    self.nsfw = target_group.try(:nsfw?) || false unless nsfw
    true
  end

  before_update do
    self.edited_at = Time.now if content_changed?
    true
  end

  after_create do
    media.trending_vote(user, 2.0) if media.present?
    if target_group.present?
      GroupUnreadFanoutWorker.perform_async(target_group_id, user_id)
    end
  end
end
