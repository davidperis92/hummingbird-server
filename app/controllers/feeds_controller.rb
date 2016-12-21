class FeedsController < ApplicationController
  include Skylight::Helpers
  include Pundit
  skip_after_action :enforce_policy_use
  before_action :authorize_feed!

  def show
    render json: stringify_activities(query.list)
  end

  def mark_read
    activities = feed.activities.mark(:read, params[:_json])
    render json: serialize_activities(activities)
  end

  def mark_seen
    activities = feed.activities.mark(:seen, params[:_json])
    render json: serialize_activities(activities)
  end

  private

  def serialize_activities(list)
    @serializer ||= FeedSerializerService.new(
      list,
      including: params[:include]&.split(','),
      # fields: params[:fields]&.split(','),
      context: context,
      base_url: request.url
    )
  end

  instrument_method
  def stringify_activities(list)
    Oj.dump(serialize_activities(list))
  end

  def query
    @query ||= FeedQueryService.new(params, current_user&.resource_owner)
  end

  delegate :feed, to: :query

  def serialize_error(status, message)
    {
      errors: [
        {
          status: status,
          detail: message
        }
      ]
    }
  end

  def authorize_feed!
    unless feed_visible?
      render status: 403,
             json: serialize_error(403, 'Not allowed to access that feed')
    end
  end

  def feed_visible?
    case params[:group]
    when 'media', 'media_aggr'
      media_type, media_id = params[:id].split('-')
      return false unless %w[Manga Anime Drama].include?(media_type)
      media = media_type.safe_constantize.find_by(id: media_id)
      media && show?(media)
    when 'user', 'user_aggr'
      user = User.find_by(id: params[:id])
      user && show?(user)
    when 'notifications', 'timeline'
      user = User.find_by(id: params[:id])
      user == current_user.resource_owner
    when 'global' then true
    end
  end

  def policy_for(model)
    policy = Pundit::PolicyFinder.new(model).policy
    policy.new(current_user, model).tap { |policy| p policy }
  end

  def scope_for(model)
    scope = Pundit::PolicyFinder.new(model).scope
    scope.new(current_user, model).tap { |policy| p policy }
  end

  def show?(model)
    scope = model.class.where(id: model.id)
    scope_for(scope).resolve.exists?
  end
end
