# frozen_string_literal: true

module DfE
  module Analytics
    class SendEvents < AnalyticsJob
      def self.do(events)
        unless DfE::Analytics.enabled?
          Rails.logger.warn('DfE::Analytics::SendEvents.do() called but DfE::Analytics is disabled. Please check DfE::Analytics.enabled? before sending events to BigQuery')
          return
        end

        # The initialise event is a one-off event that must be sent to BigQuery once only
        DfE::Analytics::InitialisationEvents.trigger_initialisation_events unless DfE::Analytics::InitialisationEvents.initialisation_events_sent?

        events = events.map { |event| event.is_a?(Event) ? event.as_json : event }

        perform_for(events)
      end

      def self.perform_for(events)
        if DfE::Analytics.within_maintenance_window?
          set(wait_until: DfE::Analytics.next_scheduled_time_after_maintenance_window).perform_later(events)
        elsif DfE::Analytics.async?
          perform_later(events)
        else
          perform_now(events)
        end
      end

      def perform(events)
        if DfE::Analytics.log_only?
          # Use the Rails logger here as the job's logger is set to :warn by default
          events.each { |event| Rails.logger.info("DfE::Analytics: #{mask_hidden_data(event).inspect}") }
        else
          if DfE::Analytics.event_debug_enabled?
            events
              .select { |event| DfE::Analytics::EventMatcher.new(event).matched? }
              .each { |event| Rails.logger.info("DfE::Analytics processing: #{mask_hidden_data(event).inspect}") }
          end

          DfE::Analytics.config.azure_federated_auth ? DfE::Analytics::BigQueryApi.insert(events) : DfE::Analytics::BigQueryLegacyApi.insert(events)
        end
      end

      private

      def mask_hidden_data(event)
        masked_event = event.deep_dup.with_indifferent_access
        return event unless masked_event&.key?(:hidden_data)

        mask_hidden_data_values(masked_event)
      end

      def mask_hidden_data_values(event)
        hidden_data = event[:hidden_data]

        hidden_data.each { |data| mask_data(data) } if hidden_data.is_a?(Array)

        event
      end

      def mask_data(data)
        return unless data.is_a?(Hash)

        data[:value] = ['HIDDEN'] if data[:value].present?

        return unless data[:key].is_a?(Hash) && data[:key][:value].present?

        data[:key][:value] = ['HIDDEN']
      end
    end
  end
end
