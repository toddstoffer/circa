class Item < ApplicationRecord

  include AspaceConnect
  include ItemStateConfig
  include StateTransitionSupport
  include RefIntegrity
  include SolrDoc
  include VersionsSupport

  belongs_to :permanent_location, class_name: "Location"
  belongs_to :current_location, class_name: "Location"
  has_many :item_orders
  has_many :orders, through: :item_orders do
    def open
      where(open: true)
    end
  end
  has_many :item_archivesspace_records
  has_one :item_catalog_record
  has_many :access_sessions do
    def active
      where(active: true)
    end
  end
  has_one :active_access_session, -> { where active: true },
      class_name: 'AccessSession'
  has_many :access_users, through: :access_sessions

  has_paper_trail ignore: [:current_location_id]

  attr_accessor :archivesspace_records

  validates :uri, uniqueness: true, unless: :digital_object

  before_create do
    if !self.current_location_id
      self.current_location_id = self.permanent_location_id
    end
  end

  # Returns an array of all ArchivesSpace URIs associated with this item
  # (ie URIs used to add item to orders)
  def archivesspace_records
    item_archivesspace_records.map { |iar| iar.archivesspace_uri }
  end

  # Returns all open orders that include this item
  def open_orders
    orders.open
  end


  def active_orders
    item_orders.where(active:true).to_a.keep_if { |io| io.order.open }.map { |io| io.order }
  end

  # Returns boolean
  def has_open_orders?
    open_orders.length > 0
  end

  # Searches orders associated with this item and returns next upcoming access date
  def next_scheduled_use_date
    next_date = nil

    open_orders.each do |o|
      if o.access_date_start
        next_date ||= o.access_date_start
        if o.access_date_start < next_date
          next_date = o.access_date_start
        end
      end
    end
    next_date
  end

  # Returns true if the item is associated with an active access_session
  def in_use?
    active_session = access_sessions.active.first
    !active_session.nil?
  end


  # Retruns all active access_sessions
  def active_access_session
    access_sessions.active.first
  end


  # Returns true if this item is associated with an open order that has been confirmed
  def has_confirmed_order?
    confirmed_order = false
    open_orders.each do |o|
      if o.confirmed
        confirmed_order = true
        break
      end
    end
    confirmed_order
  end


  # The logic here is that the order associated with the item's
  # last state transition is its active order
  def active_order_id
    last_transition ? last_transition.order_id : nil
  end


  def source
    if item_catalog_record
      'catalog'
    elsif !item_archivesspace_records.blank?
      'archivesspace'
    else
      'unknown'
    end
  end


  def event_history
    history = []

    # Get location per event (or where applicable?)
    event_attributes = lambda do |state_transition|
      attributes = {
        event: transition.metadata[:event].gsub(/_/, ' '),
        datetime: transition.created_at,
        order_id: transition.metadata[:order_id]
      }
      staff_user = User.where(id: transition.metadata[:user_id]).first
      if staff_user
        attributes[:staff_user] = user_attributes(staff_user)
      end
      attributes
    end

    state_transitions.each do |t|
      history << event_attributes.call(t)
    end

    history
  end


  def movement_history
    history = []

    # Get location per event (or where applicable?)
    event_attributes = lambda do |state_transition|
      attributes = {
        state_transition_id: state_transition.id,
        datetime: state_transition.created_at,
        order_id: state_transition.metadata[:order_id],
        user_id: state_transition.user_id
      }
      case state_transition.to_state.to_sym
      when :in_transit_to_temporary_location
        attributes[:location_id] = permanent_location_id
        attributes[:action] = 'depart'
      when :arrived_at_temporary_location
        attributes[:location_id] = state_transition.metadata[:location_id]
        attributes[:action] = 'arrive'
      when :returning_to_permanent_location
        attributes[:location_id] = state_transition.metadata[:location_id]
        attributes[:action] = 'depart'
      when :at_permanent_location
        attributes[:location_id] = permanent_location_id
        attributes[:action] = 'arrive'
      else
        # ignore other events in preparing movement history
        return nil
      end

      if attributes[:user_id]
        user = User.find_by(id: attributes[:user_id])
        if user
          attributes[:user] = user_attributes(user)
        end
      end

      if attributes[:location_id]
        location = Location.find_by(id: attributes[:location_id])
        if location
          attributes[:location] = location_attributes(location)
        end
      end

      return attributes
    end

    state_transitions.each do |t|
      attributes = event_attributes.call(t)
      if attributes
        history << event_attributes.call(t)
      end
    end

    history
  end


  # Returns current and previous versions of the Item based on changes to
  #   non-transient attributes (basically everything but current_location)
  def modification_history
    history = []

    location_attributes = lambda do |location_id|
      location = Location.find_by(id: location_id)
      return location ? { title: location.title, uri: location.uri } : nil
    end

    user_attributes = lambda do |user_id|
      user = User.find_by(id: user_id)
      return user ? { email: user.email, display_name: user.display_name } : nil
    end

    gather_attributes = lambda do |item_version|
      atts = item_version.attributes
      atts['source'] = source
      location_id = item_version.permanent_location_id
      user_id = item_version.paper_trail.originator.to_i
      atts['permanent_location'] = location_attributes.(location_id)
      atts['user'] = user_attributes.(user_id)
      if item_catalog_record
        atts['item_catalog_record'] = item_catalog_record.attributes
      end
      return atts
    end

    add_to_history = Proc.new do |item|
      history << gather_attributes.(item)
      previous = item.paper_trail.previous_version
      if previous
        add_to_history.(previous)
      end
    end

    add_to_history.(self)

    history
  end


  def last_accessed
    if access_sessions.length > 0
      a = access_sessions.order(:start_datetime).last
      a.start_datetime
    end
  end


  # For items for which the ArchivesSpace top container no longer exists
  #   due to re-processing
  def mark_as_obsolete
    if source == 'archivesspace'
      replacement_items = []

      item_orders.each do |io|
        return_items = io.update_archivesspace_item
        replacement_items += return_items
      end

      eligible_for_obsolete = !replacement_items.include?(self)
    else
      raise CircaExceptions::BadRequest,
        "The item could not be marked as obsolete this only applies to items created from ArchivesSpace records."
    end

    puts eligible_for_obsolete ? "Item is eligible to be made obsolete" :
        "Item is NOT eligible to be made obsolete"

    if eligible_for_obsolete
      update_columns(current_location_id: nil, permanent_location_id: nil, obsolete: true)
      item_orders.each do |io|
        io.update_columns(archivesspace_uri: nil, active: false)
      end
      update_index
    else
      raise CircaExceptions::BadRequest,
        "The item could not be marked as obsolete because one or more of the
        ArchivesSpace URIs associated with it still return a record with
        container information matching that of the item."
    end
  end


  def digital_item_access_sessions
    items = Item.where(uri: uri)
    all_access_sessions = []
    items.each do |i|
      i.access_sessions.each { |a| all_access_sessions << a }
    end
    all_access_sessions
  end


  def active_order_ids
    ids = []
    item_orders.each do |io|
      if io.active && io.order.open
        ids << io.order_id
      end
    end
    ids
  end


  def has_active_access_session_for_order?(order_id)
    if active_access_session
      active_access_session.order_id == order_id
    else
      false
    end
  end


  def deactivate_for_order(order_id, user_id)
    if !has_active_access_session_for_order?(order_id)
      item_orders.where(order_id: order_id).each { |io| io.deactivate(user_id) }
    end
    close_applicable_orders({user_id: user_id})
  end


  def deactivate_for_other_orders(excluded_order_id, user_id)
    item_orders.where(active: true).each do |io|
      if io.order_id != excluded_order_id
        deactivate_for_order(io.order_id, user_id)
      end
    end
  end


  def activate_for_order(order_id)
    item_orders.where(order_id: order_id).each { |io| io.activate }
  end


  def active_for_order?(order_id)
    item_orders.where(order_id: order_id, active: true).length > 0
  end


  def at_temporary_location_for_order?(order_id)
    o = Order.find(order_id)
    o.location_id == current_location_id
  end


  def update_from_source
    case source
    when 'archivesspace'
      archivesspace_uris = []
      item_archivesspace_records.each do |iar|
        archivesspace_uris << iar.archivesspace_uri
      end
      archivesspace_uris.each do |uri|
        options = { digital_object: digital_object }
        options[:force_update] = digital_object ? true : nil
        CreateOrUpdateItemsFromArchivesspace.call(uri, options)
      end
    end
  end


  # Load custom concern if present - methods in concern override those in model
  begin
    include ItemCustom
  rescue
  end


  private


  def user_attributes(user)
    {
      id: user.id,
      first_name: user.first_name,
      last_name: user.last_name,
      display_name: user.display_name,
      email: user.email
    }.with_indifferent_access
  end


  def location_attributes(location)
    location.attributes.with_indifferent_access
  end

end
