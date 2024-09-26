# frozen_string_literal: true

module DiscourseEvents
  class EventController < AdminController
    PAGE_LIMIT = 30

    def index
      all_events =
        Event.includes(:sources, event_connections: [:topic]).references(:event_connections)
      events_with_topics =
        all_events.where("discourse_events_event_connections.topic_id IS NOT NULL")
      events_without_topics =
        all_events.where("discourse_events_event_connections.topic_id IS NULL")

      filter = params[:filter]
      events =
        if filter == "unconnected"
          events_without_topics
        elsif filter === "connected"
          events_with_topics
        else
          all_events
        end

      page = params[:page].to_i
      order = %w[start_time source_id name].find { |attr| attr == params[:order] } || "start_time"
      direction = ActiveRecord::Type::Boolean.new.cast(params[:asc]) ? "ASC" : "DESC"
      offset = page * PAGE_LIMIT

      events =
        events
          .order("discourse_events_events.#{order} #{direction}")
          .offset(offset)
          .limit(PAGE_LIMIT)

      render_json_dump(
        page: page,
        filter: filter,
        order: order,
        with_topics_count: events_with_topics.count,
        without_topics_count: events_without_topics.count,
        events: serialize_data(events, EventSerializer, root: false),
      )
    end

    def connect
      event_id = params[:event_id]
      event = Event.find_by(id: event_id)
      raise Discourse::InvalidParameters.new(:event_id) unless event

      topic_id = params[:topic_id]
      topic = Topic.find_by(id: topic_id)
      raise Discourse::InvalidParameters.new(:topic_id) unless topic

      client = params[:client]
      unless Connection.available_clients.include?(client)
        raise Discourse::InvalidParameters.new(:client)
      end

      topic_with_event = nil
      ActiveRecord::Base.transaction do
        event_connection =
          EventConnection.create!(event_id: event.id, topic_id: topic.id, client: client)
        syncer = "DiscourseEvents::#{client.camelize}Syncer".constantize.new(current_user)
        topic_with_event = syncer.connect_event_to_topic(topic, event)
        raise ActiveRecord::Rollback unless topic_with_event
      end

      if topic_with_event.present?
        render json: success_json
      else
        render json: failed_json
      end
    end

    def destroy
      event_ids = params[:event_ids]
      target = params[:target]
      result = { destroyed_event_ids: [], destroyed_topics_event_ids: [] }

      ActiveRecord::Base.transaction do
        events = Event.where(id: event_ids)

        if target === "events_and_topics" || target === "topics_only"
          event_connections = {}

          events
            .includes(:event_connections)
            .each do |event|
              event.event_connections.each do |ec|
                destroyer = PostDestroyer.new(current_user, ec.topic.first_post)
                destroyer.destroy
                event_connections[ec.id] ||= ec
              end

              result[:destroyed_topics_event_ids] << event.id
            end

          DiscourseEvents::EventConnection.where(id: event_connections.keys).delete_all
        end

        if target === "events_only" || target === "events_and_topics"
          destroyed_events = events.destroy_all
          result[:destroyed_event_ids] += destroyed_events.map(&:id)
        end
      end

      if result[:destroyed_event_ids].present? || result[:destroyed_topics_event_ids].present?
        render json: success_json.merge(result)
      else
        render json: failed_json
      end
    end
  end
end
