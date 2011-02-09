class Classified < ActiveRecord::Base
  include AASM

  acts_as_authorization_object

  acts_as_taggable_on :tags, :category, :subcategories, :location
  acts_as_voteable 
  acts_as_media_item

  acts_as_featured_item
  acts_as_moderatable
  acts_as_relatable
  acts_as_wall_postable
  acts_as_tweetable
  
  named_scope :top, lambda { |*args| { :order => ["created_at desc"], :limit => (args.first || 10)} }
  named_scope :newest, lambda { |*args| { :order => ["created_at desc"], :limit => (args.first || 10)} }
  named_scope :auto_expired, lambda { |*args| { :conditions => ["expires_at < ? AND aasm_state IN (?)", Time.zone.now, [:unpublished, :available, :hidden].map(&:to_s)] } }
  named_scope :no_auto_expire, lambda { |*args| { :conditions => ["expires_at < ? AND aasm_state NOT IN (?)", Time.zone.now, [:unpublished, :available, :hidden].map(&:to_s)] } }
  named_scope :with_state, lambda { |*args| { :conditions => ["aasm_state = ?", args.first] } }
  named_scope :for_sale, { :conditions => ["listing_type = ?", "sale"] }
  named_scope :for_free, { :conditions => ["listing_type = ?", "free"] }
  named_scope :for_loan, { :conditions => ["listing_type = ?", "loan"] }
  named_scope :allow_all, { :conditions => ["allow = ?", "all"] }
  named_scope :allow_friends, { :conditions => ["allow = ?", "friends"] }
  named_scope :allow_friends_of_friends, { :conditions => ["allow = ?", "friends_of_friends"] }
  named_scope :available, { :conditions => ["aasm_state = ?", "available"] }

  belongs_to :user

  has_friendly_id :title, :use_slug => true
  has_many :comments, :as => :commentable

  validates_presence_of :title, :details, :user_id

  validate :validate_listing_type
  validate :validate_allow_type
  validate :validate_category_type
  validate :validate_subcategory_type

  before_save :set_expires_at

  aasm_initial_state :unpublished

