require 'active_support/concern'

module OrderStateConfig

  extend ActiveSupport::Concern

  included do

    # require 'work_complete_mailer.rb'

    # reproduction orders don't have a confirm step so confirm on create
    after_create do
      if self.order_type.name == 'reproduction'
        confirm
      end
    end

    # Specify state an Order is in by default upon creation
    def initial_state
      :pending
    end

    # Define states, events to move to state, and description of the event displayed to users
    def self.states_events
      [
        {
          event: :reset,
          to_state: :pending,
          event_description: "Reset order status to 'pending'."
        },
        {
          event: :review,
          to_state: :reviewing,
          event_description: "Review the request prior to confirmation."
        },
        {
          event: :confirm,
          to_state: :confirmed,
          event_description: "The request has been reviewed and items are approved for transfer."
        },
        {
          event: :fulfill,
          to_state: :fulfilled,
          event_description: "All items have been received at their use location."
        },
        {
          event: :close,
          to_state: :closed,
          event_description: "Use of the items is complete or no longer required. This order can be closed."
        }
      ]
    end

    # Special state/event definitions for reproduction requests
    def self.states_events_reproduction
      [
        {
          event: :reset,
          to_state: :pending,
          event_description: "Reset order status to 'pending'."
        },
        {
          event: :begin_work,
          to_state: :in_progress,
          event_description: "Digitization/copying is in progress or files are being prepared for delivery."
        },
        {
          event: :complete_work,
          to_state: :work_complete,
          event_description: "Digitization/copying is complete or files are ready for delivery."
        },
        {
          event: :fulfill,
          to_state: :fulfilled,
          event_description: "Materials have been sent to the requester as specified."
        },
        {
          event: :close,
          to_state: :closed,
          event_description: "All physical items have been returned and the requester has been invoiced as required. This order can be closed."
        }
      ]
    end

    # Define the final/terminal state for order
    def final_state
      :closed
    end

    # Instance method that calls self.states_events class method above
    # Provides common functionality between Items and Orders for shared methods in state_transition_support
    def states_events_config
      if reproduction_order?
        config = self.class.states_events_reproduction
      else
        config = self.class.states_events
      end
    end

    # Returns states/events as a flat array for use in the front end
    def states_events
      states_events_config.map { |se| [ se[:to_state], se[:event], se[:event_description] || '' ] }
    end


    def required_metadata_present?(event, metadata)
     metadata[:user_id]
    end


    # Define methods to be executed AFTER the given even is complete
    #   and the Order moves to a new state
    def event_callbacks(event, metadata={})
      case event
      when :reset, :review
        if confirmed
          update_attributes(confirmed: false)
        end
      when :confirm
        confirm
        # trigger :order for all applicable items
        # NOTE: :order event is common to both physical and digital items
        items.each do |i|
          if i.event_permitted(:order)
            user_id = last_transition.user_id
            i.trigger!(:order, { order_id: id, user_id: user_id })
          end
        end
      when :complete_work
        request = metadata[:request]
        work_complete_notification(request)
      when :close
        close
      end
      if event != :close && !open
        reopen
      end
    end

    # Specifies conditions under which a given event is permitted
    # Returns boolean
    def event_permitted(event)
      case event
      when :review
        [:pending, :requested].include? current_state
      when :confirm
        if !has_digital_items?
          [:pending, :reviewing].include? current_state
        else
          current_state == :reviewing
        end
      when :begin_work
        current_state == :pending && any_items_ready?
      when :complete_work
        current_state == :in_progress
      when :fulfill
        if reproduction_order?
          current_state == :work_complete
        else
          all_items_ready? && (current_state == :confirmed)
        end
      when :activate
        current_state == :fulfilled
      when :close
        if reproduction_order?
          current_state == :fulfilled
        else
          (current_state == :fulfilled) && finished?
        end
      end
    end

    # Returns integer representing the number of Items associated with this Order
    #   which are ready for use
    def num_items_ready
      ready = 0
      items.each do |i|
        if i.current_state == :ready_at_temporary_location
          ready += 1
        end
      end
      ready
    end


    def item_ready?(item)
      at_temp_location = item.at_temporary_location_for_order?(self.id)
      if item.digital_object
        item.state_reached_for_order(:ready_at_use_location, self.id) || at_temp_location
      else
        item.state_reached_for_order(:ready_at_temporary_location, self.id) || at_temp_location
      end
    end


    # Returns true if all items associated with this Order are ready for use
    def all_items_ready?
      ready = false
      items.each do |i|
        if !i.obsolete
          ready = item_ready?(i)
        end
        break if !ready
      end
      ready
    end


    # Returns true if any items associated with this Order are ready for use
    def any_items_ready?
      ready = false
      if items.blank?
        ready = true
      else
        items.each do |i|
          if !i.obsolete
            if i.digital_object
              ready = i.state_reached_for_order(:ready_at_use_location, self.id)
            else
              ready = i.state_reached_for_order(:ready_at_temporary_location, self.id)
            end
          end
          break if ready
        end
      end
      ready
    end


    # Triggers the :fulfill event for this Order if all of its Items are ready for use
    def fulfill_if_items_ready(metadata)
      if !reproduction_order?
        if available_events.include?(:fulfill) && all_items_ready?
          trigger(:fulfill, metadata)
        end
      end
    end


    # Returns true if Order is finished
    def finished?
      finished = nil
      active_item_orders = item_orders.where(active: true)
      if state_reached?(:fulfilled)
        if active_item_orders.length == 0
          finished = true
        else
          active_item_orders.each do |io|
            i = io.item
            if !i.obsolete
              last_transition = i.state_transitions.where(order_id: id).first

              if last_transition && (last_transition.to_state == i.final_state.to_s)
                finished = true
              else
                finished = false
                break
              end
            end
          end
        end
      end
      finished
    end


    private


    def work_complete_notification(request)
      order_url = "#{request.host_with_port}/#/orders/#{self.id}"
      self.assignees.each do |a|
        WorkCompleteMailer.assignee_email(self, a, order_url).deliver_later
      end
    end

  end
end