# TODO:: ADD GUARDS
#   - loanable item should not be sellable
#   - sellable item should not be loanable
  aasm_state :unpublished
  aasm_state :available, :enter => [:expire, :set_published], :exit => :expire
  aasm_state :sold, :enter => :expire
  aasm_state :loaned_out, :enter => :expire
  aasm_state :expired, :enter => :expire
  aasm_state :closed, :enter => :expire
  aasm_state :hidden, :enter => :expire

  aasm_event :published do
    transitions :to => :available, :from => [:unpublished]
  end

  aasm_event :renewed do
    transitions :to => :available, :from => [:expired, :hidden], :success => :update_renewed
  end

  aasm_event :closed do
    transitions :to => :closed, :from => [:hidden, :available, :loaned_out]
  end

  aasm_event :sold do
    transitions :to => :sold, :from => :available
  end

  aasm_event :loaned_out do
    transitions :to => :loaned_out, :from => :available
  end

  aasm_event :hidden do
    transitions :to => :hidden, :from => [:available, :loaned_out]
  end

  aasm_event :returned do
    transitions :to => :hidden, :from => :loaned_out, :after => :update_renewed
  end

  aasm_event :expired do
    transitions :to => :expired, :from => [:unpublished, :available, :hidden]
  end

  def set_published; puts "Publishing" end
  def set_unpublish; puts "Publishing" end
  def update_renewed; puts "Renewed" end
  def expire; puts "Expiring" end
  def loan_to! user
    # create loaning
    loaned_out!
  end
  def state() aasm_current_state end

  def sellable?; listing_type == "sale" end
  def loanable?; listing_type == "loan" end
  def wanted?; listing_type == "wanted" end
  def free?; listing_type == "free" end

  def unhide!
    # notify waiting list users
    renewed!
  end
  
  def has_expired?
    Time.now > expires_at
  end

  def self.auto_expire_all
    self.auto_expired.each {|c| c.expired! }
  end

  def self.listing_types
    [:free, :sale, :loan, :wanted]
  end

  def valid_listing_type?
    self.class.valid_listing_type? listing_type
  end

  def self.valid_listing_type? type
    return false unless type
    self.listing_types.include? type.to_sym
  end
  
  def valid_category?
    self.class.valid_category? category_list
  end

  def self.valid_category? type
    return false unless type
    self.default_category_names.include? type.to_s
  end
  
  def valid_subcategory?
    self.class.valid_subcategory? subcategory_list
  end

  def self.valid_subcategory? type
    return false unless type
    self.default_subcategory_names.include? type.to_s
  end
  
  def self.allow_types
    [:friends, :friends_of_friends, :all]
  end

  def valid_allow_type?
    self.class.valid_allow_type? allow
  end

  def self.valid_allow_type? type
    return false unless type
    self.allow_types.include? type.to_sym
  end
  
  def is_owner? user
    user == self.user
  end

  def is_allowed? user = nil
    return true if is_owner? user

    method = "__#{state.to_s}_is_allowed?".to_sym

    if respond_to?(method)
    	send(method, user)
    else
    	false
    end
  end

  def allow_type() allow.to_sym end
  def allow_type=(atype) self.allow = atype end

  def self.default_categories() self.default_tags(:on => "category") end
  def self.default_subcategories() self.default_tags(:on => "subcategories") end
  def self.default_category_names() self.default_categories.map(&:name) end
  def self.default_subcategory_names() self.default_subcategories.map(&:name) end
  def self.add_default_category(category) self.build_default_tag_on(category, "category") end
  def self.add_default_subcategory(subcategory) self.build_default_tag_on(subcategory, "subcategories") end

  def category_name
    category.first.name
  end

  protected
    #
    # STATE METHODS
    # Should be of the form __STATE__#{overloaded_method_name}
    #
    def allow_user? user = nil, opts = {}
      return false if opts[:require_user] and not user

      default = opts[:default].present? ? opts[:default] : false
      default_all = opts[:default_all].present? ? opts[:default_all] : true

      case allow_type
      when :all
        default_all
      when :friends
        !! user and user.friends_with? self.user
      when :friends_of_friends
        !! user and user.friends_of_friends_with? self.user
      else
        default
      end
    end

    def __unpublished_is_allowed?(user = nil)
      user == self.user
    end

    def __hidden_is_allowed?(user = nil)
      user == self.user
    end

    def __loaned_out_is_allowed?(user = nil)
      allow_user? user, :require_user => true
    end

    def __expired_is_allowed?(user = nil)
      allow_user? user, :require_user => loanable?
    end

    def __sold_is_allowed?(user = nil)
      allow_user? user
    end

    def __closed_is_allowed?(user = nil)
      allow_user? user, :require_user => loanable?
    end

    def __available_is_allowed?(user = nil)
      # TODO::: REFACTOR
      if free? or sellable?
        allow_user? user, :default => true
      elsif loanable?
        allow_user? user, :require_user => true, :default => false
      else
      	false
      end
    end

  private
    
    def self.default_tags(options = {})
      conditions = {
        :context       => (options[:on] || "tags").to_s,
        :taggable_type => self.name,
        :taggable_id   => nil
      }
      Tagging.find(:all, :include => :tag, :conditions => conditions).map(&:tag).uniq
    end

    def self.build_default_tag_on(tag_name, context = "tags")
      return true if self.default_tags(:on => context).map(&:name).include? tag_name.to_s
      tag = Tag.find_or_create_by_name(tag_name.to_s)
      if tag
      	Tagging.create!({
          :context       => context,
          :taggable_type => self.name,
          :taggable_id   => nil,
          :tag           => tag
        })
      end
    end

    def set_expires_at
      self.expires_at ||= 2.weeks.from_now
    end

    def validate_listing_type
      errors.add(:listing_type, "must be a valid listing type") unless self.valid_listing_type?
    end

    def validate_allow_type
      errors.add(:allow, "must be a valid allow group") unless self.valid_allow_type?
    end

    def validate_category_type
      errors.add(:category_list, "must be a valid category group") unless self.valid_category?
    end

    def validate_subcategory_type
      return true unless subcategory_list.present?
      errors.add(:subcategory_list, "must be a valid subcategory group") unless self.valid_subcategory?
    end

end
